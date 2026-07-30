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
//!   register: (panes_mutex segment: map insertion) → (events_mutex segment:
//!   event append) → notify. Never nests the two locks.
//!
//!   unregister: (events_mutex segment: capacity reserve) → (panes_mutex
//!   segment: pane removal) → (events_mutex segment: event append) → notify.
//!   Never nests the two locks. Uses events → panes → events pattern to
//!   pre-reserve the event slot before pane removal, ensuring the unregistered
//!   event cannot be lost due to OOM after the pane is already deleted.
//!
//!   Both are called from threadEnter/threadExit, which never hold a renderer
//!   mutex.
//!
//!   unref teardown takes neither lock: refcount == 0 guarantees
//!   exclusivity.

const TmuxRouter = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const global = @import("../global.zig");
const xev = global.xev;
const apprt = @import("../apprt.zig");
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
/// Set by close() when the tmux session ends. sendCommand/register/unregister
/// become silent no-ops after this is true.
closed: std.atomic.Value(bool) = .init(false),
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

/// Mark the router closed: the host surface's tmux session ended.
/// Subsequent sendCommand/register/unregister become silent no-ops so
/// late calls from the GUI or dying pane surfaces are harmless. The
/// panes map is NOT cleared here; pane surfaces still unregister
/// (no-op) and drop their refs normally.
pub fn close(self: *TmuxRouter) void {
    self.closed.store(true, .release);
}

/// Render a typed TmuxCommand into `buf` as a tmux control-mode string.
/// Returns the written slice. Pure function; no router state accessed.
pub fn formatCommand(
    buf: []u8,
    cmd: apprt.action.TmuxCommand,
) std.fmt.BufPrintError![]u8 {
    return switch (cmd.tag) {
        .kill_pane => std.fmt.bufPrint(buf, "kill-pane -t %{d}\n", .{cmd.id}),
        .kill_window => std.fmt.bufPrint(buf, "kill-window -t @{d}\n", .{cmd.id}),
        .detach => std.fmt.bufPrint(buf, "detach-client\n", .{}),
        .select_pane => std.fmt.bufPrint(buf, "select-pane -t %{d}\n", .{cmd.id}),
        .resize => std.fmt.bufPrint(buf, "refresh-client -C {d}x{d}\n", .{ cmd.width, cmd.height }),
        .new_window => std.fmt.bufPrint(buf, "new-window\n", .{}),
        .split_horizontal => if (cmd.width != 0)
            std.fmt.bufPrint(buf, "split-window -h -b -t %{d}\n", .{cmd.id})
        else
            std.fmt.bufPrint(buf, "split-window -h -t %{d}\n", .{cmd.id}),
        .split_vertical => if (cmd.width != 0)
            std.fmt.bufPrint(buf, "split-window -v -b -t %{d}\n", .{cmd.id})
        else
            std.fmt.bufPrint(buf, "split-window -v -t %{d}\n", .{cmd.id}),
        .select_window => std.fmt.bufPrint(buf, "select-window -t @{d}\n", .{cmd.id}),
        .rename_window => renameWindow(buf, cmd.id, cmd.text),
        .automatic_rename => std.fmt.bufPrint(buf, "set-window-option -t @{d} automatic-rename on\n", .{cmd.id}),
    };
}

/// Render rename-window with the name escaped for a tmux double-quoted
/// argument. Newlines/CR are stripped entirely (a newline terminates the
/// control-mode command — leaving one in would let a tab title inject a
/// second command); backslash, double-quote, `$`, and `~` are
/// backslash-escaped. `$` and `~` matter because tmux performs variable
/// expansion and home-directory expansion inside double-quoted strings —
/// left unescaped, `$SOME_VAR` leaks the shell's environment into the
/// window name and `~` expands to the user's home directory.
fn renameWindow(
    buf: []u8,
    id: usize,
    text: ?[*:0]const u8,
) std.fmt.BufPrintError![]u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.print("rename-window -t @{d} \"", .{id}) catch return error.NoSpaceLeft;
    if (text) |t| {
        for (std.mem.span(t)) |b| switch (b) {
            '\n', '\r' => {},
            '\\', '"', '$', '~' => {
                w.writeByte('\\') catch return error.NoSpaceLeft;
                w.writeByte(b) catch return error.NoSpaceLeft;
            },
            else => w.writeByte(b) catch return error.NoSpaceLeft,
        };
    }
    w.writeAll("\"\n") catch return error.NoSpaceLeft;
    return w.buffered();
}

pub fn register(
    self: *TmuxRouter,
    pane_id: usize,
    io: *termio.Termio,
) Allocator.Error!void {
    if (self.closed.load(.acquire)) return;
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
    if (self.closed.load(.acquire)) return;
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
    // Notify even if the event was dropped (OOM path) so the IO thread
    // observes the pane removal.
    self.wakeup.notify() catch {};
}

pub fn sendCommand(self: *TmuxRouter, cmd: []const u8) Allocator.Error!void {
    if (self.closed.load(.acquire)) return;
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

    var io: termio.Termio = undefined; // pointer placeholder only; never dereferenced
    try router.register(7, &io);
    router.unregister(7);

    var events: std.ArrayListUnmanaged(Event) = .empty;
    defer events.deinit(alloc);
    try router.drainEvents(&events, alloc);
    try std.testing.expectEqual(@as(usize, 2), events.items.len);
    try std.testing.expect(events.items[0] == .registered);
    try std.testing.expect(events.items[1] == .unregistered);
}

test "closed router drops commands silently" {
    const alloc = std.testing.allocator;
    var wakeup = try xev.Async.init();
    defer wakeup.deinit();
    const router = try TmuxRouter.create(alloc, wakeup);
    defer router.unref();

    router.close();
    try router.sendCommand("list-windows\n"); // 不得报错、不得入队

    var events: std.ArrayListUnmanaged(Event) = .empty;
    defer events.deinit(alloc);
    try router.drainEvents(&events, alloc);
    try std.testing.expectEqual(@as(usize, 0), events.items.len);
}

test "formatCommand renders each tag" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "kill-pane -t %7\n",
        try TmuxRouter.formatCommand(&buf, .{ .tag = .kill_pane, .id = 7 }),
    );
    try std.testing.expectEqualStrings(
        "kill-window -t @3\n",
        try TmuxRouter.formatCommand(&buf, .{ .tag = .kill_window, .id = 3 }),
    );
    try std.testing.expectEqualStrings(
        "detach-client\n",
        try TmuxRouter.formatCommand(&buf, .{ .tag = .detach }),
    );
    try std.testing.expectEqualStrings(
        "select-pane -t %2\n",
        try TmuxRouter.formatCommand(&buf, .{ .tag = .select_pane, .id = 2 }),
    );
    try std.testing.expectEqualStrings(
        "refresh-client -C 120x40\n",
        try TmuxRouter.formatCommand(&buf, .{ .tag = .resize, .width = 120, .height = 40 }),
    );
}

test "formatCommand renders plan3 tags" {
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings(
        "new-window\n",
        try TmuxRouter.formatCommand(&buf, .{ .tag = .new_window }),
    );
    try std.testing.expectEqualStrings(
        "split-window -h -t %7\n",
        try TmuxRouter.formatCommand(&buf, .{ .tag = .split_horizontal, .id = 7 }),
    );
    try std.testing.expectEqualStrings(
        "split-window -h -b -t %7\n",
        try TmuxRouter.formatCommand(&buf, .{ .tag = .split_horizontal, .id = 7, .width = 1 }),
    );
    try std.testing.expectEqualStrings(
        "split-window -v -t %2\n",
        try TmuxRouter.formatCommand(&buf, .{ .tag = .split_vertical, .id = 2 }),
    );
    try std.testing.expectEqualStrings(
        "split-window -v -b -t %2\n",
        try TmuxRouter.formatCommand(&buf, .{ .tag = .split_vertical, .id = 2, .width = 1 }),
    );
    try std.testing.expectEqualStrings(
        "select-window -t @3\n",
        try TmuxRouter.formatCommand(&buf, .{ .tag = .select_window, .id = 3 }),
    );
    try std.testing.expectEqualStrings(
        "rename-window -t @3 \"dev\"\n",
        try TmuxRouter.formatCommand(&buf, .{ .tag = .rename_window, .id = 3, .text = "dev" }),
    );
}

// GUI 改名清空为 nil/空串时不能发 rename-window ""(那会把 tmux 的
// automatic-rename 关掉并把标题卡在空串),而是要显式重新打开
// automatic-rename,让 tmux 自己生成名字并回声 %window-renamed,标题
// 经既有回流路径自然恢复。
test "formatCommand renders automatic_rename" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "set-window-option -t @5 automatic-rename on\n",
        try TmuxRouter.formatCommand(&buf, .{ .tag = .automatic_rename, .id = 5 }),
    );
}

test "formatCommand rename escapes injection vectors" {
    var buf: [512]u8 = undefined;
    // 反斜杠与双引号转义
    try std.testing.expectEqualStrings(
        "rename-window -t @1 \"a\\\\b\\\"c\"\n",
        try TmuxRouter.formatCommand(&buf, .{ .tag = .rename_window, .id = 1, .text = "a\\b\"c" }),
    );
    // 换行/回车剥除(控制模式里换行=命令分隔符,这是注入边界)
    try std.testing.expectEqualStrings(
        "rename-window -t @1 \"ab\"\n",
        try TmuxRouter.formatCommand(&buf, .{ .tag = .rename_window, .id = 1, .text = "a\nb\r" }),
    );
    // null text 渲染为空名
    try std.testing.expectEqualStrings(
        "rename-window -t @1 \"\"\n",
        try TmuxRouter.formatCommand(&buf, .{ .tag = .rename_window, .id = 1 }),
    );
    // $ 转义(未转义时 tmux 会在双引号内做变量展开,泄露环境变量值)
    try std.testing.expectEqualStrings(
        "rename-window -t @1 \"before \\$MYREALENV after\"\n",
        try TmuxRouter.formatCommand(&buf, .{ .tag = .rename_window, .id = 1, .text = "before $MYREALENV after" }),
    );
    // ~ 转义(未转义时 tmux 会展开成 HOME 路径)
    try std.testing.expectEqualStrings(
        "rename-window -t @1 \"\\~ x\"\n",
        try TmuxRouter.formatCommand(&buf, .{ .tag = .rename_window, .id = 1, .text = "~ x" }),
    );
}
