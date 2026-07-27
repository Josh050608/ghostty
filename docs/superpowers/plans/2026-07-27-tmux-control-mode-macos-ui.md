# tmux 控制模式 · 计划二:macOS UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 `tmux -CC attach` 在 Ghostty macOS 获得 iTerm2 式原生体验:先修复 DCS 裸转义序列杀死控制模式的成帧缺陷,再构建 macOS UI 层(tmux window → 原生标签页,pane → 原生分屏),打通输入、resize、关闭映射与 detach 收尾。

**Architecture:** Zig 侧:Stream 层在 tmux 控制模式活跃期间接管字节流绕过 VT 解析器(ESC 的 anywhere 转移不再误杀控制模式),control.zig idle 态容忍穿插的裸转义序列;TmuxRouter 增加 closed 标志与 GUI 持有引用,新增 `ghostty_tmux_router_command/release` C API(命令字符串拼接留在 Zig)。Swift 侧:`TmuxSessionManager` 按宿主 surface 追踪会话;`TmuxSessionController` 消费深拷贝的 tmux 事件,按窗口 id diff 出专属窗口组的原生标签页;扁平布局树经纯函数 `TmuxSplitLayout.build` 转成二叉 `SplitTree`;pane surface 带 `tmux_router`/`tmux_pane_id` 配置由核心自动选 TmuxPane 后端。对应设计文档:`docs/superpowers/specs/2026-07-26-tmux-control-mode-macos-design.md`(阶段 3–5)。

**Tech Stack:** Zig(0.16,unmanaged ArrayList、`std.Io`)、libghostty C ABI、Swift/AppKit(NSWindowTabGroup、SplitTree 值类型)、Swift Testing(`import Testing`)。

## Global Constraints

- 分支:一律在 `tmux-cc-core` 上开发(基线 HEAD `d895d4f66`)。**禁止**在 `tmux-cc-upstream` 上开发;禁止创建 issue/PR(CLAUDE.md)。
- zig 命令一律加代理剥离前缀:`env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY zig ...`(Clash TUN 会挂死 zig 的 HTTP 客户端;依赖已全在缓存)。下文写 `zig build` 时均指带此前缀。
- 测试永远用 `-Dtest-filter`;`--summary all` 有 ~70 个基线步骤,命中数 = 总数 − 70。当前 `-Dtest-filter=tmux` 基线 = **195/195**,本计划各任务会增加该数字,前一任务的新增计入后续任务的预期值。
- 每个 Zig 任务提交前:`zig fmt <改动文件>`;全量库构建检查 `zig build -Demit-macos-app=false`(计划一教训:过滤测试放过了非穷尽 switch)。
- 每个 Swift 任务提交前:先 `zig build -Demit-macos-app=false`(刷新 GhosttyKit),再 `xcodebuild -project macos/Ghostty.xcodeproj -target Ghostty -configuration Debug CODE_SIGNING_ALLOWED=NO build` 确认编译通过;`command -v swiftlint` 存在才跑 `swiftlint lint --strict --fix`(本机未装则记录跳过)。
- Swift 单测:`xcodebuild test -project macos/Ghostty.xcodeproj -scheme Ghostty -only-testing:GhosttyTests/<套件名> CODE_SIGNING_ALLOWED=NO`。若因签名/test host 无法运行,**先实际尝试一次**,失败则在台账记录输出并以「编译通过 + 评审」代替,不得静默跳过。
- `macos/Sources` 与 `macos/Tests` 是 Xcode 文件系统同步组(PBXFileSystemSynchronizedRootGroup),新增 Swift 文件放进目录即自动入编译,**不要**手改 project.pbxproj。
- 冒烟运行环境(详见 `.superpowers/sdd/task-11-smoke-report.md`):app 构建后需 `xattr -rc macos/build && codesign --force --deep --sign - macos/build/Debug/Ghostty.app`;启动带 `--window-vsync=false --window-save-state=never`;崩溃后删 `~/Library/Saved Application State/com.mitchellh.ghostty.debug.savedState`;日志用 `log stream --level info --predicate 'process == "ghostty" AND subsystem CONTAINS "mitchellh"'`;勿动 /Applications 的正式版 Ghostty;禁止并发 zig build;警惕 cwd=macos 产生 `macos/macos/GhosttyKit.xcframework`。
- 线程契约(沿用计划一,写代码时时刻对照):Viewer 只在宿主 IO 线程访问;锁顺序 宿主 renderer 锁 → router 锁 → pane renderer 锁;pane 线程取 router 锁时绝不持有 renderer 锁;Swift 所有 ghostty C API 调用在主线程(action 回调本身在主线程)。
- 每任务完成后在 `.superpowers/sdd/progress.md` 台账追加一行(沿用计划一格式)。

## 本计划的既定设计决策(评审时视为已裁决)

1. **route() 保持同步投递**(backlog #2 不在本计划做):锁拆分已消除主 ABBA;残余的邮箱饱和场景(超大粘贴)属罕见退化,MVP 接受,异步投递重构留到计划三/上游评审阶段。
2. **pane_gone 不做 C 层管道**:pane 注册竞态(注册时已被 tmux 删)由 windows diff 收敛——tmux 布局里不再有该 pane,GUI 下一次 diff 即销毁其 surface。
3. **焦点同步单向**(GUI → tmux `select-pane`):list-windows 格式不含 active pane,反向同步二期再说(spec 亦只列此方向)。
4. **send-keys 吞吐优化**(backlog #6)不在本计划;粘贴大文本慢是已知限制。
5. **detached 是终态**:pane surface 每 pane 只创建一次,GUI 绝不对同一 pane id 二次注册(tmux 保证 id 不复用)。

---

### Task 1: DCS 裸转义序列成帧修复(control.zig 容忍 + Stream 接管)

**不修这个,UI 毫无意义**:真实 shell(zsh + ghostty shell 集成)的 pane 启动时发 `ESC k title ST` 与 OSC 7,tmux 把这些序列**裸转发**进控制流。VT 解析器对 ESC 有 **anywhere 转移**(`src/terminal/parse_table.zig:71`:任何状态收到 0x1B → `.escape`),`dcs_passthrough` 离开时发出 `dcs_unhook`(`src/terminal/Parser.zig:274`)→ `dcs.unhook()` 返回 `.tmux = .exit` → viewer 假退出,而真实 tmux 客户端仍挂着。注意:**不只是 ST,裸序列的第一个 ESC 字节就足以杀死控制模式**。

修复分两层,缺一不可:
- **Stream 层接管**:控制模式活跃期间,字节不再进 VT 解析器,直接走 `dcs_put` 派发路径(下游 dcs.Handler → ControlParser → viewer 全部不变)。这样 ESC 到不了解析器的 anywhere 转移。
- **control.zig idle 容忍**:接管后裸序列会抵达 ControlParser,其 idle 态现在「非 % 即 broken」(`src/terminal/tmux/control.zig` put() 约 84 行),需要新增跳过状态消化 ESC 开头的序列。

控制模式的真正终结:`%exit` 行(ControlParser 发 `.exit` 通知 → tmuxExit 销毁 viewer)→ 接管解除 → 随后的真 ST 走原路径 unhook 清掉 dcs.Handler 状态。tmuxExit 需幂等化避免向 GUI 发两次 exit 事件。

**Files:**
- Modify: `src/terminal/tmux/control.zig`(idle 容忍 + 测试)
- Modify: `src/terminal/stream.zig`(接管机制 + 端到端测试)
- Modify: `src/termio/stream_handler.zig`(`tmuxControlActive` + `tmuxExit` 幂等)

**Interfaces:**
- Produces: `StreamHandler.tmuxControlActive(self) bool`(tmux 禁用时恒 false);Stream 对声明了 `tmuxControlActive` 的 Handler 自动启用接管(`@hasDecl` comptime 门控,其他 Stream 用户零开销——viewer 内部 pane 终端的 vtStream Handler 无此 decl,不受影响)。
- Consumes: 现有 `dcs.Handler`/`ControlParser`/viewer 全链路,不改其接口。

- [ ] **Step 1: control.zig 写失败测试**

在 `control.zig` 底部现有测试区(599 行起)追加。**先读现有测试**弄清 put 的调用方式、通知捕获方式与行结尾约定(`\n` 还是 `\r\n`),下面测试按现有惯例改写:

```zig
test "idle skips interleaved title escape sequence" {
    const alloc = testing.allocator;
    var p: ControlParser = .{ .max_bytes = 1024, .buffer = try .initCapacity(alloc, 128) };
    defer p.deinit(alloc);

    // %output 前后夹一段裸 ESC k title ST(zsh shell 集成的真实序列)
    var notifs: usize = 0;
    for ("%output %1 hi\n") |b| if (try p.put(alloc, b)) |n| {
        try testing.expect(n == .output);
        notifs += 1;
    };
    for ("\x1bkzsh\x1b\\") |b| try testing.expect((try p.put(alloc, b)) == null);
    for ("%output %1 bye\n") |b| if (try p.put(alloc, b)) |n| {
        try testing.expect(n == .output);
        notifs += 1;
    };
    try testing.expectEqual(@as(usize, 2), notifs);
}

test "idle skips OSC7 terminated by BEL" {
    // "\x1b]7;file://host/tmp\x07" 后接 "%output %1 ok\n" → 仅得 output 通知
}

test "idle skips OSC7 terminated by ST" {
    // "\x1b]7;file://host/tmp\x1b\\" 后接 "%output %1 ok\n" → 仅得 output 通知
}

test "idle skips two-byte escape" {
    // "\x1b=" 后接 "%output %1 ok\n" → 仅得 output 通知(简单终态序列立即结束跳过)
}

test "escape skip overflow becomes broken" {
    // max_bytes 设小(如 32),feed "\x1bk" + 64 个 'a' → 期间某次 put 返回 .exit(broken)
}
```

注意:`ControlParser.put` 的真实签名、返回类型(`?Notification` 还是别的)、构造方式**以现有代码与测试为准**,上面是形状示意;`.output` 变体名同理。非 ESC 的 idle 垃圾字节仍应 broken——现有该行为的测试保持不动。

- [ ] **Step 2: 跑测试确认失败**

Run: `zig build test -Dtest-filter="idle skips"`
Expected: 失败(ESC 进 idle 即 broken,收不到第二个 output)。

- [ ] **Step 3: control.zig 实现跳过状态**

`State` enum(32-49 行)追加三个状态(State 是纯 enum,计数器用平行字段,保持最小 diff):

```zig
    /// Skipping a raw escape sequence tmux interleaved into the control
    /// stream. tmux forwards some sequences (e.g. title changes, OSC 7)
    /// raw to capable client terminals instead of wrapping them in
    /// %output. We consume and discard them, then return to idle.
    /// esc_skip_start: right after ESC, deciding the sequence type.
    esc_skip_start,
    /// Inside a string sequence (ESC ] k P X ^ _): consume until BEL
    /// or ST (ESC \).
    esc_skip_string,
    /// Saw ESC inside a string sequence; if next byte is '\' it is ST.
    esc_skip_string_esc,
```

ControlParser 加字段 `skip_len: usize = 0`。`put()` 修改:

① idle 态的「非 % 即 broken」分支(约 84 行)前插入 ESC 分支:

```zig
            0x1B => {
                self.state = .esc_skip_start;
                self.skip_len = 0;
                return null;
            },
```

② 新增三个状态的处理(每个字节先 `self.skip_len += 1`,超过 `self.max_bytes` 走与现有 broken 完全相同的路径——照抄现有 broken 处置代码,含 buffer deinit 与返回值):

```zig
            .esc_skip_start => switch (byte) {
                // Intermediates: stay and keep looking for the final.
                0x20...0x2F => {},
                // String sequences: consume until BEL or ST.
                ']', 'k', 'P', 'X', '^', '_' => self.state = .esc_skip_string,
                // Anything else is the final byte of a simple sequence.
                else => self.state = .idle,
            },
            .esc_skip_string => switch (byte) {
                0x07 => self.state = .idle,
                0x1B => self.state = .esc_skip_string_esc,
                else => {},
            },
            .esc_skip_string_esc => switch (byte) {
                '\\' => self.state = .idle,
                // A literal ESC inside the string; keep consuming.
                else => self.state = .esc_skip_string,
            },
```

回到 idle 时 `log.debug("skipped raw escape sequence in control stream len={}", .{self.skip_len});`。整合进现有 put() 的 switch 结构时以现有代码风格为准(idle 分支对 `\r`/`\n` 的既有处理不动)。

- [ ] **Step 4: 跑 control.zig 测试确认通过**

Run: `zig build test -Dtest-filter="idle skips"` → PASS;`zig build test -Dtest-filter=escape` → PASS;`zig build test -Dtest-filter=tmux` → 全绿。

- [ ] **Step 5: stream_handler.zig 实现 tmuxControlActive 与幂等 tmuxExit**

① `dcsUnhook` 附近(372-388 行)加:

```zig
    /// True while tmux control mode is active. The terminal stream
    /// queries this to take over byte framing (raw interleaved escape
    /// sequences must not reach the VT parser's anywhere-ESC
    /// transition, which would unhook the DCS and kill control mode).
    pub fn tmuxControlActive(self: *StreamHandler) bool {
        if (comptime !tmux_enabled) return false;
        return self.tmux_viewer != null;
    }
```

② `tmuxExit`(609 行)开头加幂等保护:

```zig
    fn tmuxExit(self: *StreamHandler) void {
        if (comptime !tmux_enabled) return;

        // Idempotent: this can be reached twice for one session (the
        // %exit notification, then the DCS unhook from the trailing
        // ST). Only tear down and notify the apprt once.
        if (self.tmux_viewer == null and self.tmux_router == null) return;
        ... 其余原样 ...
```

- [ ] **Step 6: stream.zig 写失败的端到端测试**

stream.zig 底部测试区追加。**先读 stream.zig 现有测试**,弄清 mock handler 的写法(Stream 对 handler 的调用面)与 `Stream(H).init` 惯例,然后按下述逻辑构造(测试 handler 内嵌真实 `terminal.dcs.Handler`,不需要 Viewer):

```zig
test "tmux control mode survives interleaved raw escape sequences" {
    if (comptime !build_options.tmux_control_mode) return error.SkipZigTest;
    const alloc = testing.allocator;

    const H = struct {
        alloc: std.mem.Allocator,
        dcs: terminal.dcs.Handler = .{},
        active: bool = false,
        outputs: usize = 0,
        exits: usize = 0,
        printed: std.ArrayListUnmanaged(u21) = .empty,

        pub fn tmuxControlActive(self: *@This()) bool {
            return self.active;
        }

        // dcs_hook/dcs_put/dcs_unhook 三个入口把命令喂给 self.dcs,
        // 对返回的 .tmux 命令:.enter → active=true;.exit → active=false,
        // exits+=1;.output → outputs+=1;其余忽略。
        // print 回调把字符记进 printed。
        // 其余 Stream 需要的回调给空实现(照抄现有测试 handler)。
    };

    var h: H = .{ .alloc = alloc };
    // defer:清理 h.dcs 与 printed
    var s: Stream(*H) = .init(&h); // 以现有测试的构造写法为准

    try s.nextSlice("\x1bP1000p"); // DCS 进入控制模式
    try testing.expect(h.active);

    try s.nextSlice("%begin 1 0 0\n%end 1 0 0\n"); // 启动块
    try s.nextSlice("\x1bkzsh\x1b\\"); // 裸标题序列:不得杀死控制模式
    try testing.expect(h.active);
    try s.nextSlice("%output %0 hi\n");
    try s.nextSlice("\x1b]7;file://host/tmp\x07"); // 裸 OSC7(BEL 终结)
    try s.nextSlice("%output %0 bye\n");
    try testing.expectEqual(@as(usize, 2), h.outputs);
    try testing.expect(h.active);

    try s.nextSlice("%exit\n"); // 真正退出
    try testing.expect(!h.active);
    try testing.expectEqual(@as(usize, 1), h.exits);

    try s.nextSlice("\x1b\\"); // 尾随 ST 正常 unhook(dcs 状态清理,不再多发 exit)
    try s.nextSlice("A"); // 回到普通终端解析
    try testing.expectEqual(@as(usize, 1), h.exits);
    try testing.expect(h.printed.items.len == 1 and h.printed.items[0] == 'A');
}
```

行结尾(`\n` vs `\r\n`)与 `%begin`/`%end` 参数格式照抄 control.zig 现有测试的合法样例。`build_options` 的 import 方式照抄 dcs.zig 头部。

- [ ] **Step 7: 跑测试确认失败**

Run: `zig build test -Dtest-filter="survives interleaved"`
Expected: 失败——裸序列的 ESC 触发 unhook,`h.active` 变 false / exits 多于 1。

- [ ] **Step 8: stream.zig 实现接管**

① Stream 类型内(`pub fn Stream(comptime Handler: type) type` 返回的 struct 里)加:

```zig
        /// Comptime capability: handlers that expose tmux control mode
        /// state get byte-level takeover while it is active (see
        /// tmux_takeover below). All other handlers compile this out.
        const tmux_takeover_capable = @hasDecl(
            @typeInfo(@TypeOf(handler_field)) ... // 实际写法:对 Handler 解引用后的类型做 @hasDecl;
        );
```

实际判定以 Handler 的指针/值形态为准(现有 Stream 测试怎么传 handler 就怎么解):目标语义是 `@hasDecl(HandlerType, "tmuxControlActive")`。加字段:

```zig
        /// True while tmux control mode owns the byte stream. While
        /// set, bytes bypass the VT parser and go straight to the DCS
        /// put path: tmux interleaves raw escape sequences into the
        /// control stream, and the parser's anywhere-ESC transition
        /// would otherwise unhook the DCS and kill the session. The
        /// flag drops when the handler reports control mode ended
        /// (%exit); the trailing ST then unhooks the parser normally.
        tmux_takeover: if (tmux_takeover_capable) bool else void =
            if (tmux_takeover_capable) false else {},
```

② `next(c)` 顶部(以及 nextSlice 若有不经过 next 的非 ground 逐字节路径,同样处理;接管时 parser 停在 `.dcs_passthrough`,ground 快速路径不可达——加注释说明):

```zig
        if (comptime tmux_takeover_capable) {
            if (self.tmux_takeover) {
                // 派发方式与动作 switch 里 .dcs_put 分支完全一致(照抄)
                self.handler.vt(.dcs_put, c); // 或现行等价调用
                if (!self.handler.tmuxControlActive()) self.tmux_takeover = false;
                return;
            }
        }
```

③ 动作 switch 的 `.dcs_hook` 分支(约 1022 行),派发后追加:

```zig
                .dcs_hook => |dcs| {
                    self.handler.vt(.dcs_hook, dcs); // 现行调用原样
                    if (comptime tmux_takeover_capable) {
                        self.tmux_takeover = self.handler.tmuxControlActive();
                    }
                },
```

若该 switch 分支带 try/错误处理,保持原样语义。

- [ ] **Step 9: 跑测试确认通过**

Run: `zig build test -Dtest-filter="survives interleaved"` → PASS;`zig build test -Dtest-filter=tmux` → 全绿(基线 195 + 本任务新增);`zig build test -Dtest-filter=stream` → 全绿。

- [ ] **Step 10: 全量构建 + 真机冒烟**

```bash
zig build -Demit-macos-app=false   # exit 0
zig build                           # 刷新 xcframework + app(或按环境走 xcodebuild 流程)
xattr -rc macos/build && codesign --force --deep --sign - macos/build/Debug/Ghostty.app
```

冒烟(此前 zsh pane 约 1 秒即死,是本任务的判定标准):

```bash
open macos/build/Debug/Ghostty.app --args --window-vsync=false --window-save-state=never \
  --command='tmux -CC new-session -s smoke'   # 注意:默认 shell zsh,不再是 /bin/sh
```

另开终端观察 `log stream --level info --predicate 'process == "ghostty" AND subsystem CONTAINS "mitchellh"'`:期望看到 `tmux: attach`、`tmux: windows ...`,**30 秒内无 `tmux: exit`**;`tmux ls` 显示会话 attached。随后 `tmux kill-session -t smoke` 确认干净退出且只有一条 exit 日志。完毕后退出 app、清理 tmux 会话。

- [ ] **Step 11: 格式化并提交**

```bash
zig fmt src/terminal/tmux/control.zig src/terminal/stream.zig src/termio/stream_handler.zig
git add -A && git commit -m "fix(tmux): survive raw escape sequences interleaved in control stream"
```

---

### Task 2: backlog OOM 小修(viewer take 泄漏 + router unregister 事件)

**Files:**
- Modify: `src/terminal/tmux/viewer.zig`(receivedCommandOutput 末尾的 take_pending 扫描)
- Modify: `src/termio/TmuxRouter.zig`(unregister)

**Interfaces:** 无新接口,纯健壮性修复。

- [ ] **Step 1: router 写失败测试(顺带回归保护)**

`TmuxRouter.zig` 底部测试区追加:

```zig
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
```

Run: `zig build test -Dtest-filter="unregister always"` → 应当**已经通过**(常态路径本来就发事件)。这是回归保护;本步价值在于固化顺序语义。

- [ ] **Step 2: router unregister 收窄 OOM 窗口**

现状:先删 panes 表,再 `events.append(...) catch log`——OOM 时事件丢失而 pane 已删,viewer 永远不知道该 pane 反注册。pane 删除**必须**发生(其 Termio 正在销毁,不删会 UAF)。修法:先在 events_mutex 下 `ensureUnusedCapacity` 预留,再删 pane,最后 `appendAssumeCapacity`(不可失败):

```zig
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
```

两把锁依旧从不嵌套;顶部两互斥纪律注释若需要就补一句「unregister 按 events → panes → events 顺序分段加锁」。

- [ ] **Step 3: viewer take_pending 扫描消除中途 OOM 孤儿**

`receivedCommandOutput` 末尾的扫描(计划一 Task 3 步骤⑨;搜 `take_pending and !self.paneBusy`):现状 `takePane` 把 Terminal 搬上堆并置 `attached` 后,`appendSlice` 若 OOM,已堆分配的 Terminal 与 action 一起丢失(泄漏)。修法:append 前先预留容量,使 take 之后不再有可失败操作:

```zig
        // A command completing may unblock pending takes.
        var it = self.panes.iterator();
        while (it.next()) |kv| {
            const pane: *Pane = kv.value_ptr;
            switch (pane.state) {
                .loading => |l| if (l.take_pending and !self.paneBusy(kv.key_ptr.*)) {
                    // Reserve first: after takePane the terminal is on
                    // the heap and the pane is .attached; a failed
                    // append would orphan it.
                    try actions.ensureUnusedCapacity(arena_alloc, 1);
                    const taken = self.takePane(kv.key_ptr.*) orelse
                        return error.OutOfMemory;
                    actions.appendSliceAssumeCapacity(taken);
                },
                else => {},
            }
        }
```

(`takePane` 返回单元素 slice;`ensureUnusedCapacity(1)` 足够。方法名以 std 实际 API 为准:`appendSliceAssumeCapacity` 不存在就逐元素 `appendAssumeCapacity`。)

- [ ] **Step 4: 验证**

Run: `zig build test -Dtest-filter=router` → 全绿(新增 1);`zig build test -Dtest-filter="pane registered"` → 全绿;`zig build test -Dtest-filter=tmux` → 全绿;`zig build -Demit-macos-app=false` → exit 0。

- [ ] **Step 5: 格式化并提交**

```bash
zig fmt src/terminal/tmux/viewer.zig src/termio/TmuxRouter.zig
git add -A && git commit -m "fix(tmux): close OOM windows in router unregister and pending take"
```

---

### Task 3: Router 生命周期协议 + tmux 命令 C API

GUI 将长期持有 attach 事件里的 router 裸指针并随时发命令,必须解决两件事(backlog #3):
- **closed 标志**:宿主退出(tmuxExit)后,router 上的 sendCommand/register/unregister 静默丢弃,GUI 迟到的调用安全无害。
- **GUI 持有引用**:attach 事件发出前 `router.ref()` 一次,归 GUI 所有;GUI 用完(exit 收尾或掉线)调 `ghostty_tmux_router_release` 归还。杜绝 UAF。

命令字符串拼接留在 Zig 侧(spec 要求):C 只传类型化结构。

**Files:**
- Modify: `src/termio/TmuxRouter.zig`(closed + formatCommand + 测试)
- Modify: `src/apprt/action.zig`(`TmuxCommand` extern 类型 + 头文件一致性测试)
- Modify: `include/ghostty.h`(enum/struct/两个函数声明)
- Modify: `src/apprt/embedded.zig`(两个 export fn)
- Modify: `src/termio/stream_handler.zig`(.enter 加 GUI ref;tmuxExit 调 close)
- Modify: `src/App.zig`(surface 亡后丢弃 attach 事件时归还 GUI ref)

**Interfaces:**
- Produces(后续 Swift 任务依赖,签名精确):
  - C:`void ghostty_tmux_router_command(void* router, ghostty_tmux_command_s cmd);`、`void ghostty_tmux_router_release(void* router);`
  - C:`ghostty_tmux_command_s { ghostty_tmux_command_tag_e tag; uintptr_t id; uintptr_t width; uintptr_t height; }`,tag ∈ `GHOSTTY_TMUX_COMMAND_{KILL_PANE, KILL_WINDOW, DETACH, SELECT_PANE, RESIZE}`
  - Zig:`apprt.action.TmuxCommand`(extern struct 同构)、`TmuxRouter.formatCommand(buf: []u8, cmd: apprt.action.TmuxCommand) ![]u8`、`TmuxRouter.close(self)`

- [ ] **Step 1: 写失败测试**

`TmuxRouter.zig` 底部:

```zig
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
```

Run: `zig build test -Dtest-filter="closed router"` → 编译错误(close/formatCommand 不存在)。

- [ ] **Step 2: 实现 TmuxCommand 类型(action.zig)**

`src/apprt/action.zig` 里 `Tmux` union 旁(不进 Action/CValue union,独立类型)加:

```zig
/// A typed tmux command the GUI sends to a session's TmuxRouter via
/// ghostty_tmux_router_command. Command strings are rendered Zig-side
/// (TmuxRouter.formatCommand) so the C ABI stays typed.
pub const TmuxCommand = extern struct {
    tag: Tag,
    /// Pane id for kill_pane/select_pane; window id for kill_window.
    id: usize = 0,
    /// Client grid size for resize.
    width: usize = 0,
    height: usize = 0,

    pub const Tag = enum(c_int) {
        kill_pane,
        kill_window,
        detach,
        select_pane,
        resize,
    };
};
```

头文件一致性测试:照抄本文件现有 `Tmux.Node.Kind` 的 `checkGhosttyHEnum` 测试写法,为 `TmuxCommand.Tag` 对 `ghostty_tmux_command_tag_e` 加同款测试。

- [ ] **Step 3: 实现 closed 与 formatCommand(TmuxRouter.zig)**

① 字段:`closed: std.atomic.Value(bool) = .init(false),`(create 里相应初始化)。

② 方法:

```zig
/// Mark the router closed: the host surface's tmux session ended.
/// Subsequent sendCommand/register/unregister become silent no-ops so
/// late calls from the GUI or dying pane surfaces are harmless. The
/// panes map is NOT cleared here; pane surfaces still unregister
/// (no-op) and drop their refs normally.
pub fn close(self: *TmuxRouter) void {
    self.closed.store(true, .release);
}
```

`sendCommand`/`register`/`unregister` 开头加 `if (self.closed.load(.acquire)) return;`(sendCommand 返回类型不变,closed 时直接 `return`)。

③ formatCommand(公开、纯函数):

```zig
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
    };
}
```

apprt 的 import 照本文件或邻近 termio 文件现有写法(stream_handler.zig 已 import apprt)。

- [ ] **Step 4: ghostty.h 声明**

结构体/枚举放在现有 tmux 声明(787-845 行)之后:

```c
// apprt.action.TmuxCommand.Tag
typedef enum {
  GHOSTTY_TMUX_COMMAND_KILL_PANE,
  GHOSTTY_TMUX_COMMAND_KILL_WINDOW,
  GHOSTTY_TMUX_COMMAND_DETACH,
  GHOSTTY_TMUX_COMMAND_SELECT_PANE,
  GHOSTTY_TMUX_COMMAND_RESIZE,
} ghostty_tmux_command_tag_e;

// apprt.action.TmuxCommand
typedef struct {
  ghostty_tmux_command_tag_e tag;
  uintptr_t id;
  uintptr_t width;
  uintptr_t height;
} ghostty_tmux_command_s;
```

函数声明放在 `GHOSTTY_API ghostty_surface_size(...)`(1182 行)附近的函数区:

```c
GHOSTTY_API void ghostty_tmux_router_command(void*, ghostty_tmux_command_s);
GHOSTTY_API void ghostty_tmux_router_release(void*);
```

(本文件 enum 不加 `_MAX_VALUE` 哨兵——那条规则只适用于 `include/ghostty/vt/`。)

- [ ] **Step 5: embedded.zig export**

照本文件 export fn 惯例(如 `ghostty_surface_key`)追加:

```zig
/// Send a typed tmux command to a session's router. The router pointer
/// is the one delivered by the tmux attach action; the GUI must still
/// hold its reference (see ghostty_tmux_router_release). Safe to call
/// after the session ended: a closed router drops commands silently.
export fn ghostty_tmux_router_command(
    router_ptr: *anyopaque,
    cmd: apprt.action.TmuxCommand,
) void {
    const router: *termio.TmuxRouter = @ptrCast(@alignCast(router_ptr));
    var buf: [128]u8 = undefined;
    const str = termio.TmuxRouter.formatCommand(&buf, cmd) catch |err| {
        log.warn("tmux command format failed err={}", .{err});
        return;
    };
    router.sendCommand(str) catch |err| {
        log.warn("tmux command dropped err={}", .{err});
    };
}

/// Release the GUI's reference on a tmux router (taken on its behalf
/// when the attach action was emitted). Call exactly once per attach.
export fn ghostty_tmux_router_release(router_ptr: *anyopaque) void {
    const router: *termio.TmuxRouter = @ptrCast(@alignCast(router_ptr));
    router.unref();
}
```

termio 的 import 若 embedded.zig 没有则补;构建开关:若 `termio.TmuxRouter` 在 tmux 禁用构建下不可用,依 stream_handler 的 comptime 门控惯例包一层(以现有 tmux 相关代码在 embedded.zig/main C 层的门控方式为准;`ghostty_surface_config_s` 的 tmux 字段是无门控的,大概率这里也无需门控)。

- [ ] **Step 6: 布线 GUI ref 与 close**

① `stream_handler.zig` dcsCommand 的 `.enter` 分支:`surfaceMessageWriter(.{ .tmux = ev })` 之前(ev 创建成功、无后续可失败点处)加:

```zig
                    // One extra reference owned by the GUI, released
                    // via ghostty_tmux_router_release when it is done
                    // with the session (or by App.zig if the attach
                    // event is dropped before delivery).
                    router.ref();
```

② `tmuxExit`:`router.unref()` 前加 `router.close();`。

③ `src/App.zig` `surfaceMessage` 的 surface 已亡丢弃分支(现有 `switch (msg) { .tmux => |ev| ev.deinit(), ... }`):attach 事件的丢弃必须归还 GUI ref:

```zig
            .tmux => |ev| {
                // The attach event carries a router reference owned by
                // the GUI; if the event never reaches it, release here.
                switch (ev.event) {
                    .attach => |v| {
                        const router: *termio.TmuxRouter = @ptrCast(@alignCast(v.router));
                        router.unref();
                    },
                    else => {},
                }
                ev.deinit();
            },
```

(App.zig 的 termio import 若缺则补。`Surface.handleMessage` 里 performAction 抛错的同类窗口极窄,记录在台账 Minor,不处理。)

- [ ] **Step 7: 验证**

Run: `zig build test -Dtest-filter="closed router"` → PASS;`zig build test -Dtest-filter=formatCommand` → PASS;`zig build test -Dtest-filter=router` → 全绿;`zig build test -Dtest-filter=tmux` → 全绿;`zig build test -Dtest-filter=ghostty.h` → 全绿(枚举一致性测试的过滤名以现有同类测试为准);`zig build -Demit-macos-app=false` → exit 0。

- [ ] **Step 8: 格式化并提交**

```bash
zig fmt src/termio/TmuxRouter.zig src/apprt/action.zig src/apprt/embedded.zig src/termio/stream_handler.zig src/App.zig
git add -A && git commit -m "feat(tmux): router close protocol, GUI-held ref, typed command C API"
```

---

### Task 4: Viewer 版本门槛(tmux ≥ 3.2)

低版本 tmux 缺 extended-keys 等控制模式必需能力,进入半残状态不如主动 detach(spec §5)。

**Files:**
- Modify: `src/terminal/tmux/viewer.zig`(receivedTmuxVersion,约 994-1031 行)

**Interfaces:** 无新对外接口。行为:版本可解析且 < 3.2 → 发 `detach-client` 命令 + defunct(exit action);≥ 3.2 或不可解析(如异构发行版字符串)→ 照常继续并 log。

- [ ] **Step 1: 写失败测试**

viewer.zig 底部测试区,照抄现有走到 version 响应的测试(如 `test "window name parsed and renamed"` 的前三步),分三个测试:

```zig
test "tmux version below minimum detaches" {
    const alloc = testing.allocator;
    var v: Viewer = try .init(testing.io, alloc);
    defer v.deinit();

    try testViewer(&v, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{ .id = 0, .name = "test" } } },
            .contains_command = "display-message",
        },
        // 版本响应 3.1:期望 detach-client 命令 + exit,而不是 list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "3.1" } },
            .contains_command = "detach-client",
            .contains_tags = &.{.exit},
        },
    });
}

test "tmux version at minimum proceeds" {
    // 同上,版本响应 "3.2" → .contains_command = "list-windows"
}

test "tmux version unparseable proceeds" {
    // 同上,版本响应 "weird-fork" → .contains_command = "list-windows"
}
```

`testViewer`/`TestStep` 的断言字段(`contains_command`/`contains_tags`)以现有测试基建为准;若一个步骤无法同时断言 command 与 exit,拆成检查 actions 的 `check` 回调。

Run: `zig build test -Dtest-filter="tmux version"` → 失败(3.1 仍走 list-windows)。

- [ ] **Step 2: 实现**

`receivedTmuxVersion` 存储版本后插入检查:

```zig
        // Enforce the minimum supported tmux version (3.2): older
        // servers lack control mode capabilities we depend on, and a
        // half-working session is worse than a clean refusal. An
        // unparseable version (distro forks, "next-X.Y" builds) is
        // allowed through optimistically.
        if (parseVersion(self.tmux_version)) |ver| {
            if (ver.major < 3 or (ver.major == 3 and ver.minor < 2)) {
                log.warn(
                    "tmux version {s} below minimum 3.2, detaching",
                    .{self.tmux_version},
                );
                // 先排 detach 命令(照 sendCommand/queueCommands 的
                // 现有入队+立即发出逻辑),再走 defunct 发 exit。
                ...
            }
        } else log.info(
            "unparseable tmux version {s}, assuming capable",
            .{self.tmux_version},
        );
```

```zig
/// Parse "3.5a"/"3.2"/"next-3.6" style versions: the first digit run
/// is the major, an immediately following ".digits" the minor.
fn parseVersion(s: []const u8) ?struct { major: usize, minor: usize } {
    var i: usize = 0;
    while (i < s.len and !std.ascii.isDigit(s[i])) i += 1;
    if (i == s.len) return null;
    var major: usize = 0;
    while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1)
        major = major * 10 + (s[i] - '0');
    var minor: usize = 0;
    if (i < s.len and s[i] == '.') {
        i += 1;
        if (i == s.len or !std.ascii.isDigit(s[i])) return null;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1)
            minor = minor * 10 + (s[i] - '0');
    }
    return .{ .major = major, .minor = minor };
}
```

「发 detach 命令再 defunct」的实现:defunct 前把 `detach-client\n` 通过现有命令队列/单 action 机制放进返回 actions(参考 sendCommand 的立即发出分支与 defunct 的 exit 生成方式,保证两个 action 都进同一批;必要时给 defunct 加一个「附带前置 actions」的内部变体)。给 `parseVersion` 加 2-3 个直接单测(`3.5a`→3.5、`next-3.6`→3.6、`""`→null)。

- [ ] **Step 3: 验证**

Run: `zig build test -Dtest-filter="tmux version"` → PASS;`zig build test -Dtest-filter=parseVersion` → PASS;`zig build test -Dtest-filter=tmux` → 全绿;`zig build -Demit-macos-app=false` → exit 0。

- [ ] **Step 4: 格式化并提交**

```bash
zig fmt src/terminal/tmux/viewer.zig
git add -A && git commit -m "feat(tmux): enforce minimum tmux version 3.2"
```

---

### Task 5: Swift 桥接层(TmuxEvent 模型 + SurfaceConfiguration tmux 字段 + 通知)

**Files:**
- Create: `macos/Sources/Ghostty/Ghostty.Tmux.swift`
- Modify: `macos/Sources/Ghostty/Ghostty.App.swift`(tmux handler,2244-2269 行)
- Modify: `macos/Sources/Ghostty/Surface View/SurfaceView.swift`(SurfaceConfiguration,629-752 行)
- Create: `macos/Tests/Tmux/GhosttyTmuxTests.swift`

**Interfaces:**
- Produces(后续任务依赖):
  - `Ghostty.TmuxEvent`:`case attach(router: UnsafeMutableRawPointer)` / `case windows(Ghostty.TmuxWindows)` / `case exit`
  - `Ghostty.TmuxWindows { windows: [Ghostty.TmuxWindow], nodes: [Ghostty.TmuxNode] }`(深拷贝,脱离回调生命周期)
  - `Ghostty.TmuxWindow { id: UInt, name: String, width: UInt, height: UInt, root: Int }`
  - `Ghostty.TmuxNode { kind: Kind(.pane/.horizontal/.vertical), paneId: UInt, x/y/width/height: UInt, childrenStart: Int, childrenLen: Int }`
  - 通知 `.ghosttyTmux`(object = 宿主 SurfaceView,userInfo[`Ghostty.Notification.TmuxEventKey`] = TmuxEvent)——命名与 Key 风格照抄现有 `.ghosttyNewTab` 的定义处
  - `Ghostty.SurfaceConfiguration` 新字段:`tmuxRouter: UnsafeMutableRawPointer? = nil`、`tmuxPaneId: UInt = 0`,`withCValue` 映射到 `config.tmux_router`/`config.tmux_pane_id`
- Consumes: Task 3 的 `ghostty_tmux_router_release`(surface 缺失时防泄漏)。

- [ ] **Step 1: 写失败测试**

`macos/Tests/Tmux/GhosttyTmuxTests.swift`(Swift Testing;C 结构体直接在测试里构造,数组用 withUnsafe 系列取指针):

```swift
import Testing
@testable import Ghostty  // module 名以现有 Tests 文件的 import 为准
import GhosttyKit

@Suite struct GhosttyTmuxTests {
    @Test func windowsDeepCopy() throws {
        var nodes = [ghostty_action_tmux_node_s(
            kind: GHOSTTY_ACTION_TMUX_NODE_KIND_PANE,
            pane_id: 5, x: 0, y: 0, width: 80, height: 24,
            children_start: 0, children_len: 0)]
        let name = strdup("my editor")!
        defer { free(name) }
        var windows = [ghostty_action_tmux_window_s(
            id: 3, name: name, width: 80, height: 24, root: 0)]

        let copied: Ghostty.TmuxWindows? = windows.withUnsafeBufferPointer { wp in
            nodes.withUnsafeBufferPointer { np in
                Ghostty.TmuxWindows(from: ghostty_action_tmux_windows_s(
                    windows: wp.baseAddress, windows_len: 1,
                    nodes: np.baseAddress, nodes_len: 1))
            }
        }
        let w = try #require(copied)
        #expect(w.windows.count == 1)
        #expect(w.windows[0].id == 3)
        #expect(w.windows[0].name == "my editor")
        #expect(w.windows[0].root == 0)
        #expect(w.nodes.count == 1)
        #expect(w.nodes[0].kind == .pane)
        #expect(w.nodes[0].paneId == 5)
    }

    @Test func nodeRejectsUnknownKind() {
        let bad = ghostty_action_tmux_node_s(
            kind: ghostty_action_tmux_node_kind_e(rawValue: 99),
            pane_id: 0, x: 0, y: 0, width: 0, height: 0,
            children_start: 0, children_len: 0)
        #expect(Ghostty.TmuxNode(from: bad) == nil)
    }
}
```

(C struct 的逐字段构造器是否可用取决于导入形态;不可用时用 `var s = ghostty_action_tmux_node_s(); s.kind = ...` 风格。测试 target 对 app 代码的访问方式——`@testable import` 的模块名——照抄 `macos/Tests/Splits/SplitTreeTests.swift` 头部。)

- [ ] **Step 2: 跑测试确认失败**

先 `zig build -Demit-macos-app=false`,然后:
Run: `xcodebuild test -project macos/Ghostty.xcodeproj -scheme Ghostty -only-testing:GhosttyTests/GhosttyTmuxTests CODE_SIGNING_ALLOWED=NO`
Expected: 编译失败(类型不存在)。若 test host 因签名失败无法起动,记录到台账并以「编译失败即 RED」判定。

- [ ] **Step 3: 实现 Ghostty.Tmux.swift**

```swift
import GhosttyKit

extension Ghostty {
    /// A tmux control mode event delivered via GHOSTTY_ACTION_TMUX.
    /// All payloads are deep copies: the C arrays are only valid during
    /// the action callback.
    enum TmuxEvent {
        case attach(router: UnsafeMutableRawPointer)
        case windows(TmuxWindows)
        case exit
    }

    struct TmuxWindows: Equatable {
        var windows: [TmuxWindow] = []
        var nodes: [TmuxNode] = []

        init?(from c: ghostty_action_tmux_windows_s) {
            if let cw = c.windows {
                for i in 0..<Int(c.windows_len) {
                    windows.append(TmuxWindow(from: cw[i]))
                }
            }
            if let cn = c.nodes {
                for i in 0..<Int(c.nodes_len) {
                    guard let node = TmuxNode(from: cn[i]) else { return nil }
                    nodes.append(node)
                }
            }
            // Window roots must be valid node indices.
            for w in windows where w.root >= nodes.count { return nil }
        }
    }

    struct TmuxWindow: Equatable {
        var id: UInt
        var name: String
        var width: UInt
        var height: UInt
        var root: Int

        init(from c: ghostty_action_tmux_window_s) {
            id = UInt(c.id)
            name = String(cString: c.name)
            width = UInt(c.width)
            height = UInt(c.height)
            root = Int(c.root)
        }
    }

    struct TmuxNode: Equatable {
        enum Kind: Equatable { case pane, horizontal, vertical }

        var kind: Kind
        var paneId: UInt
        var x: UInt
        var y: UInt
        var width: UInt
        var height: UInt
        var childrenStart: Int
        var childrenLen: Int

        init?(from c: ghostty_action_tmux_node_s) {
            switch c.kind {
            case GHOSTTY_ACTION_TMUX_NODE_KIND_PANE: kind = .pane
            case GHOSTTY_ACTION_TMUX_NODE_KIND_HORIZONTAL: kind = .horizontal
            case GHOSTTY_ACTION_TMUX_NODE_KIND_VERTICAL: kind = .vertical
            default: return nil
            }
            paneId = UInt(c.pane_id)
            x = UInt(c.x)
            y = UInt(c.y)
            width = UInt(c.width)
            height = UInt(c.height)
            childrenStart = Int(c.children_start)
            childrenLen = Int(c.children_len)
        }
    }
}
```

通知名与 userInfo Key:在现有 `.ghosttyNewTab` 等定义的同一文件、同一风格下加 `.ghosttyTmux` 与 `TmuxEventKey`。

- [ ] **Step 4: 替换 Ghostty.App.swift 的 tmux handler**

```swift
private static func tmux(
    _ app: ghostty_app_t,
    target: ghostty_target_s,
    v: ghostty_action_tmux_s)
{
    // 宿主 surface 定位方式照本文件其它 surface 目标 action(如 newTab)
    guard target.tag == GHOSTTY_TARGET_SURFACE,
          let surface = target.target.surface,
          let surfaceView = self.surfaceView(from: surface)
    else {
        // The attach payload carries a router reference owned by the
        // GUI; if we can't deliver it, release it or it leaks.
        if v.tag == GHOSTTY_TMUX_ATTACH, let router = v.value.attach.router {
            ghostty_tmux_router_release(router)
        }
        Ghostty.logger.warning("tmux action dropped: no surface target")
        return
    }

    let event: Ghostty.TmuxEvent
    switch v.tag {
    case GHOSTTY_TMUX_ATTACH:
        guard let router = v.value.attach.router else { return }
        event = .attach(router: router)
    case GHOSTTY_TMUX_WINDOWS:
        guard let w = Ghostty.TmuxWindows(from: v.value.windows) else {
            Ghostty.logger.warning("tmux windows payload malformed, dropped")
            return
        }
        event = .windows(w)
    case GHOSTTY_TMUX_EXIT:
        event = .exit
    default:
        Ghostty.logger.warning("tmux: unknown tag=\(v.tag.rawValue)")
        return
    }

    NotificationCenter.default.post(
        name: .ghosttyTmux,
        object: surfaceView,
        userInfo: [Ghostty.Notification.TmuxEventKey: event])
}
```

- [ ] **Step 5: SurfaceConfiguration 加 tmux 字段**

`SurfaceConfiguration`(SurfaceView.swift 629 行起)属性区追加:

```swift
    /// Non-nil marks this surface as a tmux pane surface for the given
    /// router (opaque pointer from the tmux attach action) and pane id.
    /// The core then uses the TmuxPane termio backend: no subprocess.
    var tmuxRouter: UnsafeMutableRawPointer? = nil
    var tmuxPaneId: UInt = 0
```

`init(from config: ghostty_surface_config_s)` 加 `self.tmuxRouter = config.tmux_router; self.tmuxPaneId = UInt(config.tmux_pane_id)`;`withCValue` 里 `config.font_size = ...` 附近加:

```swift
    config.tmux_router = tmuxRouter
    config.tmux_pane_id = UInt(tmuxPaneId)
```

(`uintptr_t` 在 Swift 侧即 `UInt`,如类型不匹配按编译器提示补显式转换。)

- [ ] **Step 6: 验证**

```bash
zig build -Demit-macos-app=false
xcodebuild -project macos/Ghostty.xcodeproj -target Ghostty -configuration Debug CODE_SIGNING_ALLOWED=NO build
xcodebuild test -project macos/Ghostty.xcodeproj -scheme Ghostty -only-testing:GhosttyTests/GhosttyTmuxTests CODE_SIGNING_ALLOWED=NO
```

Expected: 构建成功,2 个测试 PASS(或按 Step 2 记录的降级判定)。

- [ ] **Step 7: 提交**

```bash
command -v swiftlint >/dev/null && swiftlint lint --strict --fix macos/Sources/Ghostty/Ghostty.Tmux.swift || true
git add -A && git commit -m "feat(macos): tmux event bridging and pane surface configuration"
```

---

### Task 6: TmuxSplitLayout 纯函数转换器

扁平 node 数组 → 二叉分屏描述(pane id + ratio),不触 UI 类型,可完整单测。n 叉分裂折成右结合二叉链,ratio 按分裂轴上的子节点尺寸占比。

**Files:**
- Create: `macos/Sources/Features/Tmux/TmuxSplitLayout.swift`
- Create: `macos/Tests/Tmux/TmuxSplitLayoutTests.swift`

**Interfaces:**
- Consumes: Task 5 的 `Ghostty.TmuxNode`。
- Produces:`TmuxSplitLayout`:`case pane(id: UInt)` / `indirect case split(direction: Direction, ratio: Double, left: TmuxSplitLayout, right: TmuxSplitLayout)`,`Direction ∈ {horizontal, vertical}`;`static func build(nodes: [Ghostty.TmuxNode], root: Int) -> TmuxSplitLayout?`(非法输入返回 nil)。

- [ ] **Step 1: 写失败测试**

```swift
import Testing
@testable import Ghostty
import GhosttyKit

@Suite struct TmuxSplitLayoutTests {
    private func pane(_ id: UInt, w: UInt = 80, h: UInt = 24) -> Ghostty.TmuxNode {
        node(kind: .pane, paneId: id, w: w, h: h)
    }

    private func node(
        kind: Ghostty.TmuxNode.Kind, paneId: UInt = 0,
        w: UInt, h: UInt, start: Int = 0, len: Int = 0
    ) -> Ghostty.TmuxNode {
        // Ghostty.TmuxNode 需要一个测试可用的 memberwise 构造:若 init(from:)
        // 是唯一构造器,给 TmuxNode 补一个 internal memberwise init。
        ...
    }

    @Test func singlePane() {
        let layout = TmuxSplitLayout.build(nodes: [pane(1)], root: 0)
        #expect(layout == .pane(id: 1))
    }

    @Test func horizontalPairRatio() throws {
        // [pane0(w30), pane1(w90), H(children 0..2, w121)]
        let nodes = [
            pane(0, w: 30), pane(1, w: 90),
            node(kind: .horizontal, w: 121, h: 24, start: 0, len: 2),
        ]
        let layout = try #require(TmuxSplitLayout.build(nodes: nodes, root: 2))
        guard case .split(let dir, let ratio, let left, let right) = layout else {
            Issue.record("expected split"); return
        }
        #expect(dir == .horizontal)
        #expect(abs(ratio - 30.0 / 120.0) < 0.001)
        #expect(left == .pane(id: 0))
        #expect(right == .pane(id: 1))
    }

    @Test func threeWayFoldsRightAssociative() throws {
        // H[p0(40), p1(40), p2(40)] → split(p0, split(p1, p2, 0.5), 1/3)
        let nodes = [
            pane(0, w: 40), pane(1, w: 40), pane(2, w: 40),
            node(kind: .horizontal, w: 122, h: 24, start: 0, len: 3),
        ]
        let layout = try #require(TmuxSplitLayout.build(nodes: nodes, root: 3))
        guard case .split(_, let ratio, let left, let right) = layout,
              case .split(_, let innerRatio, let innerL, let innerR) = right else {
            Issue.record("expected nested split"); return
        }
        #expect(left == .pane(id: 0))
        #expect(abs(ratio - 1.0 / 3.0) < 0.001)
        #expect(abs(innerRatio - 0.5) < 0.001)
        #expect(innerL == .pane(id: 1))
        #expect(innerR == .pane(id: 2))
    }

    @Test func nonContiguousCopiedSegment() throws {
        // 复刻 Zig 侧 H[p1, V[p2, p3]] 的扁平结果:拷贝段的孩子下标
        // 指向原位置(stream_handler.zig 的
        // "serialize tmux windows flattens non-contiguous layout" 语义):
        // [0]=p1 [1]=p2 [2]=p3 [3]=V(children 1..3) [4]=p1' (copy of 0)
        // [5]=V' (copy of 3, children still 1..3) [6]=H(children 4..6)
        let nodes = [
            pane(1, w: 40, h: 24), pane(2, w: 40, h: 11), pane(3, w: 40, h: 12),
            node(kind: .vertical, w: 40, h: 24, start: 1, len: 2),
            pane(1, w: 40, h: 24),
            node(kind: .vertical, w: 40, h: 24, start: 1, len: 2),
            node(kind: .horizontal, w: 81, h: 24, start: 4, len: 2),
        ]
        let layout = try #require(TmuxSplitLayout.build(nodes: nodes, root: 6))
        guard case .split(let dir, _, let left, let right) = layout,
              case .split(let innerDir, _, let innerL, let innerR) = right else {
            Issue.record("expected nested split"); return
        }
        #expect(dir == .horizontal)
        #expect(left == .pane(id: 1))
        #expect(innerDir == .vertical)
        #expect(innerL == .pane(id: 2))
        #expect(innerR == .pane(id: 3))
    }

    @Test func invalidIndicesReturnNil() {
        #expect(TmuxSplitLayout.build(nodes: [], root: 0) == nil)
        let bad = [node(kind: .horizontal, w: 80, h: 24, start: 5, len: 2)]
        #expect(TmuxSplitLayout.build(nodes: bad, root: 0) == nil)
        let empty = [node(kind: .horizontal, w: 80, h: 24, start: 0, len: 0)]
        #expect(TmuxSplitLayout.build(nodes: empty, root: 0) == nil)
    }
}
```

为可测性给 `Ghostty.TmuxNode` 补 internal memberwise init(Task 5 文件里,一并提交)。

- [ ] **Step 2: 跑测试确认失败**

Run: `xcodebuild test -project macos/Ghostty.xcodeproj -scheme Ghostty -only-testing:GhosttyTests/TmuxSplitLayoutTests CODE_SIGNING_ALLOWED=NO`
Expected: 编译失败(TmuxSplitLayout 不存在)。

- [ ] **Step 3: 实现**

```swift
/// A pure description of a tmux window layout as a binary split tree:
/// tmux n-ary splits are folded right-associatively, with each split's
/// ratio derived from the children's sizes along the split axis. This
/// stays free of UI types so it is fully unit-testable; mapping pane
/// ids to SurfaceViews happens in TmuxSessionController.
enum TmuxSplitLayout: Equatable {
    case pane(id: UInt)
    indirect case split(
        direction: Direction,
        ratio: Double,
        left: TmuxSplitLayout,
        right: TmuxSplitLayout)

    enum Direction: Equatable {
        case horizontal
        case vertical
    }

    static func build(nodes: [Ghostty.TmuxNode], root: Int) -> TmuxSplitLayout? {
        guard root >= 0, root < nodes.count else { return nil }
        let node = nodes[root]
        switch node.kind {
        case .pane:
            return .pane(id: node.paneId)
        case .horizontal, .vertical:
            let dir: Direction = node.kind == .horizontal ? .horizontal : .vertical
            guard node.childrenLen >= 1,
                  node.childrenStart >= 0,
                  node.childrenStart + node.childrenLen <= nodes.count
            else { return nil }
            return buildRun(
                nodes: nodes, direction: dir,
                start: node.childrenStart, len: node.childrenLen)
        }
    }

    private static func buildRun(
        nodes: [Ghostty.TmuxNode],
        direction: Direction,
        start: Int,
        len: Int
    ) -> TmuxSplitLayout? {
        func axisSize(_ n: Ghostty.TmuxNode) -> Double {
            Double(direction == .horizontal ? n.width : n.height)
        }
        guard let first = build(nodes: nodes, root: start) else { return nil }
        if len == 1 { return first }
        guard let rest = buildRun(
            nodes: nodes, direction: direction,
            start: start + 1, len: len - 1) else { return nil }
        var total = 0.0
        for i in start..<(start + len) { total += axisSize(nodes[i]) }
        guard total > 0 else { return nil }
        return .split(
            direction: direction,
            ratio: axisSize(nodes[start]) / total,
            left: first,
            right: rest)
    }
}
```

- [ ] **Step 4: 验证**

Run: Step 2 的命令 → 全部 PASS。另跑 `xcodebuild ... -target Ghostty ... build` 确认主 target 也编译。

- [ ] **Step 5: 提交**

```bash
git add -A && git commit -m "feat(macos): pure tmux layout to binary split conversion"
```

---

### Task 7: TmuxSessionManager 与 TmuxSessionController 生命周期骨架

app 级注册表(宿主 SurfaceView → 会话控制器)+ 会话控制器的 attach/exit 生命周期与 router 引用管理。windows 事件本任务只打日志(Task 8 实现)。

**Files:**
- Create: `macos/Sources/Features/Tmux/TmuxSessionManager.swift`
- Create: `macos/Sources/Features/Tmux/TmuxSessionController.swift`
- Modify: `macos/Sources/App/macOS/AppDelegate.swift`(实例化 manager)

**Interfaces:**
- Consumes: Task 5 通知与模型;Task 3 `ghostty_tmux_router_command/release`。
- Produces(Task 8-11 依赖):
  - `TmuxSessionManager.shared`(观察 `.ghosttyTmux`,路由到会话)
  - `TmuxSessionController`:`init(ghostty: Ghostty.App, host: Ghostty.SurfaceView, router: UnsafeMutableRawPointer)`、`func apply(_ ev: Ghostty.TmuxWindows)`(本任务打日志)、`func teardown()`、`func send(_ cmd: ghostty_tmux_command_s)`、`private(set) var isTearingDown: Bool`

- [ ] **Step 1: 实现 TmuxSessionManager**

```swift
import AppKit

/// Routes tmux control mode events (posted by Ghostty.App from the
/// GHOSTTY_ACTION_TMUX action) to per-session controllers, keyed by
/// the host surface running `tmux -CC`.
final class TmuxSessionManager {
    static let shared = TmuxSessionManager()

    private var sessions: [ObjectIdentifier: TmuxSessionController] = [:]

    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onTmuxEvent(_:)),
            name: .ghosttyTmux,
            object: nil)
    }

    @objc private func onTmuxEvent(_ notification: Notification) {
        guard let host = notification.object as? Ghostty.SurfaceView,
              let event = notification.userInfo?[Ghostty.Notification.TmuxEventKey]
                as? Ghostty.TmuxEvent
        else { return }
        let key = ObjectIdentifier(host)

        switch event {
        case .attach(let router):
            guard sessions[key] == nil else {
                // Duplicate attach for a live session: we own the new
                // reference, give it back.
                ghostty_tmux_router_release(router)
                return
            }
            guard let appDelegate = NSApp.delegate as? AppDelegate else {
                ghostty_tmux_router_release(router)
                return
            }
            sessions[key] = TmuxSessionController(
                ghostty: appDelegate.ghostty,
                host: host,
                router: router)

        case .windows(let windows):
            sessions[key]?.apply(windows)

        case .exit:
            sessions[key]?.teardown()
            sessions[key] = nil
        }
    }
}
```

- [ ] **Step 2: 实现 TmuxSessionController 骨架**

```swift
import AppKit

/// Owns the native UI for one `tmux -CC` session: a dedicated window
/// group where each tmux window is a native tab and each pane a native
/// split. The controller is the subordinate side of the sync: tmux
/// state (delivered as windows events) is authoritative, and native
/// close/focus/resize gestures are translated into tmux commands whose
/// effects come back as new windows events.
final class TmuxSessionController {
    let ghostty: Ghostty.App
    private(set) weak var hostView: Ghostty.SurfaceView?
    private(set) var router: UnsafeMutableRawPointer?
    private(set) var isTearingDown = false

    /// tmux window id -> native tab controller (Task 8).
    var windows: [UInt: TmuxTerminalController] = [:]
    /// tmux pane id -> its surface view. Panes are create-once: a pane
    /// id never comes back after its surface is gone (detached is a
    /// terminal state core-side and tmux never reuses ids).
    var panes: [UInt: Ghostty.SurfaceView] = [:]

    init(
        ghostty: Ghostty.App,
        host: Ghostty.SurfaceView,
        router: UnsafeMutableRawPointer
    ) {
        self.ghostty = ghostty
        self.hostView = host
        self.router = router
        Ghostty.logger.info("tmux session attached")
    }

    func apply(_ ev: Ghostty.TmuxWindows) {
        guard !isTearingDown else { return }
        // Task 8 implements the diff; log for now.
        Ghostty.logger.info("tmux windows event count=\(ev.windows.count)")
    }

    /// End of session (%exit or host death): close every native window
    /// without emitting tmux commands, then drop our router reference.
    func teardown() {
        guard !isTearingDown else { return }
        isTearingDown = true
        for (_, controller) in windows { controller.tmuxForceClose() }
        windows.removeAll()
        panes.removeAll()
        releaseRouter()
        Ghostty.logger.info("tmux session ended")
    }

    func send(_ cmd: ghostty_tmux_command_s) {
        guard let router else { return }
        ghostty_tmux_router_command(router, cmd)
    }

    private func releaseRouter() {
        guard let router else { return }
        ghostty_tmux_router_release(router)
        self.router = nil
    }

    deinit {
        releaseRouter()
    }
}
```

本任务为编译通过,`TmuxTerminalController` 先建占位文件(Task 8 充实):

```swift
/// A TerminalController for one tmux window (= one native tab in the
/// session's dedicated window group). Task 8+ fill in construction,
/// close mapping and resize.
class TmuxTerminalController: TerminalController {
    weak var session: TmuxSessionController?
    var tmuxWindowId: UInt = 0
    private var forceClosing = false

    /// Close this window bypassing tmux command mapping and
    /// confirmations (used during session teardown or after tmux
    /// itself removed the window).
    func tmuxForceClose() {
        forceClosing = true
        window?.close()
    }
}
```

- [ ] **Step 3: AppDelegate 挂载 manager**

`applicationDidFinishLaunching`(或同等启动点,照现有代码结构)加一行注释清晰的激活:

```swift
        // Start routing tmux control mode events to session controllers.
        _ = TmuxSessionManager.shared
```

- [ ] **Step 4: 构建验证 + 日志冒烟**

```bash
zig build -Demit-macos-app=false
xcodebuild -project macos/Ghostty.xcodeproj -target Ghostty -configuration Debug CODE_SIGNING_ALLOWED=NO build
xattr -rc macos/build && codesign --force --deep --sign - macos/build/Debug/Ghostty.app
```

冒烟:同 Task 1 Step 10 启动,log stream 里期望看到 `tmux session attached`、`tmux windows event count=1`;`tmux kill-session` 后看到 `tmux session ended`,且**再次 attach 正常**(验证 manager 清理与重复 attach 引用释放)。

- [ ] **Step 5: 提交**

```bash
git add -A && git commit -m "feat(macos): tmux session manager and controller lifecycle"
```

---

### Task 8: windows diff → 原生标签页与 pane surface

会话专属窗口组:首个 tmux window 开新窗(独立 tabbingIdentifier,不与普通窗口混tab),其余 window 作为标签加入;每个标签的 surfaceTree 由 TmuxSplitLayout 映射为真实 SurfaceView 的 SplitTree;pane surface 带 tmux 配置,核心自动接管内容。窗口被 tmux 删除 → 强制关标签。改名与布局更新在 Task 9。

**Files:**
- Modify: `macos/Sources/Features/Tmux/TmuxSessionController.swift`
- Modify: `macos/Sources/Features/Tmux/TmuxTerminalController.swift`(从 Task 7 占位长成真实实现;若 Task 7 把它放在 TmuxSessionController.swift 里,拆成独立文件)

**Interfaces:**
- Consumes: Task 5 SurfaceConfiguration tmux 字段、Task 6 `TmuxSplitLayout.build`、`TerminalController.init(_:withBaseConfig:withSurfaceTree:parent:)`、`SplitTree`(值类型,root Node 可直接构造)、`NSWindow.addTabbedWindowSafely(_:ordered:)`、`BaseTerminalController.titleOverride`。
- Produces(Task 9-11 依赖):`TmuxSessionController.surfaceView(forPane:) -> Ghostty.SurfaceView?`、`makeTree(_ layout: TmuxSplitLayout) -> SplitTree<Ghostty.SurfaceView>?`、`paneId(of view: Ghostty.SurfaceView) -> UInt?`;`TmuxTerminalController` 真实构造(`session`/`tmuxWindowId` 注入)。

- [ ] **Step 1: 实现 pane surface 工厂与树构造(TmuxSessionController)**

```swift
    /// Get or create the surface view for a tmux pane. Create-once:
    /// once a pane's surface is gone the id never comes back (tmux
    /// does not reuse ids), so a cache hit is always the live view.
    func surfaceView(forPane id: UInt) -> Ghostty.SurfaceView? {
        if let view = panes[id] { return view }
        guard let app = ghostty.app else { return nil }
        var config = Ghostty.SurfaceConfiguration()
        config.tmuxRouter = router
        config.tmuxPaneId = id
        let view = Ghostty.SurfaceView(app, baseConfig: config)
        panes[id] = view
        return view
    }

    func paneId(of view: Ghostty.SurfaceView) -> UInt? {
        panes.first(where: { $0.value === view })?.key
    }

    func makeTree(_ layout: TmuxSplitLayout) -> SplitTree<Ghostty.SurfaceView>? {
        guard let node = makeNode(layout) else { return nil }
        return SplitTree(root: node, zoomed: nil)
    }

    private func makeNode(_ layout: TmuxSplitLayout) -> SplitTree<Ghostty.SurfaceView>.Node? {
        switch layout {
        case .pane(let id):
            guard let view = surfaceView(forPane: id) else { return nil }
            return .leaf(view: view)
        case .split(let direction, let ratio, let left, let right):
            guard let l = makeNode(left), let r = makeNode(right) else { return nil }
            return .split(.init(
                direction: direction == .horizontal ? .horizontal : .vertical,
                ratio: ratio,
                left: l,
                right: r))
        }
    }
```

(`SplitTree`/`Node`/`Split` 的构造细节——memberwise init 是否可用、Direction 命名——以 `macos/Sources/Features/Splits/SplitTree.swift` 实际为准;同模块 internal 可直接构造。若 `SplitTree(root:zoomed:)` 不存在,加一个 internal init 或用现有 API 等价构造。)

- [ ] **Step 2: 实现 windows diff(apply)**

```swift
    /// The session's dedicated tab group identity.
    private let tabbingId = "com.mitchellh.ghostty.tmux." + UUID().uuidString

    func apply(_ ev: Ghostty.TmuxWindows) {
        guard !isTearingDown else { return }
        let incoming = Dictionary(uniqueKeysWithValues: ev.windows.map { ($0.id, $0) })

        // tmux removed these windows: close their tabs without
        // commands or confirmation (tmux already acted).
        for (id, controller) in windows where incoming[id] == nil {
            windows[id] = nil
            controller.tmuxForceClose()
        }

        // Added or kept windows, in tmux order.
        for w in ev.windows {
            if let existing = windows[w.id] {
                existing.tmuxUpdate(window: w, nodes: ev.nodes) // Task 9
            } else {
                addWindow(w, nodes: ev.nodes)
            }
        }

        prunePanes(keeping: ev)
    }

    private func addWindow(_ w: Ghostty.TmuxWindow, nodes: [Ghostty.TmuxNode]) {
        guard let layout = TmuxSplitLayout.build(nodes: nodes, root: w.root),
              let tree = makeTree(layout)
        else {
            Ghostty.logger.warning("tmux window \(w.id) layout invalid, skipped")
            return
        }

        let controller = TmuxTerminalController(
            ghostty,
            session: self,
            tmuxWindowId: w.id,
            tree: tree)
        controller.titleOverride = w.name
        windows[w.id] = controller

        guard let window = controller.window else { return }
        window.isRestorable = false
        window.tabbingIdentifier = tabbingId

        if let groupWindow = anyLiveWindow(), groupWindow !== window {
            groupWindow.tabGroup?.windows.last?
                .addTabbedWindowSafely(window, ordered: .above)
                ?? groupWindow.addTabbedWindowSafely(window, ordered: .above)
        }
        controller.showWindow(nil)
    }

    private func anyLiveWindow() -> NSWindow? {
        windows.values.compactMap(\.window).first
    }

    /// Drop cached panes that no longer appear in any window's layout.
    /// Their views were already released by the tree replacements; the
    /// core viewer marks them detached when the surface unregisters.
    private func prunePanes(keeping ev: Ghostty.TmuxWindows) {
        var live = Set<UInt>()
        for node in ev.nodes where node.kind == .pane { live.insert(node.paneId) }
        panes = panes.filter { live.contains($0.key) }
    }
```

注意 `addTabbedWindowSafely ??` 那两行是意图示意——Swift 可选链不能这样连;实现写成清晰的 if-let(先取 `tabGroup?.windows.last`,取不到用 groupWindow 本体)。

- [ ] **Step 3: TmuxTerminalController 真实构造**

```swift
class TmuxTerminalController: TerminalController {
    private(set) weak var session: TmuxSessionController?
    private(set) var tmuxWindowId: UInt = 0
    private var forceClosing = false

    convenience init(
        _ ghostty: Ghostty.App,
        session: TmuxSessionController,
        tmuxWindowId: UInt,
        tree: SplitTree<Ghostty.SurfaceView>
    ) {
        self.init(ghostty, withBaseConfig: nil, withSurfaceTree: tree, parent: nil)
        self.session = session
        self.tmuxWindowId = tmuxWindowId
    }

    func tmuxUpdate(window: Ghostty.TmuxWindow, nodes: [Ghostty.TmuxNode]) {
        // Task 9.
        titleOverride = window.name
    }

    func tmuxForceClose() {
        forceClosing = true
        window?.close()
    }
}
```

(designated/convenience 形态按 `TerminalController.init` 实际声明调整;若 super init 有 required 语义按编译器提示改。窗口何时可用(`controller.window` 懒加载于 showWindow/windowNibName 路径)——若 addWindow 时 `controller.window` 为 nil,先 `showWindow(nil)` 再做 tab 编组与属性设置,参考 `TerminalController.newWindow`/恢复路径的顺序。)

- [ ] **Step 4: 构建 + 冒烟(本计划第一次真实 UI)**

构建/签名同前。冒烟场景(tmux ≥3.2,本机):

1. `tmux -CC new-session -s smoke` → 出现**新窗口**,一个标签,标题为 tmux window 名,pane 内容可见(zsh 提示符)、能打字回显。
2. 普通终端 `tmux new-window -t smoke` → Ghostty 出现第二个标签。
3. `tmux split-window -t smoke` → 对应标签出现原生分屏,两个 pane 内容各自正确。
4. `tmux kill-window` 其中一个 → 对应标签关闭,无确认弹窗,app 不崩。
5. `tmux kill-session` → 所有 tmux 窗口关闭,宿主 surface 回普通终端。
6. 期间宿主 surface 所在窗口保持原样(不混入 tmux 标签组)。

在 log stream 观察无 error 级日志。逐条记录结果到台账。

- [ ] **Step 5: 提交**

```bash
git add -A && git commit -m "feat(macos): tmux windows diff to native tabs with pane surfaces"
```

---

### Task 9: 布局更新与焦点同步

kept 窗口的布局变化(tmux 侧 split/kill-pane/resize 回流)→ 重建该标签的 SplitTree(SurfaceView 按 pane id 复用,内容不闪断);GUI 焦点变化 → `select-pane`。

**Files:**
- Modify: `macos/Sources/Features/Tmux/TmuxTerminalController.swift`
- Modify: `macos/Sources/Features/Tmux/TmuxSessionController.swift`(如需暴露辅助)

**Interfaces:**
- Consumes: Task 8 的 makeTree/surfaceView(forPane:)/paneId(of:)、`BaseTerminalController.replaceSurfaceTree(_:moveFocusTo:moveFocusFrom:undoAction:)`、Task 3 `select_pane` 命令。
- Produces: `tmuxUpdate(window:nodes:)` 完整实现。

- [ ] **Step 1: 实现 tmuxUpdate 的布局重建**

```swift
    func tmuxUpdate(window w: Ghostty.TmuxWindow, nodes: [Ghostty.TmuxNode]) {
        if titleOverride != w.name { titleOverride = w.name }

        guard let session,
              let layout = TmuxSplitLayout.build(nodes: nodes, root: w.root)
        else { return }

        // Skip the churn when the pane structure is unchanged: ratios
        // only move on real layout changes, and rebuilding the tree
        // swaps views in and out of the hierarchy.
        if treeSignature(surfaceTree) == layoutSignature(layout) { return }

        guard let newTree = session.makeTree(layout) else { return }
        let keepFocus = focusedSurface.flatMap { fs in
            newTree.contains(fs) ? fs : nil
        }
        replaceSurfaceTree(
            newTree,
            moveFocusTo: keepFocus ?? newTree.first,   // first leaf;取法照 SplitTree 现有遍历 API
            moveFocusFrom: focusedSurface,
            undoAction: nil)
    }
```

签名比较的两个纯辅助(结构 + ratio,粒度到 pane id):

```swift
    private func layoutSignature(_ l: TmuxSplitLayout) -> String {
        switch l {
        case .pane(let id): return "p\(id)"
        case .split(let d, let r, let left, let right):
            let dir = d == .horizontal ? "h" : "v"
            return "\(dir)[\(String(format: "%.3f", r)):\(layoutSignature(left)),\(layoutSignature(right))]"
        }
    }

    private func treeSignature(_ t: SplitTree<Ghostty.SurfaceView>) -> String {
        // 对 SplitTree.Node 做同构遍历:leaf → "p<paneId>"(经
        // session.paneId(of:),未知视图给 "p?" 保证不等),split →
        // 同上格式。遍历 API 以 SplitTree.swift 实际为准。
    }
```

(`newTree.first`/`contains` 等以 SplitTree 实际 API 为准——研究确认有 `contains`;第一个 leaf 的取法参考 SplitTree 的迭代或 focusTarget 实现。`replaceSurfaceTree` 的 undoAction 传 nil 避免把 tmux 回流塞进撤销栈。)

- [ ] **Step 2: 焦点 → select-pane**

`TmuxTerminalController` 加:

```swift
    override var focusedSurface: Ghostty.SurfaceView? {
        didSet {
            guard !forceClosing,
                  let session, !session.isTearingDown,
                  let view = focusedSurface,
                  let paneId = session.paneId(of: view)
            else { return }
            // Fire and forget; tmux state is authoritative and any
            // failure just leaves tmux's active pane behind ours.
            session.send(ghostty_tmux_command_s(
                tag: GHOSTTY_TMUX_COMMAND_SELECT_PANE,
                id: UInt(paneId), width: 0, height: 0))
        }
    }
```

(若 `focusedSurface` 在 Base 中的声明形态不允许 override 加观察器,退路:在 TmuxTerminalController 监听现有焦点通知/`syncFocusToSurfaceTree` 调用点,语义不变。C struct 构造字段名以生成的 Swift 接口为准。)

- [ ] **Step 3: 构建 + 冒烟**

构建/签名同前。冒烟:

1. attach 后普通终端 `tmux split-window -t smoke` / `tmux kill-pane` → 标签内分屏实时增减,存活 pane 内容不闪断(复用验证)。
2. `tmux rename-window` → 标签标题实时变。
3. Ghostty 内点击切换 pane 焦点 → 普通终端 `tmux display-message -p '#{pane_active}'`(或对照另一个 attach 的普通 tmux 客户端)确认 active pane 跟随。
4. 无限循环输出(`yes` 跑在一个 pane)时做 2/3 → 无卡死。

- [ ] **Step 4: 提交**

```bash
git add -A && git commit -m "feat(macos): tmux layout updates and focus sync"
```

---

### Task 10: 关闭映射(kill-pane / kill-window / detach)

原生关闭手势翻译成 tmux 命令,**本地不动**——tmux 处理后的 windows 事件回流才真正收掉 UI(tmux 心智:GUI 是从属方)。会话收尾/tmux 已删除的强制关闭绕过映射。

**Files:**
- Modify: `macos/Sources/Features/Tmux/TmuxTerminalController.swift`

**Interfaces:**
- Consumes: Task 3 命令、`TerminalController` 的关闭链路(`closeTab`/`closeWindow` action 方法与 `confirmClose(surfaces:)`,以实际代码为准)。
- Produces: 完整关闭语义:pane 关闭 → `kill-pane`;标签关闭 → `kill-window`;整窗关闭 → `detach-client`(整个会话所有标签收尾);teardown/forceClosing → 直通 super。

- [ ] **Step 1: 研读现有关闭链路**

打开 `TerminalController.swift` 与 `BaseTerminalController.swift`,列出:`closeTab(_:)`/`closeWindow(_:)` 的方法签名与确认弹窗调用;单 surface 关闭的入口(`ghosttyCloseSurface` 通知的 handler 名);`windowShouldClose` → TabGroupCloseCoordinator 的 scope 分发。把发现记进实现说明(评审需要)。

- [ ] **Step 2: 实现三个 override**

按 Step 1 发现的真实签名 override;语义如下(代码形状示意,confirm 复用现有弹窗助手):

```swift
    // Tab close (⌘W on tab / tab close button): kill-window. The tab
    // disappears when tmux confirms via the next windows event.
    override func closeTab(_ sender: Any?) {
        guard !forceClosing, let session, !session.isTearingDown else {
            super.closeTab(sender)
            return
        }
        confirmTmux(surfaces: surfaceTree.filter { $0.needsConfirmQuit }) { [weak self] in
            guard let self, let session = self.session else { return }
            session.send(ghostty_tmux_command_s(
                tag: GHOSTTY_TMUX_COMMAND_KILL_WINDOW,
                id: UInt(self.tmuxWindowId), width: 0, height: 0))
        }
    }

    // Window close (red button / ⌘⇧W): detach the whole session; the
    // tmux session survives and %exit tears down every tab.
    override func closeWindow(_ sender: Any?) {
        guard !forceClosing, let session, !session.isTearingDown else {
            super.closeWindow(sender)
            return
        }
        session.send(ghostty_tmux_command_s(
            tag: GHOSTTY_TMUX_COMMAND_DETACH, id: 0, width: 0, height: 0))
    }

    // Single surface close (pane exit / close split): kill-pane.
    // (override 的具体方法名以 Step 1 的发现为准)
    ... {
        guard !forceClosing, let session, !session.isTearingDown,
              let paneId = session.paneId(of: surfaceView) else { super...; return }
        confirmTmux(surfaces: [surfaceView]) { [weak self] in
            self?.session?.send(ghostty_tmux_command_s(
                tag: GHOSTTY_TMUX_COMMAND_KILL_PANE,
                id: UInt(paneId), width: 0, height: 0))
        }
    }
```

`confirmTmux(surfaces:onConfirm:)`:surfaces 为空直接执行;否则调现有 `confirmClose`(或同等确认助手)并在确认回调里执行——kill 会杀远端进程,确认弹窗语义保留。detach 不确认(会话保留,无损)。

- [ ] **Step 3: 构建 + 冒烟**

1. 关一个分屏 pane(关闭手势)→ 弹确认(若 shell 有子进程)→ 确认后该 pane 消失,`tmux ls` 对应 pane 少一;取消则无事。
2. 关标签 → 同上,对应 tmux window 消失。
3. 关最后一个标签 → kill-window → tmux 会话随之结束 → %exit → 全部收尾,宿主回普通终端。
4. 红点关窗 → 所有 tmux 标签关闭,**`tmux ls` 会话仍在**(detached);再次 attach 完整重建。
5. teardown 路径(kill-session)不触发任何确认弹窗。

- [ ] **Step 4: 提交**

```bash
git add -A && git commit -m "feat(macos): map native close gestures to tmux commands"
```

---

### Task 11: resize(refresh-client -C)

原生窗口 resize → 换算成字符网格 → `refresh-client -C <cols>x<rows>` → tmux 重排 → %layout-change 回流(Task 9 已处理重建)。布局回流引起的 pane 视图变化不改窗口 frame,不会反向触发,天然无回环。

**Files:**
- Modify: `macos/Sources/Features/Tmux/TmuxTerminalController.swift`
- Modify: `macos/Sources/Features/Tmux/TmuxSessionController.swift`(去重)

**Interfaces:**
- Consumes: `ghostty_surface_size(ghostty_surface_t) -> ghostty_surface_size_s`(`cell_width_px`/`cell_height_px`,include/ghostty.h:1182、484-491)、SurfaceView 的底层 `ghostty_surface_t` 访问属性(以 SurfaceView 实际字段为准,研究显示为 `surface`)、Task 3 `resize` 命令。
- Produces: `TmuxSessionController.sendResize(cols: Int, rows: Int)`(去重后发命令)。

- [ ] **Step 1: session 侧去重**

```swift
    private var lastResize: (cols: Int, rows: Int)? = nil

    /// Send refresh-client -C, deduplicating repeats: every tab shares
    /// the same client size, so tab switches and duplicate resize
    /// events would otherwise spam tmux.
    func sendResize(cols: Int, rows: Int) {
        guard !isTearingDown, cols > 1, rows > 1 else { return }
        if let last = lastResize, last == (cols, rows) { return }
        lastResize = (cols, rows)
        send(ghostty_tmux_command_s(
            tag: GHOSTTY_TMUX_COMMAND_RESIZE,
            id: 0, width: UInt(cols), height: UInt(rows)))
    }
```

- [ ] **Step 2: controller 侧观测与换算**

`TmuxTerminalController`:

```swift
    private var pendingResize: DispatchWorkItem?

    func windowDidResize(_ notification: Notification) {
        // Base/super 若实现了同名 delegate 方法则先调 super(以实际为准)
        scheduleTmuxResize()
    }

    private func scheduleTmuxResize() {
        pendingResize?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.sendTmuxResize() }
        pendingResize = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    /// Translate our content size to a tmux client grid. Cell metrics
    /// come from any live pane surface (uniform font); tmux then owns
    /// the actual per-pane dimensions via the layout that flows back.
    private func sendTmuxResize() {
        guard !forceClosing, let session, !session.isTearingDown,
              let window,
              let contentView = window.contentView,
              let anyPane = surfaceTree.first(where: { $0.surface != nil }),
              let surface = anyPane.surface
        else { return }

        let size = ghostty_surface_size(surface)
        guard size.cell_width_px > 0, size.cell_height_px > 0 else { return }
        let scale = window.backingScaleFactor
        let cols = Int((contentView.bounds.width * scale) / CGFloat(size.cell_width_px))
        let rows = Int((contentView.bounds.height * scale) / CGFloat(size.cell_height_px))
        session.sendResize(cols: cols, rows: rows)
    }
```

(`surfaceTree.first(where:)` 的遍历、SurfaceView 暴露 `ghostty_surface_t` 的属性名、`windowDidResize` 在 Base 的既有实现——都以实际代码为准;若 Base 已实现 delegate 方法,用 override + super。首个 windows 布局落地后主动调一次 `scheduleTmuxResize()`(在 tmuxUpdate/初次显示后),把初始网格对齐 tmux。)

- [ ] **Step 3: 构建 + 冒烟**

1. attach 后拖拽窗口变大/变小 → 停止拖拽 ~0.1s 后,pane 分屏重排,`tmux display-message -p '#{client_width}x#{client_height}'`(对照普通客户端)显示新尺寸;内容 reflow 正确。
2. 快速连续拖拽 → 不出现命令风暴(log 观察),最终状态一致。
3. 双客户端(Ghostty -CC + 普通 tmux attach)同时在线,Ghostty resize → 普通客户端可见尺寸联动(tmux 取小者,现象符合 tmux 语义即可)。

- [ ] **Step 4: 提交**

```bash
git add -A && git commit -m "feat(macos): drive tmux client size from native window resize"
```

---

### Task 12: 端到端冒烟、台账与交接

**Files:**
- Modify: `.superpowers/sdd/progress.md`
- Create: `.superpowers/sdd/plan2-smoke-report.md`
- Create: `docs/superpowers/handoff/<日期>-plan2-complete.md`(收尾交接:遗留 backlog、上游 PR 建议)

- [ ] **Step 1: 全量回归**

```bash
zig build test -Dtest-filter=tmux --summary all   # 全绿,记录命中数
zig build -Demit-macos-app=false                  # exit 0
zig build && xcodebuild -project macos/Ghostty.xcodeproj -target Ghostty -configuration Debug CODE_SIGNING_ALLOWED=NO build
xcodebuild test -project macos/Ghostty.xcodeproj -scheme Ghostty -only-testing:GhosttyTests/TmuxSplitLayoutTests -only-testing:GhosttyTests/GhosttyTmuxTests CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 2: spec 成功标准逐条冒烟**

场景清单(全部用真实 zsh pane,这是 Task 1 修复前的死亡场景;结果逐条记入 plan2-smoke-report.md,含日志摘录):

1. 本机 `tmux -CC new-session`:窗口/标签/分屏正确呈现,含历史与可见内容(先在普通客户端造历史再 attach)。
2. 打字、粘贴中等文本、Ctrl-C、TUI 程序(`htop` 或 `vim`)交互正常。
3. tmux 侧新建/关闭 window、split/kill pane、rename → UI 实时同步。
4. 原生关闭:pane/标签/整窗(detach)语义符合 Task 10 定义;detach 后 `tmux ls` 会话保留,重复 attach/detach 3 轮无泄漏迹象(log 无 error,无僵尸窗口)。
5. resize 双向表现(Task 11 场景)。
6. SSH 远端 tmux -CC(若无远端环境,用 `ssh localhost` 模拟;不可行则记录跳过原因)。
7. 双客户端同时 attach(Ghostty -CC + 普通 tmux):互相观察输出/结构同步。
8. 版本门槛:若本机可装 tmux 3.1(brew 无旧版则跳过并记录),验证主动 detach 与日志。
9. 崩溃回归:整个清单过程中 app 零崩溃、宿主 surface 始终可回收使用。

- [ ] **Step 3: 台账与交接文档**

progress.md 追加计划二各任务行与最终状态;交接文档写明:未做事项(GTK 端、反向新建映射、send-keys 吞吐、route() 异步化、pane 内 active 焦点回流)、已知限制、上游 PR 拆分建议(UAF 修复 `d082e6e8a` 独立可提的现状不变)。

- [ ] **Step 4: 提交**

```bash
git add -A && git commit -m "docs: plan 2 smoke report and completion handoff"
```

---

## Self-Review 记录(计划作者已核)

1. **Spec 覆盖**:阶段 3(管道→UI:Task 5/7/8)、阶段 4(交互闭环:Task 9/10/11)、阶段 5(加固:Task 1/2/3/4 + Task 12 回归);spec §5 错误处理:竞态→既定决策 2 与 Task 8 create-once、宿主关闭→Task 3 App.zig ref 归还 + Task 7 teardown、版本门槛→Task 4、%error→维持计划一日志行为、背压→既定决策 4(backlog)。
2. **接口一致性**:`ghostty_tmux_router_command/release`、`ghostty_tmux_command_s`(Task 3 ↔ 5/7/9/10/11)、`TmuxEvent/TmuxWindows/TmuxNode`(Task 5 ↔ 6/7/8)、`TmuxSplitLayout.build`(Task 6 ↔ 8/9)、`surfaceView(forPane:)/paneId(of:)/makeTree`(Task 8 ↔ 9/10/11)、`sendResize`(Task 11 内部)均已交叉核对。
3. **不确定性均已显式标注**「以实际代码为准」并给出研究出处的锚点(文件+行号),无 TBD/TODO 类占位。
