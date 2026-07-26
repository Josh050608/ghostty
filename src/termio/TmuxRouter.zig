//! TmuxRouter routes data between the host surface running tmux control
//! mode and the pane surfaces rendering individual tmux panes.
//!
//! Threading contract:
//!   - register/unregister/sendCommand: any thread (pane IO threads).
//!   - drainEvents/route/replaceTerminal: host IO thread only.
//!   - route() calls the pane's Termio.processOutput while holding our
//!     mutex; unregister() blocks on the same mutex, so after it returns
//!     the pane's Termio is never touched again by the router.
//!   - Lock order: host renderer mutex -> router mutex -> pane renderer
//!     mutex. Pane threads must never hold a renderer mutex when calling
//!     into the router.

const TmuxRouter = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const global = @import("../global.zig");
const xev = global.xev;
const termio = @import("../termio.zig");
const terminalpkg = @import("../terminal/main.zig");

const log = std.log.scoped(.tmux_router);

mutex: std.Io.Mutex = .init,
alloc: Allocator,
refs: std.atomic.Value(usize),
wakeup: xev.Async,
panes: std.AutoHashMapUnmanaged(usize, *termio.Termio) = .empty,
events: std.ArrayListUnmanaged(Event) = .empty,

pub const Event = union(enum) {
    registered: usize,
    unregistered: usize,
    command: []u8,
};

pub fn create(alloc: Allocator, wakeup: xev.Async) Allocator.Error!*TmuxRouter {
    const self = try alloc.create(TmuxRouter);
    self.* = .{ .alloc = alloc, .refs = .init(1), .wakeup = wakeup };
    return self;
}

pub fn ref(self: *TmuxRouter) void {
    _ = self.refs.fetchAdd(1, .monotonic);
}

pub fn unref(self: *TmuxRouter) void {
    if (self.refs.fetchSub(1, .acq_rel) != 1) return;
    for (self.events.items) |ev| switch (ev) {
        .command => |c| self.alloc.free(c),
        else => {},
    };
    self.events.deinit(self.alloc);
    self.panes.deinit(self.alloc);
    const alloc = self.alloc;
    alloc.destroy(self);
}

pub fn register(
    self: *TmuxRouter,
    pane_id: usize,
    io: *termio.Termio,
) Allocator.Error!void {
    {
        self.mutex.lockUncancelable(global.io());
        defer self.mutex.unlock(global.io());
        try self.panes.put(self.alloc, pane_id, io);
        try self.events.append(self.alloc, .{ .registered = pane_id });
    }
    self.wakeup.notify() catch |err| {
        log.warn("tmux router wakeup failed err={}", .{err});
    };
}

pub fn unregister(self: *TmuxRouter, pane_id: usize) void {
    {
        self.mutex.lockUncancelable(global.io());
        defer self.mutex.unlock(global.io());
        _ = self.panes.remove(pane_id);
        self.events.append(self.alloc, .{ .unregistered = pane_id }) catch |err| {
            log.warn("tmux router event dropped err={}", .{err});
        };
    }
    self.wakeup.notify() catch {};
}

pub fn sendCommand(self: *TmuxRouter, cmd: []const u8) Allocator.Error!void {
    {
        self.mutex.lockUncancelable(global.io());
        defer self.mutex.unlock(global.io());
        const owned = try self.alloc.dupe(u8, cmd);
        errdefer self.alloc.free(owned);
        try self.events.append(self.alloc, .{ .command = owned });
    }
    self.wakeup.notify() catch |err| {
        log.warn("tmux router wakeup failed err={}", .{err});
    };
}

/// Host IO thread: move all pending events into `out` (allocated with
/// the caller's allocator). Command payloads transfer ownership to the
/// caller, which must free them with this router's alloc (they are
/// allocated with router.alloc; the host and router share the surface
/// gpa in practice, but free via router.alloc to be exact).
pub fn drainEvents(
    self: *TmuxRouter,
    out: *std.ArrayListUnmanaged(Event),
    alloc: Allocator,
) Allocator.Error!void {
    self.mutex.lockUncancelable(global.io());
    defer self.mutex.unlock(global.io());
    try out.appendSlice(alloc, self.events.items);
    self.events.clearRetainingCapacity();
}

/// Host IO thread: feed pane output. Returns false if unknown pane.
pub fn route(self: *TmuxRouter, pane_id: usize, data: []const u8) bool {
    self.mutex.lockUncancelable(global.io());
    defer self.mutex.unlock(global.io());
    const io = self.panes.get(pane_id) orelse return false;
    io.processOutput(data);
    io.renderer_wakeup.notify() catch {};
    return true;
}

/// Host IO thread: hand the captured terminal to the pane surface.
/// Takes ownership of `t` on success (moves it into the pane Termio);
/// on false the caller still owns it.
pub fn replaceTerminal(
    self: *TmuxRouter,
    pane_id: usize,
    t: *terminalpkg.Terminal,
) bool {
    self.mutex.lockUncancelable(global.io());
    defer self.mutex.unlock(global.io());
    const io = self.panes.get(pane_id) orelse return false;
    io.tmuxReplaceTerminal(t); // Task 6 restores the real body
    return true;
}

test "router events round trip" {
    const alloc = std.testing.allocator;
    var wakeup = try xev.Async.init();
    defer wakeup.deinit();

    const router = try TmuxRouter.create(alloc, wakeup);
    defer router.unref();

    try router.sendCommand("list-windows\n");

    var events: std.ArrayListUnmanaged(Event) = .empty;
    defer {
        for (events.items) |ev| switch (ev) {
            .command => |c| alloc.free(c),
            else => {},
        };
        events.deinit(alloc);
    }
    try router.drainEvents(&events, alloc);
    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqualStrings("list-windows\n", events.items[0].command);
}

test "router refcount" {
    const alloc = std.testing.allocator;
    var wakeup = try xev.Async.init();
    defer wakeup.deinit();
    const router = try TmuxRouter.create(alloc, wakeup);
    router.ref();
    router.unref();
    router.unref(); // 归零自毁；测试通过 = 无泄漏无 double-free
}
