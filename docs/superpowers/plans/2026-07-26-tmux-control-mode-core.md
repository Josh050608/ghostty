# tmux 控制模式 · 计划一:Zig 核心管道 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 打通 tmux -CC 从 pty 到 macOS 的完整核心管道:窗口结构事件经 apprt action 到达 Swift(本计划仅打日志),pane 内容/输入经新的 `TmuxPane` termio 后端与 `TmuxRouter` 双向路由。

**Architecture:** Viewer(宿主 IO 线程)扩展出 pane 生命周期状态机与外部命令入口;新组件 `TmuxRouter`(引用计数 + 互斥锁)承担跨线程路由:pane 注册/反注册、`%output` 字节投递、`send-keys` 命令回传;apprt 新增 `.tmux` action 把窗口列表(扁平化布局树)送到 Swift。对应设计文档:`docs/superpowers/specs/2026-07-26-tmux-control-mode-macos-design.md`(阶段 1–2)。阶段 3–5(macOS UI)由计划二覆盖,在本计划完成后另行撰写。

**Tech Stack:** Zig(0.15+ 风格:unmanaged ArrayList、`std.Io`)、libxev(`xev.Async`)、libghostty C ABI、Swift(仅一个日志 case)。

## Global Constraints

- 构建:`zig build`(macOS 上加 `-Demit-macos-app=false` 提速);测试:`zig build test -Dtest-filter=<test name>`(完整套件很慢,必须用过滤)。
- 格式化:每个任务提交前跑 `zig fmt .`;Swift 文件跑 `swiftlint lint --strict --fix`。
- tmux 控制模式核心受 `build_options.tmux_control_mode` 门控;`stream_handler.zig` 中一切 viewer/router 相关代码必须包在 `comptime tmux_enabled` 判断内(现有代码已是此风格,照抄)。
- 新增 Zig 文件的 import 风格照抄邻近文件(如 `xev`、`global.io()` 的 import 方式抄 `src/termio/mailbox.zig` 的头部)。
- `include/ghostty.h` 中新增 enum 跟随该文件现有 action enum 风格(无 `_MAX_VALUE` 哨兵——那条规则只适用于 `include/ghostty/vt/`);每个新 enum 在 action.zig 加 `lib.checkGhosttyHEnum` 测试(照抄 `OpenUrl.Kind` 的做法)。
- 禁止创建 issue 或 PR(CLAUDE.md)。
- **git 注意**:本目录当前不是 git 仓库。执行前先 `git init && git add -A && git commit -m "baseline"`;若用户不想引入 git,跳过各任务的 Commit 步骤。
- 线程契约(全计划成立的前提,写代码时时刻对照):
  - Viewer 只在宿主 IO 线程被访问(`processOutput` 持有宿主 renderer 锁时,或 `tmuxDrainRouter` 主动加锁时)。
  - 锁顺序:宿主 renderer 锁 → router 锁 → pane renderer 锁;pane 线程取 router 锁时绝不持有任何 renderer 锁。
  - 宿主 termio 邮箱是 SPSC,pane 线程**不得**向它 push;pane → 宿主一律走 `TmuxRouter` 的事件队列 + `xev.Async` 唤醒。

---

### Task 1: output.zig — `window_name` 变量与"末字段取余"解析

**Files:**
- Modify: `src/terminal/tmux/output.zig`
- Test: 同文件底部(该文件已有内联测试)

**Interfaces:**
- Produces: `Variable.window_name`(解析为 `[]const u8` 透传);`pub fn parseFormatStructRest(comptime T: type, str: []const u8, delimiter: u8) ParseError!T` —— 与 `parseFormatStruct` 相同,但**最后一个**字段用 `it.rest()` 取整行剩余(允许含分隔符,如带空格的窗口名);末字段缺失时得到空串而非报错。

**背景:** `list_windows` 格式用空格作分隔符,而 tmux 窗口名可含任意字符。把 `window_name` 放在格式串**最后**并用取余解析是唯一稳妥做法。

- [ ] **Step 1: 写失败测试**

在 `output.zig` 底部现有测试区追加:

```zig
test "parseFormatStructRest last field takes remainder" {
    const T = FormatStruct(&.{ .window_id, .window_name });
    const v = try parseFormatStructRest(T, "@5 my window name", ' ');
    try std.testing.expectEqual(@as(usize, 5), v.window_id);
    try std.testing.expectEqualStrings("my window name", v.window_name);
}

test "parseFormatStructRest empty last field" {
    const T = FormatStruct(&.{ .window_id, .window_name });
    const v = try parseFormatStructRest(T, "@5 ", ' ');
    try std.testing.expectEqualStrings("", v.window_name);
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `zig build test -Dtest-filter=parseFormatStructRest`
Expected: 编译错误 —— `window_name` 和 `parseFormatStructRest` 未定义。

- [ ] **Step 3: 实现**

① 在 `Variable` enum 中 `window_layout`(约 163 行)之后插入:

```zig
    /// Window name. User-settable and may contain any character,
    /// including format delimiters, so it must be the LAST variable
    /// in a format parsed with parseFormatStructRest.
    window_name,
```

② 在 `Variable.parse`(约 169 行起)和其配套的 `Type()` 函数里,找到 `.window_layout` 所在的字符串透传 prong(返回 `value` 原样 / 类型为 `[]const u8` 的那个分支),把 `.window_name` 加进同一 prong。

③ 在 `parseFormatStruct`(16 行)后新增:

```zig
/// Same as parseFormatStruct but the LAST field consumes the rest of
/// the string (it may contain the delimiter). Use this when the final
/// variable can contain arbitrary text, e.g. window_name.
pub fn parseFormatStructRest(
    comptime T: type,
    str: []const u8,
    delimiter: u8,
) ParseError!T {
    const fields = @typeInfo(T).@"struct".fields;
    var it = std.mem.splitScalar(u8, str, delimiter);
    var result: T = undefined;
    inline for (fields, 0..) |field, i| {
        const part = if (comptime i == fields.len - 1)
            it.rest()
        else
            it.next() orelse return error.MissingEntry;
        @field(result, field.name) = Variable.parse(
            @field(Variable, field.name),
            part,
        ) catch return error.FormatError;
    }
    return result;
}
```

注意:`it.rest()` 在前面的 `next()` 之后返回剩余未消费部分;单字段时返回整串,两者皆是想要的语义。

- [ ] **Step 4: 跑测试确认通过**

Run: `zig build test -Dtest-filter=parseFormatStructRest`
Expected: PASS(2 个测试)。再跑 `zig build test -Dtest-filter=tmux` 确认没破坏现有 tmux 测试。

- [ ] **Step 5: 格式化并提交**

```bash
zig fmt src/terminal/tmux/output.zig
git add src/terminal/tmux/output.zig
git commit -m "feat(tmux): add window_name variable and rest-parsing for formats"
```

---

### Task 2: viewer — `Window.name` 与 `%window-renamed`

**Files:**
- Modify: `src/terminal/tmux/viewer.zig`

**Interfaces:**
- Consumes: Task 1 的 `Variable.window_name`、`parseFormatStructRest`。
- Produces: `Viewer.Window` 新增字段 `name: []const u8`(由该窗口的 `layout_arena` 持有);`%window-renamed` 触发含 `.windows` 的 action。

- [ ] **Step 1: 写失败测试**

viewer.zig 底部测试区(1503 行起)已有用 `testViewer`/`TestStep` 的完整 attach 流程测试。先找到一个走完 `list-windows` 的现成测试(搜 `contains_command = "list-windows"`),照它的结构追加:

```zig
test "window name parsed and renamed" {
    const alloc = testing.allocator;
    var v: Viewer = try .init(testing.io, alloc);
    defer v.deinit();

    try testViewer(&v, &.{
        // 启动:初始块 + session-changed(抄现有测试的前两步)
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{ .id = 0, .name = "test" } } },
            .contains_command = "display-message",
        },
        // tmux version 响应
        .{ .input = .{ .tmux = .{ .block_end = "3.5a" } }, .contains_command = "list-windows" },
        // list-windows 响应:注意 window_name 在最后,含空格
        .{
            .input = .{ .tmux = .{ .block_end = "$0 @1 80 24 b25f,80x24,0,0,0 my editor\n" } },
            .contains_tags = &.{.windows},
            .check = (struct {
                fn check(viewer: *Viewer, actions: []const Viewer.Action) !void {
                    _ = actions;
                    try testing.expectEqualStrings("my editor", viewer.windows.items[0].name);
                }
            }).check,
        },
    });
}
```

注意:layout 串 `b25f,80x24,0,0,0` 的 checksum 前缀必须合法。抄现有测试里已验证过的 layout 串(搜 `,80x24,0,0`),不要自己编 checksum;若现有串无 name 列,仅在行尾追加 ` my editor`。

再加改名测试(在上述测试通过 list-windows 后追加步骤):

```zig
        // %window-renamed 更新名字并发出 windows action
        .{
            .input = .{ .tmux = .{ .window_renamed = .{ .id = 1, .name = "vim" } } },
            .contains_tags = &.{.windows},
            .check = (struct {
                fn check(viewer: *Viewer, actions: []const Viewer.Action) !void {
                    _ = actions;
                    try testing.expectEqualStrings("vim", viewer.windows.items[0].name);
                }
            }).check,
        },
```

- [ ] **Step 2: 跑测试确认失败**

Run: `zig build test -Dtest-filter="window name"`
Expected: 编译错误(`Window` 无 `name` 字段)。

- [ ] **Step 3: 实现**

① `Window` 结构(247 行)加字段:

```zig
    pub const Window = struct {
        id: usize,
        name: []const u8,
        width: usize,
        height: usize,
        layout_arena: ArenaAllocator.State,
        layout: Layout,
        ...
```

② `Format.list_windows`(1401 行)的 `vars` 末尾追加 `.window_name`(必须最后)。

③ `receivedListWindows`(850 行):把 `output.parseFormatStruct` 换成 `output.parseFormatStructRest`;`windows.append` 时加 `.name = try window_alloc.dupe(u8, data.window_name),`(`window_alloc` 是该窗口 arena,已有)。

④ `nextCommand` 中 `.window_renamed => {}`(523 行)改为:

```zig
            .window_renamed => |info| self.windowRenamed(
                &actions,
                info.id,
                info.name,
            ) catch {
                log.warn("failed to handle window rename, becoming defunct", .{});
                return self.defunct();
            },
```

⑤ 新增方法(放在 `windowAdd` 后面):

```zig
    /// A window was renamed. Update our state and notify the caller
    /// via a windows action.
    fn windowRenamed(
        self: *Viewer,
        actions: *std.ArrayList(Action),
        window_id: usize,
        name: []const u8,
    ) !void {
        const window: *Window = for (self.windows.items) |*w| {
            if (w.id == window_id) break w;
        } else {
            log.info("rename for unknown window id={}", .{window_id});
            return;
        };

        // Dupe into the window's arena. Repeated renames leak within
        // the arena until the window is replaced; names are tiny so
        // this is acceptable.
        {
            var arena = window.layout_arena.promote(self.alloc);
            defer window.layout_arena = arena.state;
            window.name = try arena.allocator().dupe(u8, name);
        }

        var arena = self.action_arena.promote(self.alloc);
        defer self.action_arena = arena.state;
        try actions.append(arena.allocator(), .{ .windows = self.windows.items });
    }
```

⑥ `sessionChanged` 无需改动(整体重建)。检查文件里其它构造 `Window` 的位置(grep `\.layout_arena =`),都补上 `.name`。

- [ ] **Step 4: 跑测试确认通过**

Run: `zig build test -Dtest-filter="window name"` → PASS;`zig build test -Dtest-filter=tmux` → 全绿(现有 list-windows 测试若因缺 name 列失败,给测试输入行尾补一个名字列,这是格式变更的预期影响)。

- [ ] **Step 5: 格式化并提交**

```bash
zig fmt src/terminal/tmux/viewer.zig
git add src/terminal/tmux/viewer.zig
git commit -m "feat(tmux): track window names, handle %window-renamed"
```

---

### Task 3: viewer — pane 生命周期状态机与新 action/input

**Files:**
- Modify: `src/terminal/tmux/viewer.zig`

**Interfaces:**
- Produces(后续任务依赖的精确签名):
  - `Viewer.Pane = struct { state: PaneState }`,`PaneState = union(enum) { loading: Loading, attached, detached }`,`Loading = struct { terminal: Terminal, take_pending: bool = false }`
  - `Viewer.Input` 新增:`pane_registered: usize`、`pane_unregistered: usize`
  - `Viewer.Action` 新增:
    - `pane_output: struct { pane_id: usize, data: []const u8 }`(data 存活于 action arena,下次 `next()` 前有效)
    - `pane_take: struct { pane_id: usize, terminal: *Terminal }`(terminal 在 gpa 堆上,接收方负责 `deinit` + `destroy` 或移走)
    - `pane_gone: usize`(注册了一个 viewer 不认识的 pane)

**语义(实现与测试的判定标准):**
- `loading`:viewer 持有 Terminal;capture/`%output` 直接灌入。
- `pane_registered`:pane 就绪(该 pane 无排队中的 `pane_history`/`pane_visible`,且无排队中的 `pane_state`)→ Terminal 搬到堆上、状态转 `attached`、发 `pane_take`;未就绪 → `take_pending = true`,待其就绪(每次命令完成后检查)再发;pane 不存在 → 发 `pane_gone`。
- `attached`:`%output` → 发 `pane_output`(数据拷入 action arena);capture 类输出到达时忽略并 log。
- `pane_unregistered`:`attached → detached`(输出丢弃);`loading` → 清 `take_pending`;未知 id → log 忽略。
- `syncLayouts` 剪枝:只有 `loading` 状态需要 `terminal.deinit`;`attached`/`detached` 的 Terminal 不归 viewer 管。
- `detached` pane 再次 `pane_registered`:发 `pane_gone`(MVP 不支持重连,GUI 靠 windows diff 收敛)。

- [ ] **Step 1: 写失败测试**

追加。前置步骤从现有测试复制:`test "initial flow"`(1614 行)是单窗单 pane 的完整 attach 序列(启动块 → session-changed → version → list-windows → 4 个 capture 响应 → pane_state 响应),`test "two pane flow with pane state"`(2111 行)是双 pane 版本。下面注释里的 `<...>` 指从 "initial flow" 里复制的对应步骤段:

```zig
test "pane registered after ready emits pane_take" {
    const alloc = testing.allocator;
    var v: Viewer = try .init(testing.io, alloc);
    defer v.deinit();

    try testViewer(&v, &.{
        // <启动到 list-windows 响应的步骤,含 4 个 capture 响应与
        //  pane_state 响应,抄现有测试;pane id 用 %0>
        // 全部 capture 完成后注册:
        .{
            .input = .{ .pane_registered = 0 },
            .contains_tags = &.{.pane_take},
            .check = (struct {
                fn check(viewer: *Viewer, actions: []const Viewer.Action) !void {
                    // viewer 侧转为 attached
                    try testing.expect(viewer.panes.get(0).?.state == .attached);
                    // 拿到的 terminal 必须由我们清理,否则测试泄漏
                    for (actions) |a| if (a == .pane_take) {
                        a.pane_take.terminal.deinit(testing.allocator);
                        testing.allocator.destroy(a.pane_take.terminal);
                    };
                }
            }).check,
        },
        // attach 后 %output 变成 pane_output 转发
        .{
            .input = .{ .tmux = .{ .output = .{ .pane_id = 0, .data = "hello" } } },
            .contains_tags = &.{.pane_output},
        },
        // 反注册后输出被丢弃
        .{ .input = .{ .pane_unregistered = 0 } },
        .{ .input = .{ .tmux = .{ .output = .{ .pane_id = 0, .data = "x" } } } },
    });
}

test "pane registered during capture defers take" {
    const alloc = testing.allocator;
    var v: Viewer = try .init(testing.io, alloc);
    defer v.deinit();

    try testViewer(&v, &.{
        // <启动到 list-windows 响应,但只喂前 2 个 capture 响应>
        // capture 未完:注册只挂起,不发 pane_take
        .{ .input = .{ .pane_registered = 0 } },
        // <喂剩余 capture 响应>
        // 最后 pane_state 响应完成时,pane_take 才出现
        .{
            .input = .{ .tmux = .{ .block_end = "<pane_state 响应行,抄现有测试>" } },
            .contains_tags = &.{.pane_take},
            .check = (struct {
                fn check(viewer: *Viewer, actions: []const Viewer.Action) !void {
                    _ = viewer;
                    for (actions) |a| if (a == .pane_take) {
                        a.pane_take.terminal.deinit(testing.allocator);
                        testing.allocator.destroy(a.pane_take.terminal);
                    };
                }
            }).check,
        },
    });
}

test "pane_registered unknown pane emits pane_gone" {
    const alloc = testing.allocator;
    var v: Viewer = try .init(testing.io, alloc);
    defer v.deinit();

    try testViewer(&v, &.{
        // <启动到 list-windows 响应的步骤>
        .{
            .input = .{ .pane_registered = 99 },
            .contains_tags = &.{.pane_gone},
        },
    });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `zig build test -Dtest-filter="pane registered"`
Expected: 编译错误(Input/Action 无新变体)。

- [ ] **Step 3: 实现**

① `Pane`(259 行)重定义:

```zig
    pub const Pane = struct {
        state: PaneState,

        pub const PaneState = union(enum) {
            /// Viewer owns the terminal; captures and %output feed it.
            loading: Loading,
            /// Terminal ownership was transferred via pane_take.
            attached,
            /// The surface went away; output is dropped.
            detached,

            pub const Loading = struct {
                terminal: Terminal,
                /// A registration arrived before captures finished.
                take_pending: bool = false,
            };
        };

        pub fn deinit(self: *Pane, alloc: Allocator) void {
            switch (self.state) {
                .loading => |*l| l.terminal.deinit(alloc),
                .attached, .detached => {},
            }
        }
    };
```

② `Input`(242 行)加:

```zig
        /// A pane surface registered with the router and wants to take
        /// over the pane terminal.
        pane_registered: usize,

        /// A pane surface unregistered (it is being torn down).
        pane_unregistered: usize,
```

③ `Action`(199 行)加(`format` 方法用现有 inline for 通用打印,无需改):

```zig
        /// Output for a pane that is attached. Data lives in the action
        /// arena and is valid until the next call to next().
        pane_output: struct {
            pane_id: usize,
            data: []const u8,
        },

        /// Transfer ownership of a pane terminal to the caller. The
        /// terminal is heap-allocated with the viewer's gpa; the caller
        /// must move it out and destroy the pointer (or deinit+destroy).
        pane_take: struct {
            pane_id: usize,
            terminal: *Terminal,
        },

        /// A pane surface registered for a pane we don't know about.
        pane_gone: usize,
```

④ `next()`(318 行)分发:

```zig
        return switch (input) {
            .tmux => self.nextTmux(input.tmux),
            .pane_registered => |id| self.paneRegistered(id),
            .pane_unregistered => |id| self.paneUnregistered(id),
        };
```

⑤ 新方法(放在 `nextCommand` 后):

```zig
    fn paneRegistered(self: *Viewer, id: usize) []const Action {
        // Reset the arena; we may emit an action.
        {
            var arena = self.action_arena.promote(self.alloc);
            _ = arena.reset(.free_all);
            self.action_arena = arena.state;
        }

        const entry = self.panes.getEntry(id) orelse
            return self.singleAction(.{ .pane_gone = id });
        const pane: *Pane = entry.value_ptr;
        switch (pane.state) {
            .attached, .detached => return self.singleAction(.{ .pane_gone = id }),
            .loading => |*l| {
                if (self.paneBusy(id)) {
                    l.take_pending = true;
                    return &.{};
                }
                return self.takePane(id) orelse self.defunct();
            },
        }
    }

    fn paneUnregistered(self: *Viewer, id: usize) []const Action {
        const entry = self.panes.getEntry(id) orelse return &.{};
        const pane: *Pane = entry.value_ptr;
        switch (pane.state) {
            .loading => |*l| l.take_pending = false,
            .attached => pane.state = .detached,
            .detached => {},
        }
        return &.{};
    }

    /// True while commands that populate this pane are still queued.
    fn paneBusy(self: *Viewer, id: usize) bool {
        var it = self.command_queue.iterator(.forward);
        while (it.next()) |cmd| switch (cmd.*) {
            .pane_history, .pane_visible => |cap| if (cap.id == id) return true,
            .pane_state => return true,
            else => {},
        };
        return false;
    }

    /// Move the pane terminal to the heap and emit pane_take.
    /// Returns null on allocation failure (caller should go defunct).
    fn takePane(self: *Viewer, id: usize) ?[]const Action {
        const entry = self.panes.getEntry(id) orelse return &.{};
        const pane: *Pane = entry.value_ptr;
        assert(pane.state == .loading);

        const t = self.alloc.create(Terminal) catch return null;
        t.* = pane.state.loading.terminal;
        pane.state = .attached;
        return self.singleAction(.{ .pane_take = .{
            .pane_id = id,
            .terminal = t,
        } });
    }
```

注意 `paneBusy` 的 union 捕获:`.pane_history, .pane_visible => |cap|` 两个变体 payload 同型(`CapturePane`)才能这样合并;它们确实同型。

⑥ `receivedOutput`(1105 行)改为按状态分派。它在 `nextCommand` 的 `.output` 分支被调用,而那条分支不会向 `actions` 追加——把调用点改成传入 `&actions`:

```zig
            .output => |out| self.receivedOutput(
                &actions,
                out.pane_id,
                out.data,
            ) catch |err| { ... 原样 ... },
```

```zig
    fn receivedOutput(
        self: *Viewer,
        actions: *std.ArrayList(Action),
        id: usize,
        data: []const u8,
    ) !void {
        const entry = self.panes.getEntry(id) orelse {
            log.info("received output for untracked pane id={}", .{id});
            return;
        };
        const pane: *Pane = entry.value_ptr;
        switch (pane.state) {
            .loading => |*l| {
                const t: *Terminal = &l.terminal;
                var stream = t.vtStream();
                defer stream.deinit();
                stream.nextSlice(data);
            },
            .attached => {
                var arena = self.action_arena.promote(self.alloc);
                defer self.action_arena = arena.state;
                const arena_alloc = arena.allocator();
                try actions.append(arena_alloc, .{ .pane_output = .{
                    .pane_id = id,
                    .data = try arena_alloc.dupe(u8, data),
                } });
            },
            .detached => {},
        }
    }
```

⑦ `receivedPaneHistory` / `receivedPaneVisible` / `receivedPaneState`:取 pane 后先判状态,非 `loading` 则 `log.info` + 跳过;terminal 取址改为 `&pane.state.loading.terminal`。

⑧ `initLayout`(1122 行)leaf 分支构造改为:

```zig
                gop.value_ptr.* = .{ .state = .{ .loading = .{ .terminal = t } } };
```

⑨ 延迟 take 的触发:在 `receivedCommandOutput`(765 行)末尾(命令 switch 之后)追加:

```zig
        // A command completing may unblock pending takes.
        var it = self.panes.iterator();
        while (it.next()) |kv| {
            const pane: *Pane = kv.value_ptr;
            switch (pane.state) {
                .loading => |l| if (l.take_pending and !self.paneBusy(kv.key_ptr.*)) {
                    const taken = self.takePane(kv.key_ptr.*) orelse
                        return error.OutOfMemory;
                    try actions.appendSlice(arena_alloc, taken);
                },
                else => {},
            }
        }
```

注意:`takePane` 返回的 slice 是 `action_single`(单元素缓冲),同一轮多个 pane 就绪时会互相覆盖——所以 `appendSlice` 后即失效没问题,但**不能**先收集再统一 append。逐个 take、逐个 append(上面代码已是如此)。

⑩ `deinit`(293 行)的 panes 清理已改走 `Pane.deinit`(①中实现),无需再改。

- [ ] **Step 4: 跑测试确认通过**

Run: `zig build test -Dtest-filter="pane registered"` → PASS;`zig build test -Dtest-filter=tmux` → 全绿(现有测试若直接访问 `pane.terminal`,改为 `pane.state.loading.terminal`)。

- [ ] **Step 5: 格式化并提交**

```bash
zig fmt src/terminal/tmux/viewer.zig
git add src/terminal/tmux/viewer.zig
git commit -m "feat(tmux): pane attach lifecycle with terminal ownership transfer"
```

---

### Task 4: viewer — `Input.send_command`

**Files:**
- Modify: `src/terminal/tmux/viewer.zig`

**Interfaces:**
- Produces: `Viewer.Input` 新增 `send_command: []const u8`(调用期内有效,viewer 自行 dupe;必须以 `\n` 结尾)。行为:非 `command_queue` 状态 → log 丢弃;队列空 → 入队并立即发 `.command` action;队列非空 → 仅入队(前一命令完成时由 `nextCommand` 既有逻辑发出)。

- [ ] **Step 1: 写失败测试**

前置步骤照抄 `test "initial flow"`(viewer.zig 1614 行)的完整序列(启动块 → session-changed → version → list-windows → capture → pane_state,走到队列清空为止);注释里 `<...>` 即指该段:

```zig
test "send_command queues and emits" {
    const alloc = testing.allocator;
    var v: Viewer = try .init(testing.io, alloc);
    defer v.deinit();

    try testViewer(&v, &.{
        // <启动到 list-windows 响应 + capture/pane_state 全部完成,队列空>
        // 队列空:立即发出
        .{
            .input = .{ .send_command = "send-keys -t %0 -H 68 69\n" },
            .contains_command = "send-keys -t %0 -H 68 69",
        },
        // 前一命令未完成:仅入队
        .{ .input = .{ .send_command = "send-keys -t %0 -H 6a\n" } },
        // 前一命令完成:下一条自动发出(nextCommand 既有逻辑)
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "send-keys -t %0 -H 6a",
        },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
    });
}

test "send_command before ready is dropped" {
    const alloc = testing.allocator;
    var v: Viewer = try .init(testing.io, alloc);
    defer v.deinit();
    // startup_block 状态直接发:不 crash、无 action
    const actions = v.next(.{ .send_command = "kill-window -t @1\n" });
    try testing.expectEqual(@as(usize, 0), actions.len);
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `zig build test -Dtest-filter=send_command`
Expected: 编译错误(Input 无 `send_command`)。

- [ ] **Step 3: 实现**

① `Input` 加变体:

```zig
        /// Send a raw command to tmux through the command queue. The
        /// string must include the trailing newline. The memory only
        /// needs to live for the duration of the call.
        send_command: []const u8,
```

② `next()` 分发加 `.send_command => |cmd| self.sendCommand(cmd),`。

③ 新方法:

```zig
    fn sendCommand(self: *Viewer, cmd: []const u8) []const Action {
        assert(cmd.len > 0 and cmd[cmd.len - 1] == '\n');
        if (self.state != .command_queue) {
            log.info("dropping command, viewer not ready state={}", .{self.state});
            return &.{};
        }

        const was_empty = self.command_queue.empty();
        const owned = self.alloc.dupe(u8, cmd) catch return self.defunct();
        self.queueCommands(&.{.{ .user = owned }}) catch {
            self.alloc.free(owned);
            return self.defunct();
        };
        if (!was_empty) return &.{};

        // Nothing in flight: emit the command immediately. The command
        // string for .user is the command itself; reference the queued
        // copy which lives until the command completes.
        return self.singleAction(.{ .command = owned });
    }
```

注意:`.command` action 直接引用入队的 `owned`,其生命周期到命令完成(`receivedCommandOutput` 里 `command.deinit`)为止,而 caller 在下一次 `next()` 前就会消费掉 action,安全。

- [ ] **Step 4: 跑测试确认通过**

Run: `zig build test -Dtest-filter=send_command` → PASS;`zig build test -Dtest-filter=tmux` → 全绿。

- [ ] **Step 5: 格式化并提交**

```bash
zig fmt src/terminal/tmux/viewer.zig
git add src/terminal/tmux/viewer.zig
git commit -m "feat(tmux): accept external commands via Input.send_command"
```

---

### Task 5: `TmuxRouter` — 跨线程路由器

**Files:**
- Create: `src/termio/TmuxRouter.zig`
- Modify: `src/termio.zig`(导出)

**Interfaces:**
- Produces(精确签名,后续任务依赖):

```zig
pub const TmuxRouter = @This();
pub const Event = union(enum) {
    registered: usize,
    unregistered: usize,
    command: []u8, // router.alloc 所有,消费方负责 free
};
pub fn create(alloc: Allocator, wakeup: xev.Async) Allocator.Error!*TmuxRouter
pub fn ref(self: *TmuxRouter) void
pub fn unref(self: *TmuxRouter) void          // 归零时自毁
pub fn register(self: *TmuxRouter, pane_id: usize, io: *termio.Termio) Allocator.Error!void
pub fn unregister(self: *TmuxRouter, pane_id: usize) void
pub fn sendCommand(self: *TmuxRouter, cmd: []const u8) Allocator.Error!void
pub fn drainEvents(self: *TmuxRouter, out: *std.ArrayList(Event), alloc: Allocator) Allocator.Error!void
pub fn route(self: *TmuxRouter, pane_id: usize, data: []const u8) bool
pub fn replaceTerminal(self: *TmuxRouter, pane_id: usize, t: *terminal.Terminal) bool
```

- 线程契约写进文件顶部注释:`register/unregister/sendCommand` 任意线程(pane IO 线程);`drainEvents/route/replaceTerminal` 仅宿主 IO 线程;所有公开方法内部持 `mutex`;`route` 持锁调用 pane 的 `processOutput`(保证 unregister 同步互斥,pane 的 Termio 在 unregister 返回后绝不再被触碰)。

- [ ] **Step 1: 写失败测试**

文件底部:

```zig
test "router events round trip" {
    const alloc = std.testing.allocator;
    var wakeup = try xev.Async.init();
    defer wakeup.deinit();

    const router = try TmuxRouter.create(alloc, wakeup);
    defer router.unref();

    try router.sendCommand("list-windows\n");

    var events: std.ArrayList(Event) = .empty;
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
    router.unref(); // 归零自毁;测试通过 = 无泄漏无 double-free
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `zig build test -Dtest-filter=router`
Expected: 编译错误(文件不存在/未导出)。

- [ ] **Step 3: 实现**

`src/termio/TmuxRouter.zig`(import 行照抄 `src/termio/mailbox.zig` 头部的 `std`/`xev`/`termio` 引法,另加 `terminal`):

```zig
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

mutex: std.Thread.Mutex = .{},
alloc: Allocator,
refs: std.atomic.Value(usize),
wakeup: xev.Async,
panes: std.AutoHashMapUnmanaged(usize, *termio.Termio) = .empty,
events: std.ArrayList(Event) = .empty,

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
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.panes.put(self.alloc, pane_id, io);
        try self.events.append(self.alloc, .{ .registered = pane_id });
    }
    self.wakeup.notify() catch |err| {
        log.warn("tmux router wakeup failed err={}", .{err});
    };
}

pub fn unregister(self: *TmuxRouter, pane_id: usize) void {
    {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.panes.remove(pane_id);
        self.events.append(self.alloc, .{ .unregistered = pane_id }) catch |err| {
            log.warn("tmux router event dropped err={}", .{err});
        };
    }
    self.wakeup.notify() catch {};
}

pub fn sendCommand(self: *TmuxRouter, cmd: []const u8) Allocator.Error!void {
    {
        self.mutex.lock();
        defer self.mutex.unlock();
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
/// caller, which must free them with this router's alloc... (they are
/// allocated with router.alloc; the host and router share the surface
/// gpa in practice, but free via router.alloc to be exact).
pub fn drainEvents(
    self: *TmuxRouter,
    out: *std.ArrayList(Event),
    alloc: Allocator,
) Allocator.Error!void {
    self.mutex.lock();
    defer self.mutex.unlock();
    try out.appendSlice(alloc, self.events.items);
    self.events.clearRetainingCapacity();
}

/// Host IO thread: feed pane output. Returns false if unknown pane.
pub fn route(self: *TmuxRouter, pane_id: usize, data: []const u8) bool {
    self.mutex.lock();
    defer self.mutex.unlock();
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
    t: *terminal.Terminal,
) bool {
    self.mutex.lock();
    defer self.mutex.unlock();
    const io = self.panes.get(pane_id) orelse return false;
    io.tmuxReplaceTerminal(t);
    return true;
}
```

顶部补 `const log = std.log.scoped(.tmux_router);` 与各 import。`src/termio.zig` 加 `pub const TmuxRouter = @import("termio/TmuxRouter.zig");`,并确认该文件的 `test { refAllDecls }` 模式会带上新文件(照抄现有导出的写法)。

注:`io.tmuxReplaceTerminal` 到 Task 6 才存在——本任务测试只覆盖 events/refcount,route/replaceTerminal 留待 Task 6 编译。为让本任务能独立编译,`replaceTerminal` 这一步可先写好但 Task 6 未合入前不要引用;Zig 惰性分析下未被引用的方法不会编译失败,测试只 refAllDecls 时会——如遇编译错误,把 `replaceTerminal` 的实现体临时改为 `_ = t; return false;` 并在 Task 6 恢复(在代码旁留一行注释 `// Task 6 restores the real body`)。

- [ ] **Step 4: 跑测试确认通过**

Run: `zig build test -Dtest-filter=router` → PASS。

- [ ] **Step 5: 格式化并提交**

```bash
zig fmt src/termio/TmuxRouter.zig src/termio.zig
git add src/termio/TmuxRouter.zig src/termio.zig
git commit -m "feat(termio): add TmuxRouter for cross-thread pane routing"
```

---

### Task 6: Termio — `tmuxReplaceTerminal` 与路由器排水钩子

**Files:**
- Modify: `src/termio/Termio.zig`
- Modify: `src/termio/Thread.zig`
- Modify: `src/termio/stream_handler.zig`(仅加 `tmux_router` 字段占位,布线在 Task 8)

**Interfaces:**
- Consumes: Task 5 的 `TmuxRouter.drainEvents`;Task 3/4 的 viewer inputs。
- Produces:
  - `Termio.tmuxReplaceTerminal(self: *Termio, t: *terminalpkg.Terminal) void` —— 在 pane 的 renderer 锁内换掉 `self.terminal` 并唤醒渲染器;`t` 被移走后 destroy。
  - `Termio.tmuxDrainRouter(self: *Termio) void` —— 宿主 IO 线程调用;无 router 时是空操作。
  - `StreamHandler` 新字段:`tmux_router: if (tmux_enabled) ?*termio.TmuxRouter else void = if (tmux_enabled) null else {}`
  - `StreamHandler.handleTmuxInput(self, input: terminal.tmux.Viewer.Input) void` —— Task 8 实现完整版;本任务先放一个转发 viewer 并处理 `.command` action 的最小版。

- [ ] **Step 1: 实现 `tmuxReplaceTerminal`**

`Termio.zig`(`processOutput`,643 行附近之后)追加。renderer 锁的加锁写法照抄 `processOutput`(643-650 行)里的现成模式:

```zig
/// Replace our terminal with a tmux-captured one. Called from the
/// host surface's IO thread via TmuxRouter while it holds the router
/// mutex; we take our own renderer lock here (lock order: router ->
/// our renderer mutex).
pub fn tmuxReplaceTerminal(self: *Termio, t: *terminalpkg.Terminal) void {
    {
        // 加锁/解锁写法抄 processOutput
        self.renderer_state.mutex.lockUncancelable(global.io());
        defer self.renderer_state.mutex.unlock(global.io());
        self.terminal.deinit(self.alloc);
        self.terminal = t.*;
    }
    self.alloc.destroy(t);
    self.renderer_wakeup.notify() catch |err| {
        log.warn("failed to notify renderer err={}", .{err});
    };
}
```

注意:`renderer_state.terminal` 指向 `&self.io.terminal`(字段地址),按值替换不改变地址,渲染器指针依然有效。**不做** resize——pane 表面首次布局时会走正常 resize 消息把网格调对(计划二覆盖)。若 `lockUncancelable`/`global.io()` 与该文件实际写法不符,以 `processOutput` 的实际代码为准。

- [ ] **Step 2: 实现 `tmuxDrainRouter` + StreamHandler 字段与最小版 `handleTmuxInput`**

① `stream_handler.zig` 字段区(69 行 `tmux_viewer` 旁)加:

```zig
    /// The tmux pane router, created together with the viewer.
    tmux_router: if (tmux_enabled) ?*termio.TmuxRouter else void =
        if (tmux_enabled) null else {},
```

② `stream_handler.zig` 加方法(dcsCommand 附近;完整版 Task 8 替换):

```zig
    /// Feed an input into the tmux viewer and process the resulting
    /// actions. Task 8 extends this to handle all action types.
    pub fn handleTmuxInput(
        self: *StreamHandler,
        input: terminal.tmux.Viewer.Input,
    ) void {
        if (comptime !tmux_enabled) return;
        const viewer = self.tmux_viewer orelse return;
        for (viewer.next(input)) |action| switch (action) {
            .command => |command| {
                self.messageWriter(termio.Message.writeReq(
                    self.alloc,
                    command,
                ) catch |err| {
                    log.warn("tmux command dropped err={}", .{err});
                    return;
                });
            },
            else => log.info("tmux action (unhandled until task 8)={f}", .{action}),
        };
    }
```

③ `Termio.zig` 追加:

```zig
/// Drain pending TmuxRouter events (pane registrations and commands
/// from pane surfaces). Called on our IO thread after each mailbox
/// drain. No-op when tmux control mode is inactive.
pub fn tmuxDrainRouter(self: *Termio) void {
    if (comptime !StreamHandler.tmux_enabled) return;
    const handler = &self.terminal_stream.handler;
    const router = handler.tmux_router orelse return;

    var events: std.ArrayList(termio.TmuxRouter.Event) = .empty;
    defer events.deinit(self.alloc);
    router.drainEvents(&events, self.alloc) catch |err| {
        log.warn("tmux router drain failed err={}", .{err});
        return;
    };
    if (events.items.len == 0) return;

    // Viewer access requires the renderer mutex (same contract as
    // processOutput). 加锁写法抄 processOutput。
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());

    for (events.items) |ev| switch (ev) {
        .registered => |id| handler.handleTmuxInput(.{ .pane_registered = id }),
        .unregistered => |id| handler.handleTmuxInput(.{ .pane_unregistered = id }),
        .command => |cmd| {
            defer router.alloc.free(cmd);
            handler.handleTmuxInput(.{ .send_command = cmd });
        },
    };
}
```

`StreamHandler.tmux_enabled` 是既有公开常量(stream_handler.zig 83 行)。若 `Termio.zig` 未 import `StreamHandler`,它已有 `const StreamHandler = @import("stream_handler.zig").StreamHandler;` 之类(terminal_stream 的类型来源),照实际调整。

④ `Thread.zig` 的 `wakeupCallback`(441 行),在 `cb.self.drainMailbox(cb) catch ...`(455 行)之后追加一行(字段名以该文件 `CallbackData` 实际定义为准,`io` 即 `*Termio`):

```zig
    cb.io.tmuxDrainRouter();
```

- [ ] **Step 3: 编译验证**

Run: `zig build -Demit-macos-app=false`
Expected: 编译通过。若 Task 5 中 `replaceTerminal` 用了临时体,现在恢复真实现并重编译。

- [ ] **Step 4: 跑既有测试确认无回归**

Run: `zig build test -Dtest-filter=tmux`
Expected: 全绿(本任务纯布线,无新单测;行为由 Task 8 的端到端路径覆盖)。

- [ ] **Step 5: 格式化并提交**

```bash
zig fmt src/termio/Termio.zig src/termio/Thread.zig src/termio/stream_handler.zig
git add src/termio/Termio.zig src/termio/Thread.zig src/termio/stream_handler.zig
git commit -m "feat(termio): terminal takeover and router drain hooks"
```

---

### Task 7: `TmuxPane` termio 后端

**Files:**
- Create: `src/termio/TmuxPane.zig`
- Modify: `src/termio/backend.zig`(四个 union 各加一臂)
- Modify: `src/termio.zig`(导出)

**Interfaces:**
- Consumes: Task 5 `TmuxRouter.register/unregister/sendCommand/ref/unref`。
- Produces:

```zig
pub const TmuxPane = @This();
pub const Config = struct { router: *termio.TmuxRouter, pane_id: usize };
pub fn init(cfg: Config) TmuxPane            // 内部 router.ref()
pub fn deinit(self: *TmuxPane) void          // router.unref()
pub fn threadEnter(self: *TmuxPane, alloc: Allocator, io: *termio.Termio, td: *termio.Termio.ThreadData) !void
pub fn threadExit(self: *TmuxPane, td: *termio.Termio.ThreadData) void
pub fn queueWrite(self: *TmuxPane, alloc: Allocator, td: *termio.Termio.ThreadData, data: []const u8, linefeed: bool) !void
```

- backend.zig `Kind` 变为 `enum { exec, tmux_pane }`;`Config`/`Backend`/`ThreadData` 三个 union 各加 `tmux_pane` 臂,所有方法 switch 补齐(`tmux_pane` 的 ThreadData 是 `void`)。

- [ ] **Step 1: 写失败测试**

`TmuxPane.zig` 底部:

```zig
test "queueWrite encodes send-keys hex chunks" {
    const alloc = std.testing.allocator;
    var wakeup = try xev.Async.init();
    defer wakeup.deinit();
    const router = try termio.TmuxRouter.create(alloc, wakeup);
    defer router.unref();

    var pane = TmuxPane.init(.{ .router = router, .pane_id = 5 });
    defer pane.deinit();

    // td 参数在 tmux_pane 实现中未使用,传 undefined 即可
    try pane.queueWrite(alloc, undefined, "hi\r", false);

    var events: std.ArrayList(termio.TmuxRouter.Event) = .empty;
    defer {
        for (events.items) |ev| switch (ev) {
            .command => |c| alloc.free(c),
            else => {},
        };
        events.deinit(alloc);
    }
    try router.drainEvents(&events, alloc);
    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqualStrings(
        "send-keys -t %5 -H 68 69 0d\n",
        events.items[0].command,
    );
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `zig build test -Dtest-filter="send-keys hex"`
Expected: 编译错误(文件不存在)。

- [ ] **Step 3: 实现**

`src/termio/TmuxPane.zig`(import 照抄 `Exec.zig` 头部风格,精简到用到的):

```zig
//! Termio backend for a tmux pane surface. There is no subprocess and
//! no pty: input is translated to tmux `send-keys` commands routed to
//! the host surface via TmuxRouter, and output arrives when the host
//! calls our Termio.processOutput through the router.

const TmuxPane = @This();

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

/// Max bytes per send-keys command. Keeps commands well under any
/// tmux line-length limits while amortizing command overhead.
const WRITE_CHUNK = 64;

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

    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();

    var i: usize = 0;
    while (i < data.len) {
        const chunk = data[i..@min(data.len, i + WRITE_CHUNK)];
        i += chunk.len;

        buf.clearRetainingCapacity();
        try buf.writer.print("send-keys -t %{d} -H", .{self.pane_id});
        for (chunk) |b| try buf.writer.print(" {x:0>2}", .{b});
        try buf.writer.writeByte('\n');
        try self.router.sendCommand(buf.writer.buffered());
    }
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
```

`Allocating` writer 若无 `clearRetainingCapacity`,改为每 chunk 重新 `init/deinit`(以 std 实际 API 为准)。

`backend.zig`:`Kind` 加 `tmux_pane`;`Config` union 加 `tmux_pane: termio.TmuxPane.Config`;`Backend` union 加 `tmux_pane: termio.TmuxPane`;`ThreadData` union 加 `tmux_pane: void`;每个方法的 switch 加对应臂(模式与 exec 臂完全一致,`ThreadData.deinit` 的 `tmux_pane` 臂为空操作)。`src/termio.zig` 加 `pub const TmuxPane = @import("termio/TmuxPane.zig");`。

- [ ] **Step 4: 跑测试确认通过**

Run: `zig build test -Dtest-filter="send-keys hex"` → PASS;`zig build -Demit-macos-app=false` → 编译通过。

- [ ] **Step 5: 格式化并提交**

```bash
zig fmt src/termio/TmuxPane.zig src/termio/backend.zig src/termio.zig
git add src/termio/TmuxPane.zig src/termio/backend.zig src/termio.zig
git commit -m "feat(termio): TmuxPane backend translating input to send-keys"
```

---

### Task 8: stream_handler 完整布线 + 窗口事件序列化

**Files:**
- Modify: `src/termio/stream_handler.zig`
- Modify: `src/apprt/surface.zig`(Message 新变体 + TmuxEvent 类型)
- Test: `src/termio/stream_handler.zig` 底部(该文件已有测试)

**Interfaces:**
- Consumes: Task 3/4 viewer actions、Task 5/6/7 router 与后端。
- Produces:
  - `apprt.surface.TmuxEvent`(堆分配,`deinit` 自毁):

```zig
pub const TmuxEvent = struct {
    alloc: Allocator,
    arena_state: ArenaAllocator.State,
    event: Event,

    pub const Event = union(enum) {
        attach: struct { router: *anyopaque },
        windows: struct { windows: []const Window, nodes: []const Node },
        exit,
    };

    /// 布局树扁平化:nodes 数组,children 用 [start, start+len) 区间表示,
    /// 每窗口 root 是 nodes 下标。
    pub const Window = struct {
        id: usize,
        name: [:0]const u8,
        width: usize,
        height: usize,
        root: usize,
    };

    pub const Node = struct {
        kind: enum { pane, horizontal, vertical },
        pane_id: usize, // kind == .pane 时有效
        x: usize,
        y: usize,
        width: usize,
        height: usize,
        children_start: usize,
        children_len: usize,
    };

    pub fn deinit(self: *TmuxEvent) void; // 内部用 arena 实现整体释放
};
```

  - `apprt.surface.Message` 新变体:`tmux: *TmuxEvent`(接收方 `defer ev.deinit()`)。
  - `stream_handler` 内部:`handleTmuxInput` 完整版(所有 action);`serializeTmuxWindows(self, windows: []const terminal.tmux.Viewer.Window) !*TmuxEvent`。
  - `.enter` 时创建 router 并发 `attach` 事件;`.exit`/`deinit` 时发 `exit` 事件并 `unref` router。

- [ ] **Step 1: 写失败测试(序列化纯函数)**

stream_handler.zig 底部(测试可直接构造 viewer Window/Layout;Layout 内容用手工构造而非解析,避免 checksum):

```zig
test "serialize tmux windows flattens layout tree" {
    if (comptime !StreamHandler.tmux_enabled) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    const Layout = terminal.tmux.Layout;
    const children: [2]Layout = .{
        .{ .width = 40, .height = 24, .x = 0, .y = 0, .content = .{ .pane = 1 } },
        .{ .width = 39, .height = 24, .x = 41, .y = 0, .content = .{ .pane = 2 } },
    };
    const windows: [1]terminal.tmux.Viewer.Window = .{.{
        .id = 7,
        .name = "main",
        .width = 80,
        .height = 24,
        .layout_arena = .{},
        .layout = .{
            .width = 80,
            .height = 24,
            .x = 0,
            .y = 0,
            .content = .{ .horizontal = &children },
        },
    }};

    const ev = try StreamHandler.serializeTmuxWindowsAlloc(alloc, &windows);
    defer ev.deinit();

    const w = ev.event.windows;
    try std.testing.expectEqual(@as(usize, 1), w.windows.len);
    try std.testing.expectEqualStrings("main", w.windows[0].name);
    // 根节点 + 两个子节点
    try std.testing.expectEqual(@as(usize, 3), w.nodes.len);
    const root = w.nodes[w.windows[0].root];
    try std.testing.expect(root.kind == .horizontal);
    try std.testing.expectEqual(@as(usize, 2), root.children_len);
    const c0 = w.nodes[root.children_start];
    try std.testing.expect(c0.kind == .pane);
    try std.testing.expectEqual(@as(usize, 1), c0.pane_id);
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `zig build test -Dtest-filter="serialize tmux"`
Expected: 编译错误。

- [ ] **Step 3: 实现**

① `src/apprt/surface.zig`:按上方接口块原样加入 `TmuxEvent`(`deinit` 实现:构造时把所有内存分配在一个 `ArenaAllocator` 里,`TmuxEvent` 自身也在 arena 内,`deinit` 就是 `arena.promote(alloc).deinit()`——把 `arena_state: ArenaAllocator.State` 和真正的 gpa `alloc` 存在字段里);`Message` union 加:

```zig
    /// Tmux control mode state change destined for the apprt.
    /// Receiver must call deinit().
    tmux: *TmuxEvent,
```

② `stream_handler.zig` 序列化(两个入口:成员方法用 `self.alloc`,测试用静态版):

```zig
    pub fn serializeTmuxWindowsAlloc(
        alloc: Allocator,
        windows: []const terminal.tmux.Viewer.Window,
    ) !*apprt.surface.TmuxEvent {
        var arena: ArenaAllocator = .init(alloc);
        errdefer arena.deinit();
        const a = arena.allocator();

        var nodes: std.ArrayList(apprt.surface.TmuxEvent.Node) = .empty;
        var out_windows: std.ArrayList(apprt.surface.TmuxEvent.Window) = .empty;
        for (windows) |*w| {
            const root = try flattenLayout(a, &nodes, &w.layout);
            try out_windows.append(a, .{
                .id = w.id,
                .name = try a.dupeZ(u8, w.name),
                .width = w.width,
                .height = w.height,
                .root = root,
            });
        }

        const ev = try a.create(apprt.surface.TmuxEvent);
        ev.* = .{
            .alloc = alloc,
            .arena_state = undefined, // set below, after last arena use
            .event = .{ .windows = .{
                .windows = out_windows.items,
                .nodes = nodes.items,
            } },
        };
        ev.arena_state = arena.state;
        return ev;
    }

    /// Flatten a layout tree into `nodes` post-order (children first),
    /// returning the index of this subtree's root node.
    fn flattenLayout(
        a: Allocator,
        nodes: *std.ArrayList(apprt.surface.TmuxEvent.Node),
        layout: *const terminal.tmux.Layout,
    ) !usize {
        var node: apprt.surface.TmuxEvent.Node = .{
            .kind = undefined,
            .pane_id = 0,
            .x = layout.x,
            .y = layout.y,
            .width = layout.width,
            .height = layout.height,
            .children_start = 0,
            .children_len = 0,
        };
        switch (layout.content) {
            .pane => |id| {
                node.kind = .pane;
                node.pane_id = id;
            },
            inline .horizontal, .vertical => |children, tag| {
                node.kind = switch (tag) {
                    .horizontal => .horizontal,
                    .vertical => .vertical,
                    else => unreachable,
                };
                // Children must be contiguous: flatten each child's
                // subtree first, then record our children as a run of
                // root indices... contiguity requires indirection:
                // collect child root indices, then append a contiguous
                // "child ref" run.
                var child_roots: std.ArrayList(usize) = .empty;
                defer child_roots.deinit(a);
                for (children) |*c| {
                    try child_roots.append(a, try flattenLayout(a, nodes, c));
                }
                // Re-append shallow copies of child roots contiguously.
                node.children_start = nodes.items.len;
                node.children_len = child_roots.items.len;
                for (child_roots.items) |idx| {
                    try nodes.append(a, nodes.items[idx]);
                }
            },
        }
        try nodes.append(a, node);
        return nodes.items.len - 1;
    }
```

**注意上面 `flattenLayout` 的关键决定**:为了让"某节点的孩子"是 `nodes` 里一段连续区间,分裂节点先递归扁平化孩子子树,再把每个孩子的根节点**浅拷贝**成连续一段。孩子根的拷贝与原件字段完全一致(区间引用不受拷贝影响,因为引用的是下标且原件保留),消费方只按 `children_start/len` 区间遍历即可正确重建整棵树。嵌套分裂在真实 tmux 布局中层级很浅(≤5),重复少量节点无妨。测试断言按此语义写(根的 children 区间与子树根内容一致)。

③ `TmuxEvent` 字段对齐②:`alloc: Allocator, arena_state: ArenaAllocator.State, event: Event`,`deinit`:

```zig
    pub fn deinit(self: *TmuxEvent) void {
        var arena = self.arena_state.promote(self.alloc);
        arena.deinit(); // frees self too; do not touch self afterwards
    }
```

④ `handleTmuxInput` 完整版(替换 Task 6 的最小版;同时把 `dcsCommand` 里原来的 action 循环删掉,统一改调 `self.handleTmuxActions(viewer.next(...))` 风格——具体:`dcsCommand` 的 `.tmux` 分支中 `for (viewer.next(...)) |action| {...}` 整段换成 `self.handleTmuxActions(viewer.next(.{ .tmux = tmux }));`):

```zig
    fn handleTmuxActions(
        self: *StreamHandler,
        actions: []const terminal.tmux.Viewer.Action,
    ) void {
        if (comptime !tmux_enabled) return;
        for (actions) |action| {
            log.info("tmux viewer action={f}", .{action});
            switch (action) {
                .exit => self.tmuxExit(),

                .command => |command| {
                    assert(command.len > 0);
                    assert(command[command.len - 1] == '\n');
                    self.messageWriter(termio.Message.writeReq(
                        self.alloc,
                        command,
                    ) catch |err| {
                        log.warn("tmux command dropped err={}", .{err});
                        continue;
                    });
                },

                .windows => |windows| {
                    const ev = serializeTmuxWindowsAlloc(
                        self.alloc,
                        windows,
                    ) catch |err| {
                        log.warn("tmux windows event dropped err={}", .{err});
                        continue;
                    };
                    self.surfaceMessageWriter(.{ .tmux = ev });
                },

                .pane_output => |out| {
                    const router = self.tmux_router orelse continue;
                    if (!router.route(out.pane_id, out.data)) {
                        log.info(
                            "tmux output for unrouted pane id={}",
                            .{out.pane_id},
                        );
                    }
                },

                .pane_take => |take| {
                    const router = self.tmux_router orelse {
                        take.terminal.deinit(self.alloc);
                        self.alloc.destroy(take.terminal);
                        continue;
                    };
                    if (!router.replaceTerminal(take.pane_id, take.terminal)) {
                        take.terminal.deinit(self.alloc);
                        self.alloc.destroy(take.terminal);
                    }
                },

                // Plan 2: GUI 收到 windows diff 后会关闭陈旧 surface,
                // 此处仅记录。
                .pane_gone => |id| log.info("tmux pane gone id={}", .{id}),
            }
        }
    }

    /// Tear down tmux state and notify the apprt.
    fn tmuxExit(self: *StreamHandler) void {
        if (comptime !tmux_enabled) return;

        if (self.tmux_viewer) |viewer| {
            viewer.deinit();
            self.alloc.destroy(viewer);
            self.tmux_viewer = null;
        }
        if (self.tmux_router) |router| {
            router.unref();
            self.tmux_router = null;
        }

        const ev = apprt.surface.TmuxEvent.initExit(self.alloc) catch |err| {
            log.warn("tmux exit event dropped err={}", .{err});
            return;
        };
        self.surfaceMessageWriter(.{ .tmux = ev });
    }
```

同时 `handleTmuxInput`(Task 6 的最小版)的最终形态是一个薄封装,`Termio.tmuxDrainRouter` 继续调它:

```zig
    pub fn handleTmuxInput(
        self: *StreamHandler,
        input: terminal.tmux.Viewer.Input,
    ) void {
        if (comptime !tmux_enabled) return;
        const viewer = self.tmux_viewer orelse return;
        self.handleTmuxActions(viewer.next(input));
    }
```

`exit`/`attach` 事件构造为 `TmuxEvent` 的两个辅助构造器(放 apprt/surface.zig,arena 模式同 `serializeTmuxWindowsAlloc`:创建 arena → 在 arena 内 create TmuxEvent → 填 `alloc`/`arena_state`/`event`):

```zig
    pub fn initExit(gpa: Allocator) Allocator.Error!*TmuxEvent {
        var arena: ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const ev = try arena.allocator().create(TmuxEvent);
        ev.* = .{ .alloc = gpa, .arena_state = arena.state, .event = .exit };
        return ev;
    }

    pub fn initAttach(
        gpa: Allocator,
        router: *anyopaque,
    ) Allocator.Error!*TmuxEvent {
        var arena: ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const ev = try arena.allocator().create(TmuxEvent);
        ev.* = .{
            .alloc = gpa,
            .arena_state = arena.state,
            .event = .{ .attach = .{ .router = router } },
        };
        return ev;
    }
```

(注意 `arena.state` 必须在最后一次 arena 分配**之后**读取;上面两个构造器中 create 是唯一分配,赋值顺序已满足。)

⑤ `dcsCommand` 的 `.enter` 分支(stream_handler.zig 390 行起)在创建 viewer 的同时创建 router 并发 attach:

```zig
                    .enter => {
                        assert(self.tmux_viewer == null);
                        const viewer = try self.alloc.create(terminal.tmux.Viewer);
                        errdefer self.alloc.destroy(viewer);
                        viewer.* = try .init(global.io(), self.alloc);
                        errdefer viewer.deinit();

                        const router = try termio.TmuxRouter.create(
                            self.alloc,
                            self.termio_mailbox.spsc.wakeup,
                        );
                        errdefer router.unref();

                        // Create the attach event BEFORE assigning our
                        // fields: on error the errdefers free viewer and
                        // router, so the fields must not point at them yet.
                        const ev = try apprt.surface.TmuxEvent.initAttach(
                            self.alloc,
                            router,
                        );

                        self.tmux_viewer = viewer;
                        self.tmux_router = router;
                        self.surfaceMessageWriter(.{ .tmux = ev });
                        break :tmux;
                    },
```

⑥ `.exit` 分支与 `deinit`(88 行)改为调 `self.tmuxExit()`(deinit 里只清理、不发消息也可以——deinit 时 surface 也在销毁,直接 viewer/router 清理即可;保持 deinit 现有结构,补 router unref)。

⑦ `.tmux` 通知分发处(432 行)整段换成 `self.handleTmuxActions(viewer.next(.{ .tmux = tmux }));`。

- [ ] **Step 4: 跑测试确认通过**

Run: `zig build test -Dtest-filter="serialize tmux"` → PASS;`zig build test -Dtest-filter=tmux` → 全绿;`zig build -Demit-macos-app=false` → 编译通过。

- [ ] **Step 5: 格式化并提交**

```bash
zig fmt src/termio/stream_handler.zig src/apprt/surface.zig
git add src/termio/stream_handler.zig src/apprt/surface.zig
git commit -m "feat(tmux): wire viewer actions to router and surface events"
```

---

### Task 9: apprt `.tmux` action、C API 与 Swift 日志

**Files:**
- Modify: `src/apprt/action.zig`
- Modify: `src/Surface.zig`(handleMessage 转发)
- Modify: `include/ghostty.h`
- Modify: `macos/Sources/Ghostty/Ghostty.App.swift`

**Interfaces:**
- Consumes: Task 8 的 `apprt.surface.Message.tmux` / `TmuxEvent`。
- Produces: `apprt.Action.tmux: Tmux`;C 侧 `GHOSTTY_ACTION_TMUX` + `ghostty_action_tmux_s`。

- [ ] **Step 1: action.zig 定义(照 `KeyTable` 的 Tag/CValue/C/cval 模式)**

```zig
    /// Tmux control mode state changes. See apprt.surface.TmuxEvent
    /// for the semantics; payload memory is only valid during the
    /// action callback and must be copied by the apprt.
    tmux: Tmux,
```

```zig
pub const Tmux = union(enum) {
    attach: Attach,
    windows: Windows,
    exit,

    // Sync with: ghostty_action_tmux_attach_s
    pub const Attach = extern struct {
        /// Opaque TmuxRouter pointer; pass back verbatim in the
        /// surface config of each pane surface.
        router: ?*anyopaque,
    };

    // Sync with: ghostty_action_tmux_node_s
    pub const Node = extern struct {
        kind: Kind,
        pane_id: usize,
        x: usize,
        y: usize,
        width: usize,
        height: usize,
        children_start: usize,
        children_len: usize,

        // Sync with: ghostty_action_tmux_node_kind_e
        pub const Kind = enum(c_int) {
            pane,
            horizontal,
            vertical,

            test "ghostty.h Tmux.Node.Kind" {
                try lib.checkGhosttyHEnum(
                    Kind,
                    "GHOSTTY_ACTION_TMUX_NODE_KIND_",
                );
            }
        };
    };

    // Sync with: ghostty_action_tmux_window_s
    pub const CWindow = extern struct {
        id: usize,
        name: [*:0]const u8,
        width: usize,
        height: usize,
        root: usize,
    };

    pub const Windows = struct {
        windows: []const CWindow,
        nodes: []const Node,

        // Sync with: ghostty_action_tmux_windows_s
        pub const C = extern struct {
            windows: ?[*]const CWindow,
            windows_len: usize,
            nodes: ?[*]const Node,
            nodes_len: usize,
        };

        pub fn cval(self: Windows) C {
            return .{
                .windows = if (self.windows.len > 0) self.windows.ptr else null,
                .windows_len = self.windows.len,
                .nodes = if (self.nodes.len > 0) self.nodes.ptr else null,
                .nodes_len = self.nodes.len,
            };
        }
    };

    // Sync with: ghostty_action_tmux_tag_e
    pub const Tag = enum(c_int) {
        attach,
        windows,
        exit,

        test "ghostty.h Tmux.Tag" {
            try lib.checkGhosttyHEnum(Tag, "GHOSTTY_TMUX_");
        }
    };

    // Sync with: ghostty_action_tmux_u
    pub const CValue = extern union {
        attach: Attach,
        windows: Windows.C,
    };

    // Sync with: ghostty_action_tmux_s
    pub const C = extern struct {
        tag: Tag,
        value: CValue,
    };

    pub fn cval(self: Tmux) C {
        return switch (self) {
            .attach => |v| .{ .tag = .attach, .value = .{ .attach = v } },
            .windows => |v| .{ .tag = .windows, .value = .{ .windows = v.cval() } },
            .exit => .{ .tag = .exit, .value = undefined },
        };
    }
};
```

同时:`Key` enum 加 `tmux`(grep `.key_table` 在 action.zig 出现的**每一处**——Key 定义、可能的 scope/文档注释表——都镜像补一条)。

注意:`Node`/`CWindow` 与 Task 8 `TmuxEvent.Node/Window` 字段一一对应但类型不同(extern + C 指针 vs 普通 Zig 类型)。两套类型都保留(apprt/surface.zig 不 import action 类型,避免引入循环依赖风险),在 Surface.handleMessage 做显式转换;`TmuxEvent.Node.kind` 的成员顺序必须与 `Tmux.Node.Kind` 一致(pane/horizontal/vertical),转换时逐字段映射、不依赖内存布局。

- [ ] **Step 2: Surface.zig handleMessage 转发(含显式转换)**

在 handleMessage 的 switch(参考 `.color_change` 分支,1011 行)加。`performAction` 是同步调用,返回后即可释放临时数组:

```zig
            .tmux => |ev| {
                defer ev.deinit();
                switch (ev.event) {
                    .attach => |v| _ = try self.rt_app.performAction(
                        .{ .surface = self },
                        .tmux,
                        .{ .attach = .{ .router = v.router } },
                    ),

                    .exit => _ = try self.rt_app.performAction(
                        .{ .surface = self },
                        .tmux,
                        .exit,
                    ),

                    .windows => |w| {
                        const Tmux = apprt.action.Tmux;
                        const c_windows = try self.alloc.alloc(
                            Tmux.CWindow,
                            w.windows.len,
                        );
                        defer self.alloc.free(c_windows);
                        for (w.windows, c_windows) |src, *dst| dst.* = .{
                            .id = src.id,
                            .name = src.name.ptr,
                            .width = src.width,
                            .height = src.height,
                            .root = src.root,
                        };

                        const c_nodes = try self.alloc.alloc(
                            Tmux.Node,
                            w.nodes.len,
                        );
                        defer self.alloc.free(c_nodes);
                        for (w.nodes, c_nodes) |src, *dst| dst.* = .{
                            .kind = switch (src.kind) {
                                .pane => .pane,
                                .horizontal => .horizontal,
                                .vertical => .vertical,
                            },
                            .pane_id = src.pane_id,
                            .x = src.x,
                            .y = src.y,
                            .width = src.width,
                            .height = src.height,
                            .children_start = src.children_start,
                            .children_len = src.children_len,
                        };

                        _ = try self.rt_app.performAction(
                            .{ .surface = self },
                            .tmux,
                            .{ .windows = .{
                                .windows = c_windows,
                                .nodes = c_nodes,
                            } },
                        );
                    },
                }
            },
```

(`src.name` 是 Task 8 里的 `[:0]const u8`,`.ptr` 即 `[*:0]const u8`,与 `CWindow.name` 类型吻合。)

- [ ] **Step 3: ghostty.h**

在 action 相关声明区(`ghostty_action_key_table_s` 附近,765-783 行风格)加:

```c
// apprt.action.Tmux.Tag
typedef enum {
  GHOSTTY_TMUX_ATTACH,
  GHOSTTY_TMUX_WINDOWS,
  GHOSTTY_TMUX_EXIT,
} ghostty_action_tmux_tag_e;

// apprt.action.Tmux.Attach
typedef struct {
  void* router;
} ghostty_action_tmux_attach_s;

// apprt.action.Tmux.Node.Kind
typedef enum {
  GHOSTTY_ACTION_TMUX_NODE_KIND_PANE,
  GHOSTTY_ACTION_TMUX_NODE_KIND_HORIZONTAL,
  GHOSTTY_ACTION_TMUX_NODE_KIND_VERTICAL,
} ghostty_action_tmux_node_kind_e;

// apprt.action.Tmux.Node
typedef struct {
  ghostty_action_tmux_node_kind_e kind;
  uintptr_t pane_id;
  uintptr_t x;
  uintptr_t y;
  uintptr_t width;
  uintptr_t height;
  uintptr_t children_start;
  uintptr_t children_len;
} ghostty_action_tmux_node_s;

// apprt.action.Tmux.CWindow
typedef struct {
  uintptr_t id;
  const char* name;
  uintptr_t width;
  uintptr_t height;
  uintptr_t root;
} ghostty_action_tmux_window_s;

// apprt.action.Tmux.Windows.C
typedef struct {
  const ghostty_action_tmux_window_s* windows;
  uintptr_t windows_len;
  const ghostty_action_tmux_node_s* nodes;
  uintptr_t nodes_len;
} ghostty_action_tmux_windows_s;

// apprt.action.Tmux.CValue
typedef union {
  ghostty_action_tmux_attach_s attach;
  ghostty_action_tmux_windows_s windows;
} ghostty_action_tmux_u;

// apprt.action.Tmux.C
typedef struct {
  ghostty_action_tmux_tag_e tag;
  ghostty_action_tmux_u value;
} ghostty_action_tmux_s;
```

`ghostty_action_tag_e` 末尾(GHOSTTY_ACTION_COPY_TITLE_TO_CLIPBOARD 后)加 `GHOSTTY_ACTION_TMUX,`;`ghostty_action_u` union 定义处加 `ghostty_action_tmux_s tmux;`(位置与其他成员并列,grep `ghostty_action_u` 找到定义)。

- [ ] **Step 4: 验证 header 同步测试**

Run: `zig build test -Dtest-filter="ghostty.h"`
Expected: PASS(`checkGhosttyHEnum` 校验新 enum 与 header 同步;action key 的顺序校验若存在也会在此暴露——`Key` enum 里 `tmux` 的位置必须与 `ghostty_action_tag_e` 中 `GHOSTTY_ACTION_TMUX` 的位置一致,都放在各自末尾)。

- [ ] **Step 5: Swift 日志 case**

`Ghostty.App.swift` 的 action switch(481-685 行)加:

```swift
        case GHOSTTY_ACTION_TMUX:
            tmux(app, target: target, v: action.action.tmux)
```

并加 handler(私有 static,放 colorChange 附近):

```swift
        private static func tmux(
            _ app: ghostty_app_t,
            target: ghostty_target_s,
            v: ghostty_action_tmux_s)
        {
            // Plan 1: log only. Plan 2 replaces this with the
            // TmuxSessionController pipeline.
            switch v.tag {
            case GHOSTTY_TMUX_ATTACH:
                Ghostty.logger.info("tmux: attach")
            case GHOSTTY_TMUX_WINDOWS:
                let w = v.value.windows
                Ghostty.logger.info("tmux: windows count=\(w.windows_len) nodes=\(w.nodes_len)")
                if let windows = w.windows {
                    for i in 0..<w.windows_len {
                        let win = windows[i]
                        let name = String(cString: win.name)
                        Ghostty.logger.info("tmux: window id=\(win.id) name=\(name, privacy: .public) \(win.width)x\(win.height)")
                    }
                }
            case GHOSTTY_TMUX_EXIT:
                Ghostty.logger.info("tmux: exit")
            default:
                Ghostty.logger.warning("tmux: unknown tag=\(v.tag.rawValue)")
            }
        }
```

- [ ] **Step 6: 全量编译 + 提交**

```bash
zig build          # 含 macOS app
swiftlint lint --strict --fix macos/Sources/Ghostty/Ghostty.App.swift
zig fmt src/apprt/action.zig src/Surface.zig
git add src/apprt/action.zig src/Surface.zig include/ghostty.h macos/Sources/Ghostty/Ghostty.App.swift
git commit -m "feat(apprt): tmux action pipeline through C API to macOS"
```

---

### Task 10: pane surface 配置字段(C API → 核心后端选择)

**Files:**
- Modify: `include/ghostty.h`(surface config)
- Modify: `src/apprt/embedded.zig`
- Modify: `src/Surface.zig`(termio 后端选择)

**Interfaces:**
- Produces:
  - `ghostty_surface_config_s` 末尾新增:`void* tmux_router; uintptr_t tmux_pane_id;`(router 为 NULL 表示普通 surface)。
  - embedded `Surface.Options` 对应字段:`tmux_router: ?*anyopaque = null, tmux_pane_id: usize = 0`。
  - embedded `Surface` 新方法:`pub fn tmuxPane(self: *const Surface) ?apprt.surface.TmuxPane`,其中 `apprt.surface.TmuxPane = struct { router: *anyopaque, pane_id: usize }`(加在 apprt/surface.zig)。
  - 核心 `Surface.init`:若 rt_surface 报告 tmux pane,则 termio 后端用 `.tmux_pane`,跳过 Exec 构造。

- [ ] **Step 1: ghostty.h + embedded 字段**

`ghostty_surface_config_s`(467-480 行)在 `context` 字段后加:

```c
  void* tmux_router;
  uintptr_t tmux_pane_id;
```

embedded.zig `Surface.Options`(426-466 行)末尾加:

```zig
    /// Opaque TmuxRouter pointer from the tmux attach action. When
    /// non-null this surface is a tmux pane surface for tmux_pane_id
    /// and no subprocess is started.
    tmux_router: ?*anyopaque = null,
    tmux_pane_id: usize = 0,
```

embedded `Surface` struct 加字段存下来(init 里 `self.* = .{...}` 处加 `.tmux_pane_opts = .{ .router = opts.tmux_router, .pane_id = opts.tmux_pane_id }`,字段类型 `struct { router: ?*anyopaque, pane_id: usize }`),并加方法:

```zig
    pub fn tmuxPane(self: *const Surface) ?apprt.surface.TmuxPane {
        const router = self.tmux_pane_opts.router orelse return null;
        return .{ .router = router, .pane_id = self.tmux_pane_opts.pane_id };
    }
```

`apprt/surface.zig` 加:

```zig
/// Identifies a surface as a tmux pane surface.
pub const TmuxPane = struct {
    router: *anyopaque,
    pane_id: usize,
};
```

- [ ] **Step 2: 核心 Surface.zig 后端选择**

在 termio 初始化处(652-681 行)改为:

```zig
    const tmux_pane: ?apprt.surface.TmuxPane =
        if (comptime @hasDecl(apprt.runtime.Surface, "tmuxPane"))
            rt_surface.tmuxPane()
        else
            null;

    var io_backend: termio.Backend = backend: {
        if (tmux_pane) |tp| break :backend .{ .tmux_pane = termio.TmuxPane.init(.{
            .router = @ptrCast(@alignCast(tp.router)),
            .pane_id = tp.pane_id,
        }) };

        break :backend .{ .exec = try termio.Exec.init(alloc, .{
            // 原 io_exec 初始化参数原样搬入
            ...
        }) };
    };
    errdefer io_backend.deinit();

    try termio.Termio.init(&self.io, alloc, .{
        ...
        .backend = io_backend,
        ...
    });
```

(把原 `var io_exec = ...; errdefer io_exec.deinit();` 两行删除,`.backend = .{ .exec = io_exec }` 改为 `.backend = io_backend`。)

- [ ] **Step 3: 编译验证**

Run: `zig build`(含 macOS app;Swift 侧 `SurfaceConfiguration.withCValue` 未设置新字段——C struct 新字段位于末尾且 `ghostty_surface_config_new()` 返回值已初始化为零/默认,NULL router 即普通 surface,无行为变化)。
Expected: 编译通过。

确认 `ghostty_surface_config_new` 的实现(embedded.zig,grep)返回的默认值把新字段置空;若它是 `std.mem.zeroes` 或字段默认值风格则天然满足。

- [ ] **Step 4: 跑既有测试**

Run: `zig build test -Dtest-filter=tmux`
Expected: 全绿。

- [ ] **Step 5: 格式化并提交**

```bash
zig fmt src/apprt/embedded.zig src/apprt/surface.zig src/Surface.zig
git add include/ghostty.h src/apprt/embedded.zig src/apprt/surface.zig src/Surface.zig
git commit -m "feat(core): tmux pane surface config selects TmuxPane backend"
```

---

### Task 11: 端到端冒烟验证

**Files:** 无新改动(验证任务)。

**前置:** 本机安装 tmux ≥ 3.2(`brew install tmux`;`tmux -V` 确认)。

- [ ] **Step 1: 构建并启动 app**

```bash
zig build
open zig-out/Ghostty.app   # 实际产物路径以 zig build 输出为准(macos/build 目录或 zig-out)
```

同时开日志窗口:

```bash
log stream --predicate 'subsystem CONTAINS "ghostty"' --level info | grep -i tmux
```

- [ ] **Step 2: attach 冒烟**

在 Ghostty 窗口里:

```bash
tmux -CC new-session -s smoke
```

Expected(日志中依序出现):
1. `tmux: attach`
2. `tmux viewer action=...command...`(list-windows 等启动命令)
3. `tmux: windows count=1 nodes=1`、`tmux: window id=... name=zsh 80x24`(名字随 shell)

- [ ] **Step 3: 双客户端输出路由冒烟**

另开一个普通终端:

```bash
tmux attach -t smoke   # 普通模式挂同一会话
echo hello-from-tmux
```

Expected:Ghostty 日志出现 `%output` 相关 `pane_output`/route 日志(pane 未注册时是 `tmux output for unrouted pane` ——**这是本计划的正确结果**,pane surface 要到计划二才创建);在普通客户端里 `tmux rename-window testname` 后,Ghostty 日志出现 `tmux: window ... name=testname`(验证 Task 1/2 的 rest-parse 与 rename 链路)。

- [ ] **Step 4: detach/exit 冒烟**

普通客户端里 `tmux kill-session -t smoke`。
Expected:Ghostty 日志出现 `tmux: exit`,宿主 surface 回到普通提示符,无崩溃;再跑一轮 Step 2 确认可重复 attach。

- [ ] **Step 5: 收尾提交**

```bash
zig fmt .
git add -A
git commit -m "chore(tmux): plan 1 core pipeline complete"
```

---

## 计划二预告(本计划完成后撰写)

覆盖 spec 阶段 3–5:Swift `TmuxSessionController`(attach 开专属窗口组、windows diff → 标签页、nodes → SplitTree、pane surface 创建时填 `tmux_router`/`tmux_pane_id`)、resize(`refresh-client -C`,经新增的 GUI→tmux 命令通道)、关闭映射(kill-pane/kill-window/detach)、焦点同步、版本门槛与竞态加固。GUI→tmux 命令通道将新增 `ghostty_surface_tmux_command()` C API,复用 Task 4 的 `Input.send_command`。
