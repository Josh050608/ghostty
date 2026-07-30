//! Encode pane input bytes into tmux send-keys commands.
//! Printable-safe ASCII runs use the literal form (-l) for ~1:1 byte
//! cost; everything else (C0 controls, non-ASCII, characters that are
//! risky inside a tmux double-quoted argument) uses the hex form (-H).
//! tmux ≥3.2 gate means no version branches.

const std = @import("std");
const testing = std.testing;

const LITERAL_CHUNK = 256;
const HEX_CHUNK = 64;

/// Whether a byte is safe to send inside a tmux `-l` (literal) double
/// quoted argument without any risk of shell/format-string reinterpretation.
/// Printable ASCII (0x20-0x7e) minus a conservative blacklist of
/// characters tmux treats specially inside quotes: backslash, double
/// quote, `;`, `$`, `#`, `'`, `{`, `}`, `~` (home expansion), and `%`
/// (tmux format specifiers). Anything outside this set — including all
/// C0 controls and non-ASCII bytes — falls back to the hex form.
fn isLiteralSafe(b: u8) bool {
    if (b < 0x20 or b > 0x7e) return false;
    return switch (b) {
        '\\', '"', ';', '$', '#', '\'', '{', '}', '~', '%' => false,
        else => true,
    };
}

/// Encode pane input bytes into a series of tmux `send-keys` commands,
/// invoking `emit` once per command in input byte order. Runs of
/// printable-safe ASCII are sent via the literal form (`-l`, chunked at
/// `LITERAL_CHUNK` bytes); everything else is sent via the hex form
/// (`-H`, chunked at `HEX_CHUNK` bytes). Command order matches input
/// byte order.
pub fn encode(
    alloc: std.mem.Allocator,
    pane_id: usize,
    data: []const u8,
    ctx: anytype,
    emit: fn (@TypeOf(ctx), []const u8) anyerror!void,
) !void {
    var i: usize = 0;
    while (i < data.len) {
        const safe = isLiteralSafe(data[i]);
        // Find the end of this run of same-class bytes.
        var j = i + 1;
        while (j < data.len and isLiteralSafe(data[j]) == safe) j += 1;
        const cap: usize = if (safe) LITERAL_CHUNK else HEX_CHUNK;

        var k = i;
        while (k < j) {
            const end = @min(j, k + cap);
            const chunk = data[k..end];
            k = end;

            var buf: std.Io.Writer.Allocating = .init(alloc);
            defer buf.deinit();
            if (safe) {
                try buf.writer.print("send-keys -t %{d} -l -- \"", .{pane_id});
                try buf.writer.writeAll(chunk);
                try buf.writer.writeAll("\"\n");
            } else {
                try buf.writer.print("send-keys -t %{d} -H", .{pane_id});
                for (chunk) |b| try buf.writer.print(" {x:0>2}", .{b});
                try buf.writer.writeByte('\n');
            }
            try emit(ctx, buf.writer.buffered());
        }
        i = j;
    }
}

const Collector = struct {
    list: std.ArrayListUnmanaged([]u8) = .empty,
    alloc: std.mem.Allocator,
    fn emit(self: *Collector, cmd: []const u8) anyerror!void {
        try self.list.append(self.alloc, try self.alloc.dupe(u8, cmd));
    }
    fn deinit(self: *Collector) void {
        for (self.list.items) |s| self.alloc.free(s);
        self.list.deinit(self.alloc);
    }
};

test "pure printable ascii becomes one literal command" {
    var c: Collector = .{ .alloc = testing.allocator };
    defer c.deinit();
    try encode(testing.allocator, 5, "ls -la /tmp", &c, Collector.emit);
    try testing.expectEqual(1, c.list.items.len);
    try testing.expectEqualStrings(
        "send-keys -t %5 -l -- \"ls -la /tmp\"\n",
        c.list.items[0],
    );
}

test "control bytes go hex, order preserved" {
    var c: Collector = .{ .alloc = testing.allocator };
    defer c.deinit();
    try encode(testing.allocator, 5, "ab\rcd", &c, Collector.emit);
    try testing.expectEqual(3, c.list.items.len);
    try testing.expectEqualStrings("send-keys -t %5 -l -- \"ab\"\n", c.list.items[0]);
    try testing.expectEqualStrings("send-keys -t %5 -H 0d\n", c.list.items[1]);
    try testing.expectEqualStrings("send-keys -t %5 -l -- \"cd\"\n", c.list.items[2]);
}

test "blacklist chars and non-ascii go hex" {
    var c: Collector = .{ .alloc = testing.allocator };
    defer c.deinit();
    // '"' 与多字节 UTF-8 都必须走 hex
    try encode(testing.allocator, 1, "a\"\xe4\xbd\xa0b", &c, Collector.emit);
    try testing.expectEqual(3, c.list.items.len);
    try testing.expectEqualStrings("send-keys -t %1 -l -- \"a\"\n", c.list.items[0]);
    try testing.expectEqualStrings("send-keys -t %1 -H 22 e4 bd a0\n", c.list.items[1]);
    try testing.expectEqualStrings("send-keys -t %1 -l -- \"b\"\n", c.list.items[2]);
}

test "literal chunks split at 256 bytes" {
    var c: Collector = .{ .alloc = testing.allocator };
    defer c.deinit();
    const data = "x" ** 300;
    try encode(testing.allocator, 2, data, &c, Collector.emit);
    try testing.expectEqual(2, c.list.items.len);
    // 第一块 256 字节,第二块 44 字节
    try testing.expect(std.mem.indexOf(u8, c.list.items[0], "\"" ++ ("x" ** 256) ++ "\"") != null);
    try testing.expect(std.mem.indexOf(u8, c.list.items[1], "\"" ++ ("x" ** 44) ++ "\"") != null);
}

test "hex chunks split at 64 bytes" {
    var c: Collector = .{ .alloc = testing.allocator };
    defer c.deinit();
    const data = [_]u8{0x01} ** 65;
    try encode(testing.allocator, 2, &data, &c, Collector.emit);
    try testing.expectEqual(2, c.list.items.len);
}

test "empty input emits nothing" {
    var c: Collector = .{ .alloc = testing.allocator };
    defer c.deinit();
    try encode(testing.allocator, 2, "", &c, Collector.emit);
    try testing.expectEqual(0, c.list.items.len);
}

test "round trip: decode emitted commands equals input" {
    var c: Collector = .{ .alloc = testing.allocator };
    defer c.deinit();
    const input = "echo \"hi\"; rm -rf ~\r\x1b[A\xf0\x9f\x91\xbb plain tail";
    try encode(testing.allocator, 9, input, &c, Collector.emit);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(testing.allocator);
    for (c.list.items) |cmd| {
        if (std.mem.indexOf(u8, cmd, " -l -- \"")) |i| {
            const body = cmd[i + 8 .. cmd.len - 2]; // 去掉结尾 "\n
            try out.appendSlice(testing.allocator, body);
        } else if (std.mem.indexOf(u8, cmd, " -H ")) |i| {
            var it = std.mem.tokenizeScalar(u8, cmd[i + 4 .. cmd.len - 1], ' ');
            while (it.next()) |hex|
                try out.append(testing.allocator, try std.fmt.parseInt(u8, hex, 16));
        } else return error.UnknownCommandShape;
    }
    try testing.expectEqualStrings(input, out.items);
}
