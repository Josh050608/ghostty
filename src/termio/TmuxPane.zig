//! Termio backend for a tmux pane surface. There is no subprocess and
//! no pty: input is translated to tmux `send-keys` commands routed to
//! the host surface via TmuxRouter, and output arrives when the host
//! calls our Termio.processOutput through the router.

const TmuxPane = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const global = @import("../global.zig");
const xev = global.xev;
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");
const ProcessInfo = @import("../pty.zig").ProcessInfo;
const TmuxKeyEncode = @import("TmuxKeyEncode.zig");

const log = std.log.scoped(.io_tmux_pane);

router: *termio.TmuxRouter,
pane_id: usize,

pub const Config = struct {
    router: *termio.TmuxRouter,
    pane_id: usize,
};

pub fn init(cfg: Config) TmuxPane {
    cfg.router.ref();
    return .{ .router = cfg.router, .pane_id = cfg.pane_id };
}

pub fn deinit(self: *TmuxPane) void {
    self.router.unref();
}

/// Call to initialize the terminal state as necessary for this backend.
pub fn initTerminal(self: *TmuxPane, t: *terminal.Terminal) void {
    _ = self;
    _ = t;
}

pub fn threadEnter(
    self: *TmuxPane,
    alloc: Allocator,
    io: *termio.Termio,
    td: *termio.Termio.ThreadData,
) !void {
    _ = alloc;
    td.backend = .{ .tmux_pane = {} };
    try self.router.register(self.pane_id, io);
}

pub fn threadExit(self: *TmuxPane, td: *termio.Termio.ThreadData) void {
    _ = td;
    self.router.unregister(self.pane_id);
}

pub fn focusGained(
    self: *TmuxPane,
    td: *termio.Termio.ThreadData,
    focused: bool,
) !void {
    _ = self;
    _ = td;
    _ = focused;
}

pub fn resize(
    self: *TmuxPane,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
) !void {
    // Pane dimensions are dictated by the tmux layout; plan 2 will
    // drive refresh-client from the GUI side.
    _ = self;
    _ = grid_size;
    _ = screen_size;
}

pub fn queueWrite(
    self: *TmuxPane,
    alloc: Allocator,
    td: *termio.Termio.ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    _ = td;
    // The terminal-side newline translation happens in tmux's pty,
    // not ours; send bytes as-is.
    _ = linefeed;
    try TmuxKeyEncode.encode(alloc, self.pane_id, data, self, emitCommand);
}

fn emitCommand(self: *TmuxPane, cmd: []const u8) anyerror!void {
    try self.router.sendCommand(cmd);
}

pub fn childExitedAbnormally(
    self: *TmuxPane,
    gpa: Allocator,
    t: *terminal.Terminal,
    exit_code: u32,
    runtime_ms: u64,
) !void {
    _ = self;
    _ = gpa;
    _ = t;
    _ = exit_code;
    _ = runtime_ms;
}

pub fn getProcessInfo(
    self: *TmuxPane,
    comptime info: ProcessInfo,
) ?ProcessInfo.Type(info) {
    _ = self;
    return null;
}

test "queueWrite routes through TmuxKeyEncode" {
    const alloc = std.testing.allocator;
    var wakeup = try xev.Async.init();
    defer wakeup.deinit();
    const router = try termio.TmuxRouter.create(alloc, wakeup);
    defer router.unref();

    var pane = TmuxPane.init(.{ .router = router, .pane_id = 5 });
    defer pane.deinit();

    // td parameter is unused in tmux_pane implementation
    try pane.queueWrite(alloc, undefined, "hi\r", false);

    var events: std.ArrayListUnmanaged(termio.TmuxRouter.Event) = .empty;
    defer {
        for (events.items) |ev| switch (ev) {
            .command => |c| alloc.free(c),
            else => {},
        };
        events.deinit(alloc);
    }
    try router.drainEvents(&events, alloc);
    try std.testing.expectEqual(@as(usize, 2), events.items.len);
    try std.testing.expectEqualStrings(
        "send-keys -t %5 -l -- \"hi\"\n",
        events.items[0].command,
    );
    try std.testing.expectEqualStrings(
        "send-keys -t %5 -H 0d\n",
        events.items[1].command,
    );
}
