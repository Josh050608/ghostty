//! Encode pane input bytes into tmux send-keys commands.
//! Printable-safe ASCII runs use the literal form (-l) for ~1:1 byte
//! cost; everything else (C0 controls, non-ASCII, characters that are
//! risky inside a tmux double-quoted argument) uses the hex form (-H).
//! tmux ≥3.2 gate means no version branches.
//!
//! Short safe runs sandwiched between unsafe bytes are folded into the
//! neighboring hex form (see MIN_LITERAL_RUN) so that content with dense
//! interleaving of safe/unsafe bytes (JSON, shell snippets, `a$a$a$...`)
//! doesn't degrade into one send-keys command per byte or two.

const std = @import("std");
const testing = std.testing;

const LITERAL_CHUNK = 256;
const HEX_CHUNK = 64;

/// Safe runs shorter than this are folded into an adjacent hex run
/// instead of being emitted as their own literal command. Hex can
/// represent any byte, so folding never weakens the isLiteralSafe
/// boundary -- it only trades a few bytes of wire overhead for far
/// fewer send-keys round trips (each one a dupe + mutex + wakeup
/// notification on the IO thread) when safe and unsafe bytes interleave
/// densely. A run only gets folded when it has a neighboring run at all
/// (i.e. it isn't the entirety of `data`), since by construction any
/// two adjacent runs have opposite safety and folding an isolated safe
/// run would only add hex overhead for no reduction in command count.
const MIN_LITERAL_RUN = 12;

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

/// A contiguous span of `data` sharing one classification. `safe` starts
/// as the raw isLiteralSafe verdict for the run and may be downgraded to
/// hex by the MIN_LITERAL_RUN fold below.
const Run = struct {
    start: usize,
    end: usize,
    safe: bool,
};

/// Encode pane input bytes into a series of tmux `send-keys` commands,
/// invoking `emit` once per command in input byte order. Runs of
/// printable-safe ASCII are sent via the literal form (`-l`, chunked at
/// `LITERAL_CHUNK` bytes); everything else is sent via the hex form
/// (`-H`, chunked at `HEX_CHUNK` bytes). Safe runs shorter than
/// `MIN_LITERAL_RUN` that border an unsafe run are folded into hex first
/// (see MIN_LITERAL_RUN doc comment). Command order matches input byte
/// order.
pub fn encode(
    alloc: std.mem.Allocator,
    pane_id: usize,
    data: []const u8,
    ctx: anytype,
    emit: fn (@TypeOf(ctx), []const u8) anyerror!void,
) !void {
    if (data.len == 0) return;

    // Pass 1: split into raw runs of same-class bytes. Consecutive runs
    // always alternate safe/unsafe by construction.
    var runs: std.ArrayListUnmanaged(Run) = .empty;
    defer runs.deinit(alloc);
    {
        var i: usize = 0;
        while (i < data.len) {
            const safe = isLiteralSafe(data[i]);
            var j = i + 1;
            while (j < data.len and isLiteralSafe(data[j]) == safe) j += 1;
            try runs.append(alloc, .{ .start = i, .end = j, .safe = safe });
            i = j;
        }
    }

    // Pass 2: fold short safe runs into hex when they have a neighbor
    // (i.e. runs.items.len > 1 -- a lone run spanning all of `data` has
    // no neighbor to fold with and gains nothing from folding).
    if (runs.items.len > 1) {
        for (runs.items) |*run| {
            if (run.safe and (run.end - run.start) < MIN_LITERAL_RUN) {
                run.safe = false;
            }
        }
    }

    // Pass 3: merge adjacent runs that now share a classification (a
    // folded safe run plus its unsafe neighbor(s) becomes one run) and
    // emit, chunking each merged run at its form's byte cap.
    var idx: usize = 0;
    while (idx < runs.items.len) {
        const safe = runs.items[idx].safe;
        const start = runs.items[idx].start;
        var end = runs.items[idx].end;
        idx += 1;
        while (idx < runs.items.len and runs.items[idx].safe == safe) {
            end = runs.items[idx].end;
            idx += 1;
        }
        const cap: usize = if (safe) LITERAL_CHUNK else HEX_CHUNK;

        var k = start;
        while (k < end) {
            const chunk_end = @min(end, k + cap);
            const chunk = data[k..chunk_end];
            k = chunk_end;

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
    // "ab" and "cd" are each only 2 bytes (< MIN_LITERAL_RUN) and both
    // border the "\r" hex run, so they fold into it: one merged hex
    // command covering the whole input, instead of literal+hex+literal.
    try testing.expectEqual(1, c.list.items.len);
    try testing.expectEqualStrings("send-keys -t %5 -H 61 62 0d 63 64\n", c.list.items[0]);
}

test "blacklist chars and non-ascii go hex" {
    var c: Collector = .{ .alloc = testing.allocator };
    defer c.deinit();
    // '"' 与多字节 UTF-8 都必须走 hex;两端的单字节 "a"/"b" 也因短于
    // MIN_LITERAL_RUN 且与不安全段相邻而折入同一条 hex 命令。
    try encode(testing.allocator, 1, "a\"\xe4\xbd\xa0b", &c, Collector.emit);
    try testing.expectEqual(1, c.list.items.len);
    try testing.expectEqualStrings("send-keys -t %1 -H 61 22 e4 bd a0 62\n", c.list.items[0]);
}

test "short safe run alone (no neighbor) still stays literal" {
    // A safe run shorter than MIN_LITERAL_RUN that spans the *entire*
    // input has no neighbor to fold with, so it must not be downgraded
    // to hex -- confirmed separately by "pure printable ascii becomes
    // one literal command" above (11 bytes, one run). This test pins
    // the even-shorter edge case explicitly.
    var c: Collector = .{ .alloc = testing.allocator };
    defer c.deinit();
    try encode(testing.allocator, 4, "hi", &c, Collector.emit);
    try testing.expectEqual(1, c.list.items.len);
    try testing.expectEqualStrings("send-keys -t %4 -l -- \"hi\"\n", c.list.items[0]);
}

test "dense safe/unsafe interleaving folds instead of exploding command count" {
    // Regression guard: before MIN_LITERAL_RUN folding, alternating
    // 1-byte safe/unsafe runs produced one command per run (up to ~1
    // command per input byte). Folding collapses the whole pattern into
    // a single run of hex chunks, matching the pre-encoder hex-only
    // command count instead of a 60x+ blowup.
    var c: Collector = .{ .alloc = testing.allocator };
    defer c.deinit();
    const pattern = "a$" ** 500; // 1000 bytes, alternating 1-byte runs.
    try encode(testing.allocator, 3, pattern, &c, Collector.emit);
    try testing.expectEqual((pattern.len + HEX_CHUNK - 1) / HEX_CHUNK, c.list.items.len);
    for (c.list.items) |cmd| {
        try testing.expect(std.mem.indexOf(u8, cmd, " -l -- ") == null);
    }
}

test "property: literal command bodies never contain unsafe bytes" {
    var byte: u16 = 0;
    while (byte < 256) : (byte += 1) {
        const b: u8 = @intCast(byte);

        // Frame the candidate byte with 0, 3, and 20 bytes of safe
        // padding on each side to exercise the isolated-run path, the
        // MIN_LITERAL_RUN fold path, and the un-folded-neighbor path.
        inline for (.{ 0, 3, 20 }) |pad| {
            var buf: [pad * 2 + 1]u8 = undefined;
            @memset(buf[0..pad], 'A');
            buf[pad] = b;
            @memset(buf[pad + 1 ..], 'A');

            var c: Collector = .{ .alloc = testing.allocator };
            defer c.deinit();
            try encode(testing.allocator, 7, &buf, &c, Collector.emit);

            for (c.list.items) |cmd| {
                if (std.mem.indexOf(u8, cmd, " -l -- \"")) |i| {
                    const body = cmd[i + 8 .. cmd.len - 2];
                    for (body) |bb| try testing.expect(isLiteralSafe(bb));
                }
            }
        }
    }
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
