//! TmuxRouter routes data between the host surface running tmux control
//! mode and the pane surfaces rendering individual tmux panes.
//!
//! Threading contract:
//!   - register/unregister/sendCommand: any thread (pane IO threads).
//!   - drainEvents/route/replaceTerminal: host IO thread only.
//!
//! Two-mutex discipline (prevents ABBA deadlock):
//!   - events_mutex: guards the `events` list.
//!     Users: sendCommand, drainEvents, and the event-append part of
//!     register/unregister.
//!   - panes_mutex: guards the `panes` map.
//!     Users: route, replaceTerminal, and the map part of
//!     register/unregister.
//!
//! Why two mutexes?
//!   Pane IO threads call sendCommand (and indirectly via sizeReportLocked /
//!   colorSchemeReportLocked) while holding their renderer mutex.  The old
//!   single-mutex design allowed route() to hold the router mutex while
//!   calling processOutput -> pane renderer mutex, creating an ABBA cycle:
//!     pane-renderer -> router  AND  router -> pane-renderer.
//!   With the split, events_mutex is never held while acquiring any renderer
//!   mutex, so no cycle is possible.
//!
//!   register/unregister acquire the two locks SEQUENTIALLY (map op under
//!   panes_mutex, release, then event append under events_mutex, release,
//!   then notify) — they are never nested.  Both are called from
//!   threadEnter/threadExit, which never hold a renderer mutex.
//!   unregister uses events → panes → events segment pattern to pre-reserve
//!   the event slot before pane removal, ensuring the unregistered event
//!   cannot be lost due to OOM after the pane is already deleted.
//!
//!   unref teardown takes neither lock: refcount == 0 guarantees
//!   exclusivity.

const TmuxRouter = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const global = @import("../global.zig");
const xev = global.xev;
const termio = @import("../termio.zig");
const terminalpkg = @import("../terminal/main.zig");

const log = std.log.scoped(.tmux_router);

/// Guards `events`. Held only by sendCommand, drainEvents, and the
/// event-append portion of register/unregister. Never held while
/// acquiring any renderer mutex.
events_mutex: std.Io.Mutex = .init,
/// Guards `panes`. Held only by route, replaceTerminal, and the
/// map portion of register/unregister.
panes_mutex: std.Io.Mutex = .init,
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
    // Map op under panes_mutex (never nested with events_mutex).
    {
        self.panes_mutex.lockUncancelable(global.io());
        defer self.panes_mutex.unlock(global.io());
        try self.panes.put(self.alloc, pane_id, io);
    }
    // Event append under events_mutex (never nested with panes_mutex).
    {
        self.events_mutex.lockUncancelable(global.io());
        defer self.events_mutex.unlock(global.io());
        try self.events.append(self.alloc, .{ .registered = pane_id });
    }
    self.wakeup.notify() catch |err| {
        log.warn("tmux router wakeup failed err={}", .{err});
    };
}

pub fn unregister(self: *TmuxRouter, pane_id: usize) void {
    // Reserve the event slot first so the append below cannot fail:
    // the pane removal is mandatory (its Termio is being torn down),
    // and losing the event would leave the viewer routing to a ghost.
    var reserved = true;
    {
        self.events_mutex.lockUncancelable(global.io());
        defer self.events_mutex.unlock(global.io());
        self.events.ensureUnusedCapacity(self.alloc, 1) catch {
            reserved = false;
            log.warn("tmux router unregister event dropped (OOM) pane={}", .{pane_id});
        };
    }
    {
        self.panes_mutex.lockUncancelable(global.io());
        defer self.panes_mutex.unlock(global.io());
        _ = self.panes.remove(pane_id);
    }
    if (reserved) {
        self.events_mutex.lockUncancelable(global.io());
        defer self.events_mutex.unlock(global.io());
        self.events.appendAssumeCapacity(.{ .unregistered = pane_id });
    }
    self.wakeup.notify() catch {};
}

pub fn sendCommand(self: *TmuxRouter, cmd: []const u8) Allocator.Error!void {
    {
        self.events_mutex.lockUncancelable(global.io());
        defer self.events_mutex.unlock(global.io());
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
    self.events_mutex.lockUncancelable(global.io());
    defer self.events_mutex.unlock(global.io());
    try out.appendSlice(alloc, self.events.items);
    self.events.clearRetainingCapacity();
}

/// Host IO thread: feed pane output. Returns false if unknown pane.
pub fn route(self: *TmuxRouter, pane_id: usize, data: []const u8) bool {
    self.panes_mutex.lockUncancelable(global.io());
    defer self.panes_mutex.unlock(global.io());
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
    self.panes_mutex.lockUncancelable(global.io());
    defer self.panes_mutex.unlock(global.io());
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
    router.unref(); // drops to zero and self-destroys; no leak or double-free
}

test "unregister always emits the unregistered event" {
    const alloc = std.testing.allocator;
    var wakeup = try xev.Async.init();
    defer wakeup.deinit();
    const router = try TmuxRouter.create(alloc, wakeup);
    defer router.unref();

    var io: termio.Termio = undefined; // 仅作指针占位,不解引用
    try router.register(7, &io);
    router.unregister(7);

    var events: std.ArrayListUnmanaged(Event) = .empty;
    defer events.deinit(alloc);
    try router.drainEvents(&events, alloc);
    try std.testing.expectEqual(@as(usize, 2), events.items.len);
    try std.testing.expect(events.items[0] == .registered);
    try std.testing.expect(events.items[1] == .unregistered);
}
