# 计划三:tmux -CC A 级功能补全 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** GUI 反向操作(新建 window/pane、rename、批量关闭映射)+ 反向焦点 + send-keys literal 快路径,对齐 iTerm2 tmux -CC 的 A 级交互。

**Architecture:** 全部功能沿既有六环节管道(controller → session.send → C ABI → formatCommand → viewer 队列 → tmux)加分支;tmux→GUI 方向经 viewer action → TmuxEvent → NotificationCenter → TmuxSessionController。零新长期组件;新状态仅 Swift 侧焦点抑制标志 + pendingFocusWindowId。Spec: `docs/superpowers/specs/2026-07-30-tmux-cc-plan3-design.md`。

**Tech Stack:** Zig(核心/协议,`zig build test -Dtest-filter=tmux`)、Swift/AppKit(macOS UI,xcodebuild + Swift Testing)、tmux ≥3.2。

## Global Constraints

- 仓库:`/Users/zouchaoxu/Desktop/ghostty/ghostty`,分支 `tmux-cc-core`。**禁止创建 issue/PR**(仓库 CLAUDE.md)。
- Zig 命令一律剥代理:`env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY zig build ...`
- 基线只增不减:`-Dtest-filter=tmux`(小写)**不覆盖** `TmuxRouter`/`TmuxKeyEncode` 等大写驼峰模块名的测试(Zig test filter 大小写敏感,子串匹配的是模块限定名,不含文件路径)——门禁须双跑:`-Dtest-filter=tmux`(当前 **214/214**)与 `-Dtest-filter=Tmux`(大写,覆盖 `TmuxRouter`/`TmuxKeyEncode` 等,当前 **81/81**),两个计数都只增不减;GhosttyTests 全绿;`zig build -Demit-macos-app=false` 0 错。
- Swift 测试:`xcodebuild test -project macos/Ghostty.xcodeproj -scheme Ghostty -only-testing:GhosttyTests CODE_SIGNING_ALLOWED=NO`(从仓库根跑)。
- 新增 macOS Swift 源文件必须同时登记到 `macos/Ghostty.xcodeproj/project.pbxproj` 的 **Ghostty-iOS 排除清单**(`membershipExceptions`,现有 `Features/Tmux/*.swift` 条目旁,字母序);`macos/Tests/` 下的测试文件不需要。
- tmux 版本门槛 ≥3.2(启动时已强制),新代码**不写版本分支**。
- tmux 权威不变量:GUI 不本地改 tmux 拥有的状态,一切经命令 → 通知回流。
- 每任务提交后:`git push backup tmux-cc-core && git push fork tmux-cc-core`。
- 台账:任务完成追记 `.superpowers/sdd/progress.md`(git-ignored)。
- iTerm2 参考(按需):`git clone --depth 1 https://github.com/gnachman/iTerm2` 到 scratchpad;按键编码 TmuxGateway.m:937-1025,命令形态 TmuxController.m。

---

### Task 1: ABI 扩展 + formatCommand 新命令(Zig 纯管道)

**Files:**
- Modify: `include/ghostty.h`(~849 行 `ghostty_tmux_command_tag_e`、~855 行 `ghostty_tmux_command_s`)
- Modify: `src/apprt/action.zig:948-969`(`TmuxCommand`)
- Modify: `src/termio/TmuxRouter.zig:107-118`(`formatCommand`)+ 同文件测试区(~295 行起)
- Modify: `src/apprt/embedded.zig:2104-2117`(`ghostty_tmux_router_command` 栈缓冲 128→512)

**Interfaces:**
- Consumes: 现有 `TmuxCommand` extern struct(tag/id/width/height)、`checkGhosttyHEnum` 测试基建。
- Produces(后续任务依赖,签名精确):
  - C tag 枚举追加(**顺序固定,追加在 `GHOSTTY_TMUX_COMMAND_RESIZE` 之后**):`GHOSTTY_TMUX_COMMAND_NEW_WINDOW`、`GHOSTTY_TMUX_COMMAND_SPLIT_HORIZONTAL`、`GHOSTTY_TMUX_COMMAND_SPLIT_VERTICAL`、`GHOSTTY_TMUX_COMMAND_RENAME_WINDOW`、`GHOSTTY_TMUX_COMMAND_SELECT_WINDOW`
  - C struct 追加字段:`const char* text;`(放 height 之后;rename 用,其余 NULL)
  - Zig `TmuxCommand.Tag` 同序追加 `new_window, split_horizontal, split_vertical, rename_window, select_window`;struct 追加 `text: ?[*:0]const u8 = null`
  - 语义约定:split 的 `id`=目标 pane id,`width != 0` 表示 `-b`(before,前插);rename/select 的 `id`=window id
  - 渲染结果:`new-window\n` / `split-window -h -t %{id}\n`(before 加 ` -b`:`split-window -h -b -t %{id}\n`;`-v` 同理)/ `rename-window -t @{id} "{转义后}"\n` / `select-window -t @{id}\n`

- [ ] **Step 1: 写失败测试**(`src/termio/TmuxRouter.zig` 测试区,紧跟现有 `test "formatCommand renders each tag"`)

```zig
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
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY zig build test -Dtest-filter="formatCommand" --summary all`
Expected: 编译错误(`.new_window` 不存在)——这就是本任务的 RED。

- [ ] **Step 3: 实现**

`include/ghostty.h`(追加到 RESIZE 之后、struct 加字段):

```c
// apprt.action.TmuxCommand.Tag
typedef enum {
  GHOSTTY_TMUX_COMMAND_KILL_PANE,
  GHOSTTY_TMUX_COMMAND_KILL_WINDOW,
  GHOSTTY_TMUX_COMMAND_DETACH,
  GHOSTTY_TMUX_COMMAND_SELECT_PANE,
  GHOSTTY_TMUX_COMMAND_RESIZE,
  GHOSTTY_TMUX_COMMAND_NEW_WINDOW,
  GHOSTTY_TMUX_COMMAND_SPLIT_HORIZONTAL,
  GHOSTTY_TMUX_COMMAND_SPLIT_VERTICAL,
  GHOSTTY_TMUX_COMMAND_RENAME_WINDOW,
  GHOSTTY_TMUX_COMMAND_SELECT_WINDOW,
} ghostty_tmux_command_tag_e;

// apprt.action.TmuxCommand
typedef struct {
  ghostty_tmux_command_tag_e tag;
  uintptr_t id;
  uintptr_t width;
  uintptr_t height;
  const char* text;
} ghostty_tmux_command_s;
```

`src/apprt/action.zig` TmuxCommand:

```zig
pub const TmuxCommand = extern struct {
    tag: Tag,
    /// Pane id for kill_pane/select_pane/split_*; window id for
    /// kill_window/rename_window/select_window.
    id: usize = 0,
    /// Client grid size for resize. For split_* a non-zero width means
    /// insert before (-b).
    width: usize = 0,
    height: usize = 0,
    /// Window name for rename_window; null for everything else. Only
    /// borrowed for the duration of the call (formatted immediately).
    text: ?[*:0]const u8 = null,

    pub const Tag = enum(c_int) {
        kill_pane,
        kill_window,
        detach,
        select_pane,
        resize,
        new_window,
        split_horizontal,
        split_vertical,
        rename_window,
        select_window,

        // Sync with: ghostty_tmux_command_tag_e
        test "ghostty.h TmuxCommand.Tag" {
            try lib.checkGhosttyHEnum(Tag, "GHOSTTY_TMUX_COMMAND_");
        }
    };
};
```

`src/termio/TmuxRouter.zig` formatCommand 新 case(在现有 switch 里追加)+ 转义 helper:

```zig
    return switch (cmd.tag) {
        // ...现有 5 case 不动...
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
    };
```

```zig
/// Render rename-window with the name escaped for a tmux double-quoted
/// argument. Newlines/CR are stripped entirely (a newline terminates the
/// control-mode command — leaving one in would let a tab title inject a
/// second command); backslash and double-quote are backslash-escaped.
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
            '\\', '"' => {
                w.writeByte('\\') catch return error.NoSpaceLeft;
                w.writeByte(b) catch return error.NoSpaceLeft;
            },
            else => w.writeByte(b) catch return error.NoSpaceLeft,
        };
    }
    w.writeAll("\"\n") catch return error.NoSpaceLeft;
    return w.buffered();
}
```

注意:`std.Io.Writer.fixed` 的具体 API 以本仓库 Zig 版本为准——参照同文件/viewer.zig 里现有 writer 用法(如 `std.Io.Writer.Allocating` 的邻近模式),保持一致;若 fixed writer 不可用,退化为手动游标写 buf 也可,测试为准。

`src/apprt/embedded.zig` `ghostty_tmux_router_command`:`var buf: [128]u8` → `var buf: [512]u8`(rename 长名+转义余量)。

- [ ] **Step 4: 跑测试确认通过**

Run: `env -u ... zig build test -Dtest-filter="formatCommand" --summary all`(命令同 Step 2)
Expected: 全过(含既有 `formatCommand renders each tag`)。
再跑 ABI 看守:`env -u ... zig build test -Dtest-filter="ghostty.h TmuxCommand" --summary all` → 过。

- [ ] **Step 5: 全量基线 + 提交**

```bash
zig fmt src/termio/TmuxRouter.zig src/apprt/action.zig src/apprt/embedded.zig
env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY zig build test -Dtest-filter=tmux --summary all   # ≥214,只增
env -u ... zig build -Demit-macos-app=false    # 0 错
git add include/ghostty.h src/apprt/action.zig src/termio/TmuxRouter.zig src/apprt/embedded.zig
git commit -m "feat(termio/tmux): plan3 command tags (new/split/rename/select-window) with escaped rename"
git push backup tmux-cc-core && git push fork tmux-cc-core
```

---

### Task 2: R2 — Swift 类型化命令构造器 + 全调用点迁移

**Files:**
- Create: `macos/Sources/Features/Tmux/TmuxCommand.swift`
- Modify: `macos/Sources/Features/Tmux/TmuxSessionController.swift:185-200`(`send`/`sendResize`)
- Modify: `macos/Sources/Features/Tmux/TmuxTerminalController.swift`(所有 `ghostty_tmux_command_s(...)` 调用点:closeTab ~:99、closeWindow ~:118、closeSurface ~:163、syncFocusToSurfaceTree ~:230)
- Modify: `macos/Ghostty.xcodeproj/project.pbxproj`(iOS 排除清单加 `Features/Tmux/TmuxCommand.swift`)
- Test: `macos/Tests/Tmux/TmuxCommandTests.swift`

**Interfaces:**
- Consumes: Task 1 的 C tag/struct(含 `text` 字段)。
- Produces(后续任务全部经此发命令):

```swift
enum TmuxCommand: Equatable {
    case killPane(paneId: UInt)
    case killWindow(windowId: UInt)
    case detach
    case selectPane(paneId: UInt)
    case resize(cols: UInt, rows: UInt)
    case newWindow
    case split(paneId: UInt, direction: SplitTree<Ghostty.SurfaceView>.NewDirection)
    case renameWindow(windowId: UInt, name: String)
    case selectWindow(windowId: UInt)

    /// Bridge to the C struct. The body runs synchronously; text is only
    /// borrowed for that duration (the ABI entry formats immediately).
    func withCValue(_ body: (ghostty_tmux_command_s) -> Void)
}
// TmuxSessionController:
func send(_ cmd: TmuxCommand)   // 替换原 func send(_ cmd: ghostty_tmux_command_s)
```

- [ ] **Step 1: 写失败测试**

```swift
import AppKit
import Testing
@testable import Ghostty

@Suite struct TmuxCommandTests {
    private func cValue(_ cmd: TmuxCommand) -> ghostty_tmux_command_s {
        var out: ghostty_tmux_command_s!
        cmd.withCValue { out = $0 }
        return out
    }

    @Test func killWindowFields() {
        let c = cValue(.killWindow(windowId: 3))
        #expect(c.tag == GHOSTTY_TMUX_COMMAND_KILL_WINDOW)
        #expect(c.id == 3)
        #expect(c.text == nil)
    }

    @Test func splitDirectionMapping() {
        // 右→ -h;左→ -h -b(width=1);下→ -v;上→ -v -b
        let right = cValue(.split(paneId: 7, direction: .right))
        #expect(right.tag == GHOSTTY_TMUX_COMMAND_SPLIT_HORIZONTAL)
        #expect(right.id == 7 && right.width == 0)

        let left = cValue(.split(paneId: 7, direction: .left))
        #expect(left.tag == GHOSTTY_TMUX_COMMAND_SPLIT_HORIZONTAL)
        #expect(left.width == 1)

        let down = cValue(.split(paneId: 7, direction: .down))
        #expect(down.tag == GHOSTTY_TMUX_COMMAND_SPLIT_VERTICAL)
        #expect(down.width == 0)

        let up = cValue(.split(paneId: 7, direction: .up))
        #expect(up.tag == GHOSTTY_TMUX_COMMAND_SPLIT_VERTICAL)
        #expect(up.width == 1)
    }

    @Test func renameMarshalsText() {
        var seen: String?
        TmuxCommand.renameWindow(windowId: 2, name: "dev ✅").withCValue { c in
            #expect(c.tag == GHOSTTY_TMUX_COMMAND_RENAME_WINDOW)
            #expect(c.id == 2)
            seen = c.text.map { String(cString: $0) }
        }
        #expect(seen == "dev ✅")
    }

    @Test func resizeFields() {
        let c = cValue(.resize(cols: 120, rows: 40))
        #expect(c.tag == GHOSTTY_TMUX_COMMAND_RESIZE)
        #expect(c.width == 120 && c.height == 40)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `xcodebuild test -project macos/Ghostty.xcodeproj -scheme Ghostty -only-testing:GhosttyTests/TmuxCommandTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test case|error:"`
Expected: 编译失败(`TmuxCommand` 未定义)——RED。

- [ ] **Step 3: 实现 `TmuxCommand.swift`**

```swift
import AppKit
import GhosttyKit

/// Typed GUI→tmux commands. One conversion point to the C ABI struct so
/// call sites never hand-build ghostty_tmux_command_s (and the rename
/// string's lifetime is scoped here, not at every caller).
enum TmuxCommand: Equatable {
    case killPane(paneId: UInt)
    case killWindow(windowId: UInt)
    case detach
    case selectPane(paneId: UInt)
    case resize(cols: UInt, rows: UInt)
    case newWindow
    case split(paneId: UInt, direction: SplitTree<Ghostty.SurfaceView>.NewDirection)
    case renameWindow(windowId: UInt, name: String)
    case selectWindow(windowId: UInt)

    func withCValue(_ body: (ghostty_tmux_command_s) -> Void) {
        switch self {
        case .killPane(let id):
            body(.init(tag: GHOSTTY_TMUX_COMMAND_KILL_PANE, id: UInt(id), width: 0, height: 0, text: nil))
        case .killWindow(let id):
            body(.init(tag: GHOSTTY_TMUX_COMMAND_KILL_WINDOW, id: UInt(id), width: 0, height: 0, text: nil))
        case .detach:
            body(.init(tag: GHOSTTY_TMUX_COMMAND_DETACH, id: 0, width: 0, height: 0, text: nil))
        case .selectPane(let id):
            body(.init(tag: GHOSTTY_TMUX_COMMAND_SELECT_PANE, id: UInt(id), width: 0, height: 0, text: nil))
        case .resize(let cols, let rows):
            body(.init(tag: GHOSTTY_TMUX_COMMAND_RESIZE, id: 0, width: UInt(cols), height: UInt(rows), text: nil))
        case .newWindow:
            body(.init(tag: GHOSTTY_TMUX_COMMAND_NEW_WINDOW, id: 0, width: 0, height: 0, text: nil))
        case .split(let paneId, let direction):
            let tag: ghostty_tmux_command_tag_e
            let before: UInt
            switch direction {
            case .right: tag = GHOSTTY_TMUX_COMMAND_SPLIT_HORIZONTAL; before = 0
            case .left: tag = GHOSTTY_TMUX_COMMAND_SPLIT_HORIZONTAL; before = 1
            case .down: tag = GHOSTTY_TMUX_COMMAND_SPLIT_VERTICAL; before = 0
            case .up: tag = GHOSTTY_TMUX_COMMAND_SPLIT_VERTICAL; before = 1
            }
            body(.init(tag: tag, id: UInt(paneId), width: before, height: 0, text: nil))
        case .renameWindow(let id, let name):
            name.withCString { cstr in
                body(.init(tag: GHOSTTY_TMUX_COMMAND_RENAME_WINDOW, id: UInt(id), width: 0, height: 0, text: cstr))
            }
        case .selectWindow(let id):
            body(.init(tag: GHOSTTY_TMUX_COMMAND_SELECT_WINDOW, id: UInt(id), width: 0, height: 0, text: nil))
        }
    }
}
```

注意:`ghostty_tmux_command_s` 的 memberwise init 形参名/顺序以生成的 Swift 接口为准(uintptr_t → UInt);若字段名不同(如 `id:` 实为其它拼写)按编译器提示对齐。

- [ ] **Step 4: 迁移调用点**

`TmuxSessionController.swift`:

```swift
    func send(_ cmd: TmuxCommand) {
        guard let router, !isTearingDown else { return }
        cmd.withCValue { ghostty_tmux_router_command(router, $0) }
    }

    func sendResize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        send(.resize(cols: UInt(cols), rows: UInt(rows)))
    }
```

(保持原 send 里已有的 guard 语义——照原实现保留 router/teardown 检查,如原来没有就不加。)

`TmuxTerminalController.swift` 四处调用点机械替换,例:

```swift
// closeTab 确认回调里:
self.session?.send(.killWindow(windowId: UInt(self.tmuxWindowId)))
// closeWindow:
session.send(.detach)
// closeSurface 确认回调里:
self?.session?.send(.killPane(paneId: paneId))
// syncFocusToSurfaceTree 末尾:
session.send(.selectPane(paneId: paneId))
```

pbxproj:在 iOS 排除清单 `Features/Tmux/TmuxSplitLayout.swift,` 后插入 `Features/Tmux/TmuxCommand.swift,`(字母序)。

- [ ] **Step 5: 跑测试确认通过 + 全量 + 提交**

```bash
xcodebuild test ... -only-testing:GhosttyTests/TmuxCommandTests ...   # 全过
xcodebuild test ... -only-testing:GhosttyTests ...                     # 全绿
git add macos/Sources/Features/Tmux/TmuxCommand.swift macos/Sources/Features/Tmux/TmuxSessionController.swift macos/Sources/Features/Tmux/TmuxTerminalController.swift macos/Tests/Tmux/TmuxCommandTests.swift macos/Ghostty.xcodeproj/project.pbxproj
git commit -m "refactor(macos/tmux): typed TmuxCommand builder, migrate all send sites"
git push backup tmux-cc-core && git push fork tmux-cc-core
```

---

### Task 3: F1 — GUI 反向新建(⌘T→new-window,分屏→split-window)

**Files:**
- Modify: `macos/Sources/Features/Terminal/TerminalController.swift`(新增 `requestNewTab`;`newWindowForTab` ~:1166 改走它)
- Modify: `macos/Sources/App/macOS/AppDelegate.swift:727-739`(`ghosttyNewTab` 改走 controller 实例方法)
- Modify: `macos/Sources/Features/Tmux/TmuxTerminalController.swift`(override `requestNewTab` + `newSplit`)

**Interfaces:**
- Consumes: Task 2 `session.send(.newWindow)` / `.split(paneId:direction:)`;现有 `session.paneId(of:) -> UInt?`、`isTmuxManaged`。
- Produces: `TerminalController.requestNewTab(withBaseConfig: Ghostty.SurfaceConfiguration?)` — 实例方法,默认实现走既有 `TerminalController.newTab(_:from:withBaseConfig:)` 静态路径;tmux 子类接管。后续任务不依赖本任务的新接口。

- [ ] **Step 1: 实现 `requestNewTab` 缝(默认行为不变)**

`TerminalController.swift`(放在 `@IBAction func newTab` 附近):

```swift
    /// Create a new tab in this controller's window. Instance seam so
    /// subclasses can reroute tab creation (tmux: new-window command).
    /// Default: the existing local-tab static path.
    func requestNewTab(withBaseConfig config: Ghostty.SurfaceConfiguration? = nil) {
        guard let window else { return }
        _ = TerminalController.newTab(ghostty, from: window, withBaseConfig: config)
    }
```

`newWindowForTab`(标签条 "+" 按钮,~:1166):把方法体里对 `TerminalController.newTab(...)` 静态调用替换为 `requestNewTab(withBaseConfig: nil)`(保留原有前置 guard 不动)。

`AppDelegate.ghosttyNewTab`(:727):把

```swift
        guard window.windowController is TerminalController else { return }
        ...
        _ = TerminalController.newTab(ghostty, from: window, withBaseConfig: config)
```

改为:

```swift
        guard let controller = window.windowController as? TerminalController else { return }
        let configAny = notification.userInfo?[Ghostty.Notification.NewSurfaceConfigKey]
        let config = configAny as? Ghostty.SurfaceConfiguration
        controller.requestNewTab(withBaseConfig: config)
```

- [ ] **Step 2: 跑全量 Swift 测试(重构无行为变化)**

Run: `xcodebuild test ... -only-testing:GhosttyTests ...`
Expected: 全绿(此步是重构安全网;⌘T 行为唯一变化在下一步的 tmux override)。

- [ ] **Step 3: tmux 侧接管**

`TmuxTerminalController.swift`:

```swift
    // MARK: - Reverse create (plan 3)

    /// ⌘T / File>New Tab / tab-bar "+" on a tmux tab creates a real tmux
    /// window. The new native tab materializes from the window-add /
    /// layout-change resync; focus follows via reverse focus (%session-
    /// window-changed). No local tab is ever created for a live session.
    override func requestNewTab(withBaseConfig config: Ghostty.SurfaceConfiguration? = nil) {
        guard isTmuxManaged, let session else {
            super.requestNewTab(withBaseConfig: config)
            return
        }
        session.send(.newWindow)
    }

    /// Split gestures on a tmux pane become split-window commands; the
    /// new pane materializes from the layout-change resync. Returns nil:
    /// no local SurfaceView is created.
    override func newSplit(
        at oldView: Ghostty.SurfaceView,
        direction: SplitTree<Ghostty.SurfaceView>.NewDirection,
        baseConfig config: Ghostty.SurfaceConfiguration? = nil
    ) -> Ghostty.SurfaceView? {
        guard isTmuxManaged, let session else {
            return super.newSplit(at: oldView, direction: direction, baseConfig: config)
        }
        guard let paneId = session.paneId(of: oldView) else { return nil }
        session.send(.split(paneId: paneId, direction: direction))
        return nil
    }
```

注意:`newSplit` 在 Base 里是 `@discardableResult`;override 保持签名一致(含默认参不可重复,Swift override 不写默认值,以编译器提示为准——默认参数在 override 中省略,调用端不受影响)。

- [ ] **Step 4: 构建 + 全量测试**

```bash
xcodebuild -project macos/Ghostty.xcodeproj -target Ghostty -configuration Debug CODE_SIGNING_ALLOWED=NO build   # BUILD SUCCEEDED
xcodebuild test ... -only-testing:GhosttyTests ...   # 全绿
```

(⌘T/分屏是 GUI 手势,AX 注入不可用 → 交互验证归 Task 9 冒烟;本任务的可自动验证面 = 编译 + 既有测试不回归。)

- [ ] **Step 5: 提交**

```bash
git add macos/Sources/Features/Terminal/TerminalController.swift macos/Sources/App/macOS/AppDelegate.swift macos/Sources/Features/Tmux/TmuxTerminalController.swift
git commit -m "feat(macos/tmux): cmd-T and split gestures create real tmux windows/panes"
git push backup tmux-cc-core && git push fork tmux-cc-core
```

---

### Task 4: F2(Zig 半)— %session-window-changed 解析 + focus action

**Files:**
- Modify: `src/terminal/tmux/control.zig`(通知解析 ~:516 区域新增分支;Notification 联合 ~:725 新增变体;文件尾测试区新增 2 测)
- Modify: `src/terminal/tmux/viewer.zig`(Action 联合新增 `focus`;通知 switch ~:575 接线;测试区新增)

**Interfaces:**
- Consumes: 现有通知解析基建(oni.Regex 模式,照 `%window-pane-changed` :517-551 镜像)。
- Produces:
  - `control.zig` Notification 联合新增:`session_window_changed: struct { session_id: usize, window_id: usize }`(格式 `%session-window-changed $1 @2`)
  - `viewer.zig` Action 联合新增:`focus: struct { window_id: usize, pane_id: ?usize }`
  - 语义:`window_pane_changed` → `focus{window_id, pane_id}`;`session_window_changed` → `focus{window_id, null}`(session id 丢弃——单会话 viewer)

- [ ] **Step 1: 写失败测试**

`control.zig` 测试区(仿 :1045 的 window_pane_changed 测试):

```zig
test "notification session-window-changed" {
    var p: Parser = .init(std.testing.allocator);
    defer p.deinit();
    const n = try feedLine(&p, "%session-window-changed $0 @7");
    try testing.expect(n == .session_window_changed);
    try testing.expectEqual(0, n.session_window_changed.session_id);
    try testing.expectEqual(7, n.session_window_changed.window_id);
}

test "notification session-window-changed malformed ignored" {
    var p: Parser = .init(std.testing.allocator);
    defer p.deinit();
    try testing.expectEqual(null, try feedLineNull(&p, "%session-window-changed garbage"));
}
```

(具体喂行 helper 以该文件既有测试写法为准——照 :996/:1045 两个测试的实际结构镜像,不要发明新 helper。)

`viewer.zig` 测试区(仿既有 testViewer 流程,attach 就绪后注入通知断言 focus action):

```zig
test "focus actions from pane and window change notifications" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{ .id = 0, .name = "0" } } },
            .contains_command = "display-message",
        },
        .{ .input = .{ .tmux = .{ .block_end = "3.5a" } }, .contains_command = "list-windows" },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0 @0 165 79 ca97,165x79,0,0[165x40,0,0,0,165x38,0,41,4] bash
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // pane 焦点变化 → focus{window, pane}
        .{
            .input = .{ .tmux = .{ .window_pane_changed = .{ .window_id = 0, .pane_id = 4 } } },
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    for (actions) |a| switch (a) {
                        .focus => |f| {
                            try testing.expectEqual(0, f.window_id);
                            try testing.expectEqual(4, f.pane_id.?);
                            return;
                        },
                        else => {},
                    };
                    return error.TestExpectedFocus;
                }
            }).check,
        },
        // 当前 window 变化 → focus{window, null}
        .{
            .input = .{ .tmux = .{ .session_window_changed = .{ .session_id = 0, .window_id = 0 } } },
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    for (actions) |a| switch (a) {
                        .focus => |f| {
                            try testing.expectEqual(0, f.window_id);
                            try testing.expectEqual(null, f.pane_id);
                            return;
                        },
                        else => {},
                    };
                    return error.TestExpectedFocus;
                }
            }).check,
        },
        .{ .input = .{ .tmux = .exit }, .contains_tags = &.{.exit} },
    });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `env -u ... zig build test -Dtest-filter="session-window-changed" --summary all` 与 `-Dtest-filter="focus actions"`
Expected: 编译错误(变体不存在)——RED。

- [ ] **Step 3: 实现**

`control.zig`:在 `%window-pane-changed` 分支后镜像新增(regex `^%session-window-changed \\$([0-9]+) @([0-9]+)$`,两组数字捕获,解析结构同型);Notification 联合在 `window_pane_changed` 后新增:

```zig
    /// The session's current window changed to window-id.
    session_window_changed: struct {
        session_id: usize,
        window_id: usize,
    },
```

`viewer.zig`:Action 联合新增(放 `pane_gone` 前):

```zig
        /// tmux-side focus change: make this window (and pane, when
        /// non-null) the active one in the GUI. From
        /// %window-pane-changed / %session-window-changed.
        focus: struct {
            window_id: usize,
            pane_id: ?usize,
        },
```

通知 switch(:575 区域):

```zig
            // The active pane changed: forward to the GUI as a focus
            // action so native focus follows tmux.
            .window_pane_changed => |info| try actions.append(arena_alloc, .{
                .focus = .{ .window_id = info.window_id, .pane_id = info.pane_id },
            }),

            // The session's current window changed: forward window-level
            // focus (no pane info in this notification).
            .session_window_changed => |info| try actions.append(arena_alloc, .{
                .focus = .{ .window_id = info.window_id, .pane_id = null },
            }),
```

注意:该 switch 所在函数的 actions 收集方式以现有代码为准(`.window_renamed` 分支就在旁边,是现成模板——它怎么 append action、用哪个 allocator,照抄)。`Action.format` 若对新变体需要分支,补一行(有 `pane_output` 模板)。

- [ ] **Step 4: 跑测试确认通过**

Run: 同 Step 2 两条 + `env -u ... zig build test -Dtest-filter=tmux --summary all`
Expected: 新测过,全量 ≥216(214+2 控制 +1 viewer;以实际计数为准,只增)。

- [ ] **Step 5: 提交**

```bash
zig fmt src/terminal/tmux/control.zig src/terminal/tmux/viewer.zig
git add src/terminal/tmux/control.zig src/terminal/tmux/viewer.zig
git commit -m "feat(terminal/tmux): parse %session-window-changed, emit focus actions"
git push backup tmux-cc-core && git push fork tmux-cc-core
```

---

### Task 5: F2(管道 + Swift 半)— focus 事件到原生焦点 + 抑制回环 + select-window

**Files:**
- Modify: `src/apprt/surface.zig`(TmuxEvent.Event 新增 `focus`;新增 `initFocus`)
- Modify: `src/termio/stream_handler.zig`(handleTmuxActions 新增 `.focus` case ~:640)
- Modify: `src/Surface.zig:1193-1210`(`.tmux` 事件 switch 新增 focus → performAction)
- Modify: `src/apprt/action.zig`(Tmux union + CValue 新增 focus)
- Modify: `include/ghostty.h`(`ghostty_action_tmux_tag_e` 追加 `GHOSTTY_TMUX_FOCUS`;新增 `ghostty_action_tmux_focus_s`;union 加成员)
- Modify: `macos/Sources/Ghostty/Ghostty.Tmux.swift`(TmuxEvent 枚举加 case)
- Modify: `macos/Sources/Ghostty/Ghostty.App.swift:2264-2280`(解码分发加 case)
- Modify: `macos/Sources/Features/Tmux/TmuxSessionManager.swift`(路由加 case)
- Modify: `macos/Sources/Features/Tmux/TmuxSessionController.swift`(`applyFocus` + `pendingFocusWindowId` + `isApplyingTmuxFocus`)
- Modify: `macos/Sources/Features/Tmux/TmuxTerminalController.swift`(syncFocusToSurfaceTree:抑制检查 + 补发 select-window)

**Interfaces:**
- Consumes: Task 4 的 viewer `focus` action;Task 2 的 `.selectWindow(windowId:)`。
- Produces:
  - C:`GHOSTTY_TMUX_FOCUS`(追加在 `GHOSTTY_TMUX_EXIT` 之后);`typedef struct { uintptr_t window_id; uintptr_t pane_id; bool has_pane; } ghostty_action_tmux_focus_s;`;union 加 `ghostty_action_tmux_focus_s focus;`
  - Zig apprt:`Tmux` union 加 `focus: Focus`,`pub const Focus = extern struct { window_id: usize, pane_id: usize, has_pane: bool }`(cval 同步)
  - Swift:`Ghostty.TmuxEvent` 加 `case focus(windowId: UInt, paneId: UInt?)`
  - `TmuxSessionController.applyFocus(windowId: UInt, paneId: UInt?)`;`private(set) var isApplyingTmuxFocus: Bool`

- [ ] **Step 1: Zig 管道实现(此段无独立单测,靠 tmux filter 全量回归 + 编译看守)**

`src/apprt/surface.zig` TmuxEvent:

```zig
    pub const Event = union(enum) {
        attach: struct { router: *anyopaque },
        windows: struct { windows: []const Window, nodes: []const Node },
        focus: struct { window_id: usize, pane_id: ?usize },
        exit,
    };

    pub fn initFocus(
        gpa: Allocator,
        window_id: usize,
        pane_id: ?usize,
    ) Allocator.Error!*TmuxEvent {
        var arena: ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const ev = try arena.allocator().create(TmuxEvent);
        ev.* = .{
            .alloc = gpa,
            .arena_state = arena.state,
            .event = .{ .focus = .{ .window_id = window_id, .pane_id = pane_id } },
        };
        return ev;
    }
```

`stream_handler.zig` handleTmuxActions(`.pane_gone` 前):

```zig
                .focus => |f| {
                    const ev = apprt.surface.TmuxEvent.initFocus(
                        self.alloc,
                        f.window_id,
                        f.pane_id,
                    ) catch |err| {
                        log.warn("tmux focus event dropped err={}", .{err});
                        continue;
                    };
                    self.surfaceMessageWriter(.{ .tmux = ev });
                },
```

`src/Surface.zig` `.tmux` switch(仿 .attach 分支):

```zig
                .focus => |f| _ = try self.rt_app.performAction(
                    .{ .surface = self },
                    .tmux,
                    .{ .focus = .{
                        .window_id = f.window_id,
                        .pane_id = f.pane_id orelse 0,
                        .has_pane = f.pane_id != null,
                    } },
                ),
```

`src/apprt/action.zig` Tmux union(`windows` 后):

```zig
    focus: Focus,

    // Sync with: ghostty_action_tmux_focus_s
    pub const Focus = extern struct {
        window_id: usize,
        pane_id: usize,
        has_pane: bool,
    },
```

(cval/CValue 生成逻辑照 `attach`/`windows` 的既有模式补;若有 `comptime` 映射表需登记,以编译错误为向导。)

`include/ghostty.h`:

```c
typedef enum {
  GHOSTTY_TMUX_ATTACH,
  GHOSTTY_TMUX_WINDOWS,
  GHOSTTY_TMUX_EXIT,
  GHOSTTY_TMUX_FOCUS,
} ghostty_action_tmux_tag_e;

// apprt.action.Tmux.Focus
typedef struct {
  uintptr_t window_id;
  uintptr_t pane_id;
  bool has_pane;
} ghostty_action_tmux_focus_s;

// union 追加成员:
  ghostty_action_tmux_focus_s focus;
```

(注:`GHOSTTY_TMUX_FOCUS` 追加在尾部,与 Zig union 字段顺序的对应关系以 `checkGhosttyHEnum`/编译看守为准——若 Zig 侧 union 顺序必须与 C 枚举一致,则 Zig `focus` 放 `exit` 之后。)

Run: `env -u ... zig build test -Dtest-filter=tmux --summary all` + `env -u ... zig build -Demit-macos-app=false`
Expected: 全过、0 错。

- [ ] **Step 2: Swift 解码与路由**

`Ghostty.Tmux.swift`:`enum TmuxEvent` 加 `case focus(windowId: UInt, paneId: UInt?)`。
`Ghostty.App.swift` tmux 分发 switch 加:

```swift
            case GHOSTTY_TMUX_FOCUS:
                let f = v.value.focus
                event = .focus(
                    windowId: UInt(f.window_id),
                    paneId: f.has_pane ? UInt(f.pane_id) : nil)
```

`TmuxSessionManager.onTmuxEvent` 加:

```swift
        case .focus(let windowId, let paneId):
            sessions[key]?.applyFocus(windowId: windowId, paneId: paneId)
```

- [ ] **Step 3: TmuxSessionController.applyFocus + pending + 抑制**

```swift
    /// True while we are applying a tmux-driven focus change to native
    /// windows. TmuxTerminalController checks this to avoid echoing the
    /// focus back as select-window/select-pane (loop suppression).
    private(set) var isApplyingTmuxFocus = false

    /// Focus notification that arrived before its window materialized
    /// (e.g. %session-window-changed racing the window-add resync).
    private var pendingFocusWindowId: UInt?

    /// Apply a tmux-side focus change (from %window-pane-changed /
    /// %session-window-changed) to the native UI.
    func applyFocus(windowId: UInt, paneId: UInt?) {
        guard !isTearingDown else { return }
        guard let controller = windows[windowId], let window = controller.window else {
            pendingFocusWindowId = windowId
            return
        }
        pendingFocusWindowId = nil

        isApplyingTmuxFocus = true
        defer { isApplyingTmuxFocus = false }

        // Select the native tab without stealing key from another app.
        if let tabGroup = window.tabGroup, tabGroup.selectedWindow !== window {
            tabGroup.selectedWindow = window
        }

        // Focus the pane's surface when we know it.
        if let paneId, let view = panes[paneId], controller.surfaceTree.contains(view) {
            Ghostty.moveFocus(to: view)
        }
    }
```

`apply(_ ev:)` 末尾(prunePanes 之后)补:

```swift
        // A focus notification may have raced the resync that materialized
        // its window; apply it now that the window exists.
        if let pending = pendingFocusWindowId, windows[pending] != nil {
            applyFocus(windowId: pending, paneId: nil)
        }
```

(`Ghostty.moveFocus(to:)` 的可用性/签名以 `BaseTerminalController.focusSurface` :278 的用法为准——那里就是 `Ghostty.moveFocus(to: view)`。)

- [ ] **Step 4: TmuxTerminalController — 抑制 + 补发 select-window**

`syncFocusToSurfaceTree` override 改为:

```swift
    override func syncFocusToSurfaceTree() {
        super.syncFocusToSurfaceTree()

        guard window?.isKeyWindow == true else { return }
        guard !forceClosing,
              let session, !session.isTearingDown,
              // tmux-driven focus application must not echo back.
              !session.isApplyingTmuxFocus,
              let view = focusedSurface,
              let paneId = session.paneId(of: view)
        else { return }

        // select-pane alone does not switch tmux's current window;
        // send select-window first so tmux-side focus fully follows.
        session.send(.selectWindow(windowId: UInt(tmuxWindowId)))
        session.send(.selectPane(paneId: paneId))
    }
```

(原函数尾部若还有其它逻辑,保留;仅按上述插入抑制 guard 与 selectWindow。)

- [ ] **Step 5: 全量测试 + 提交**

```bash
env -u ... zig build test -Dtest-filter=tmux --summary all    # 全过
xcodebuild test ... -only-testing:GhosttyTests ...            # 全绿
xcodebuild -project macos/Ghostty.xcodeproj -target Ghostty -configuration Debug CODE_SIGNING_ALLOWED=NO build
git add include/ghostty.h src/apprt/surface.zig src/apprt/action.zig src/termio/stream_handler.zig src/Surface.zig macos/Sources/Ghostty/Ghostty.Tmux.swift macos/Sources/Ghostty/Ghostty.App.swift macos/Sources/Features/Tmux/TmuxSessionManager.swift macos/Sources/Features/Tmux/TmuxSessionController.swift macos/Sources/Features/Tmux/TmuxTerminalController.swift
git commit -m "feat(tmux): reverse focus — tmux window/pane changes drive native focus with echo suppression"
git push backup tmux-cc-core && git push fork tmux-cc-core
```

---

### Task 6: R3+F4 — TmuxKeyEncode 三级编码(send-keys 吞吐)

**Files:**
- Create: `src/termio/TmuxKeyEncode.zig`
- Modify: `src/termio/TmuxPane.zig:80-108`(queueWrite 改调编码器;删旧 hex 循环)
- Modify: `src/termio/TmuxPane.zig` 测试(:156 起,更新期望)
- Modify: `src/termio.zig` 或相邻导出点(若 termio 模块有显式导出表,登记新文件;以 `TmuxPane` 的导出方式为准)

**Interfaces:**
- Consumes: `router.sendCommand([]const u8)`(经 TmuxPane 现有引用)。
- Produces:

```zig
/// 把 pane 输入字节流编码为一串 send-keys 命令,逐条回调 emit。
/// 可打印安全 ASCII 走 literal(-l,双引号包裹,块上限 256B),
/// 其余字节(C0、非 ASCII、黑名单字符)走 hex(-H,块上限 64B)。
/// 顺序保持:输出命令序 = 输入字节序。
pub fn encode(
    alloc: std.mem.Allocator,
    pane_id: usize,
    data: []const u8,
    ctx: anytype,
    emit: fn (@TypeOf(ctx), []const u8) anyerror!void,
) !void
```

- 安全字节判定:`0x20-0x7E` 且**不在**黑名单 `\ " ; $ # ' { } ~ %` 内(`%` 保守排除:tmux format 场景;`~` 防 home 展开歧义)。空格**允许**(双引号包裹)。literal 命令形态:`send-keys -t %{d} -l -- "{run}"\n`。
- hex 命令形态与现状一致:`send-keys -t %{d} -H {xx} {xx}...\n`。

- [ ] **Step 1: 写失败测试**(`TmuxKeyEncode.zig` 文件内)

```zig
const std = @import("std");
const testing = std.testing;

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
```

- [ ] **Step 2: 跑测试确认失败**

Run: `env -u ... zig build test -Dtest-filter="TmuxKeyEncode" --summary all`(若 filter 不含新文件,用 `-Dtest-filter="literal command"` 等测试名;新文件需在构建图里——先在 TmuxPane.zig 顶部加 `const TmuxKeyEncode = @import("TmuxKeyEncode.zig");` 引用以纳入编译)
Expected: 编译错误(encode 未实现)——RED。

- [ ] **Step 3: 实现 encode**

```zig
//! Encode pane input bytes into tmux send-keys commands.
//! Printable-safe ASCII runs use the literal form (-l) for ~1:1 byte
//! cost; everything else (C0 controls, non-ASCII, characters that are
//! risky inside a tmux double-quoted argument) uses the hex form (-H).
//! tmux ≥3.2 gate means no version branches.
const std = @import("std");

const LITERAL_CHUNK = 256;
const HEX_CHUNK = 64;

fn isLiteralSafe(b: u8) bool {
    if (b < 0x20 or b > 0x7e) return false;
    return switch (b) {
        '\\', '"', ';', '$', '#', '\'', '{', '}', '~', '%' => false,
        else => true,
    };
}

pub fn encode(
    alloc: std.mem.Allocator,
    pane_id: usize,
    data: []const u8,
    ctx: anytype,
    comptime emit: fn (@TypeOf(ctx), []const u8) anyerror!void,
) !void {
    var i: usize = 0;
    while (i < data.len) {
        const safe = isLiteralSafe(data[i]);
        // 找同类 run 的边界
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
```

(writer API 以 TmuxPane.zig:100-106 现用的 `std.Io.Writer.Allocating` 为准,照抄用法。)

- [ ] **Step 4: 跑测试确认通过**

Run: 同 Step 2。Expected: 全过。

- [ ] **Step 5: 接线 TmuxPane.queueWrite + 更新其测试**

`queueWrite` 主体替换为:

```zig
pub fn queueWrite(
    self: *TmuxPane,
    alloc: Allocator,
    td: *termio.Termio.ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    _ = td;
    _ = linefeed;
    try TmuxKeyEncode.encode(alloc, self.pane_id, data, self, emitCommand);
}

fn emitCommand(self: *TmuxPane, cmd: []const u8) anyerror!void {
    try self.router.sendCommand(cmd);
}
```

原 `test "queueWrite encodes send-keys hex chunks"`(:156)期望更新:输入 `"hi\r"` 现在产出 literal+hex 两条(`send-keys -t %5 -l -- "hi"\n` 和 `send-keys -t %5 -H 0d\n`)——按新编码语义改断言,测试名改为 `"queueWrite routes through TmuxKeyEncode"`。

Run: `env -u ... zig build test -Dtest-filter=tmux --summary all` → 全过(计数只增:+7 编码器测试)。

- [ ] **Step 6: 提交**

```bash
zig fmt src/termio/TmuxKeyEncode.zig src/termio/TmuxPane.zig
git add src/termio/TmuxKeyEncode.zig src/termio/TmuxPane.zig
git commit -m "perf(termio/tmux): literal fast path for send-keys (three-tier encoding)"
git push backup tmux-cc-core && git push fork tmux-cc-core
```

---

### Task 7: F3 — rename 双向

**Files:**
- Modify: `macos/Sources/Features/Terminal/TerminalController.swift`(新增 `userDidSetTitleOverride` 缝)
- Modify: `macos/Sources/Features/Terminal/Window Styles/TerminalWindow.swift:822-828`(TabTitleEditor 提交点改走缝)
- Modify: `macos/Sources/Features/Terminal/BaseTerminalController.swift:388-395` 附近(promptTabTitle 完成回调改走缝——**注意**:promptTabTitle 在 Base 上,缝在 TerminalController 上;若回调处类型是 Base,做 `(self as? TerminalController)?.userDidSetTitleOverride(...) ?? { titleOverride = ... }()` 式分流,或把缝上提到 Base——以最小 diff 为准,缝放 Base 亦可,默认实现 `titleOverride = title`)
- Modify: `macos/Sources/Features/Tmux/TmuxTerminalController.swift`(override 缝 → rename-window)

**Interfaces:**
- Consumes: Task 2 `.renameWindow(windowId:name:)`;现有 `titleOverride`、`tmuxUpdate` 回流(`%window-renamed` → titleOverride,不动)。
- Produces: `BaseTerminalController.userDidSetTitleOverride(_ title: String?)` — 用户改名的唯一提交缝;默认 `titleOverride = title`。

- [ ] **Step 1: 实现缝(默认行为不变)**

`BaseTerminalController.swift`(promptTabTitle 附近):

```swift
    /// User-initiated tab rename commit point. Subclasses can reroute
    /// (tmux: rename-window command; the title then updates from the
    /// %window-renamed echo, keeping tmux authoritative).
    func userDidSetTitleOverride(_ title: String?) {
        titleOverride = title
    }
```

promptTabTitle 完成回调里的 `titleOverride = ...` 赋值行替换为 `userDidSetTitleOverride(...)`(保持空串→nil 的既有归一化逻辑)。

`TerminalWindow.swift` `didCommitTitle`(:826-827):

```swift
        guard let targetController = targetWindow.windowController as? BaseTerminalController else { return }
        targetController.userDidSetTitleOverride(editedTitle.isEmpty ? nil : editedTitle)
```

- [ ] **Step 2: tmux override**

`TmuxTerminalController.swift`:

```swift
    /// GUI rename on a tmux tab becomes rename-window; the native title
    /// updates when tmux echoes %window-renamed (no optimistic local set).
    override func userDidSetTitleOverride(_ title: String?) {
        guard isTmuxManaged, let session else {
            super.userDidSetTitleOverride(title)
            return
        }
        session.send(.renameWindow(windowId: UInt(tmuxWindowId), name: title ?? ""))
    }
```

(`tmuxUpdate` 里的 `titleOverride = w.name` 直赋不走缝——回流路径,无回环。)

- [ ] **Step 3: 全量 Swift 测试 + 构建**

Run: `xcodebuild test ... -only-testing:GhosttyTests ...` + Debug build
Expected: 全绿、BUILD SUCCEEDED。(改名对话框是 GUI 交互,自动断言归 Task 9 冒烟。)

- [ ] **Step 4: 提交**

```bash
git add macos/Sources/Features/Terminal/BaseTerminalController.swift "macos/Sources/Features/Terminal/Window Styles/TerminalWindow.swift" macos/Sources/Features/Terminal/TerminalController.swift macos/Sources/Features/Tmux/TmuxTerminalController.swift
git commit -m "feat(macos/tmux): GUI tab rename maps to rename-window"
git push backup tmux-cc-core && git push fork tmux-cc-core
```

(若最终缝放在 Base、TerminalController 无改动,提交清单相应缩减。)

---

### Task 8: R1+F5 — 批量关闭映射(TmuxTabGuard 退役)

**Files:**
- Create: `macos/Sources/Features/Tmux/TmuxBatchClose.swift`
- Delete: `macos/Sources/Features/Tmux/TmuxTabGuard.swift`、`macos/Tests/Tmux/TmuxTabGuardTests.swift`
- Modify: `macos/Sources/Features/Terminal/TerminalController.swift`(closeTabsOnTheRight/closeOtherTabs 的 @IBAction ~:1297/:1329、`*Immediately` ~:717/:766、validateMenuItem ~:1627——移除 TmuxTabGuard 检查恢复上游逻辑,批量入口改走 TmuxBatchClose)
- Modify: `macos/Sources/Features/Tmux/TmuxTerminalController.swift`(validateMenuItem 移除对 closeOtherTabs/closeTabsOnTheRight 的禁用;新增 disposition override;isTmuxManaged 保留)
- Modify: `macos/Ghostty.xcodeproj/project.pbxproj`(排除清单:去 TmuxTabGuard.swift,加 TmuxBatchClose.swift)
- Test: `macos/Tests/Tmux/TmuxBatchCloseTests.swift`

**Interfaces:**
- Consumes: Task 2 `.killWindow(windowId:)`;现有 `closeTabImmediately(registerRedo:)`、`tmuxForceClose` 回流路径。
- Produces:

```swift
/// 每个 controller 申报自己在批量关闭里的处置方式。
enum BatchCloseDisposition {
    case local                                              // 本地关,可撤销
    case tmuxKill(session: TmuxSessionController, windowId: UInt)  // kill-window,不可逆
}
// TerminalController:
var batchCloseDisposition: BatchCloseDisposition { .local }   // TmuxTerminalController override

enum TmuxBatchClose {
    /// 纯逻辑:把候选划分为本地关闭组与按 session 分组的 kill 清单。
    static func partition(_ candidates: [TerminalController])
        -> (local: [TerminalController], kills: [(session: TmuxSessionController, windowIds: [UInt])])
    /// 入口:无 tmux 候选→返回 false(调用方走既有本地路径);
    /// 有→弹一个确认框,确认后发命令+关本地,返回 true。
    static func run(_ candidates: [TerminalController], presenting window: NSWindow?) -> Bool
}
```

- [ ] **Step 1: 写失败测试**

```swift
import AppKit
import Testing
@testable import Ghostty

@MainActor
@Suite struct TmuxBatchCloseTests {
    /// 桩:覆写 disposition,不需要真 session 的场景用 .local。
    private final class StubLocal: TerminalController { /* 构造照 TmuxTabGuardTests 旧法或直接用
        TerminalController 不可行时,用协议化:见 Step 3 说明 */ }

    @Test func allLocalReturnsAllInLocalBucket() {
        // partition 输入 2 个 .local 申报者 → local.count == 2, kills.isEmpty
    }

    @Test func killsGroupBySession() {
        // 同一 session 的两个 windowId + 另一 session 的一个 →
        // kills.count == 2,组内 windowIds 完整
    }

    @Test func mixedPartition() {
        // 1 local + 2 tmux → local.count == 1, kills 覆盖 2 个 id
    }
}
```

**实现注记(供 Step 3)**:`TerminalController` 直接实例化在单测里不可行(NIB 依赖)时,把 `partition` 的输入抽象为 `[(BatchCloseDisposition)]` 或接受 `[any BatchCloseParticipant]` 协议(`var batchCloseDisposition: BatchCloseDisposition { get }`),测试用轻量桩实现协议——**partition 必须是不碰 AppKit 的纯函数**,这是本任务的可测边界。TerminalController 遵循该协议。

- [ ] **Step 2: 跑测试确认失败**

Run: `xcodebuild test ... -only-testing:GhosttyTests/TmuxBatchCloseTests ...`
Expected: 编译失败(类型未定义)——RED。

- [ ] **Step 3: 实现 TmuxBatchClose.swift**

```swift
import AppKit

/// 批量关闭(关闭右侧/其他标签)的 tmux 感知执行器。
/// 划分候选 → 一个汇总确认框 → tmux 侧发 kill-window(GUI 移除等回流,
/// 走与单个 kill 相同的 tmuxForceClose 路径),本地侧走既有可撤销关闭。
protocol BatchCloseParticipant: AnyObject {
    var batchCloseDisposition: BatchCloseDisposition { get }
}

enum BatchCloseDisposition {
    case local
    case tmuxKill(session: TmuxSessionController, windowId: UInt)
}

enum TmuxBatchClose {
    static func partition(_ candidates: [any BatchCloseParticipant])
        -> (local: [any BatchCloseParticipant],
            kills: [(session: TmuxSessionController, windowIds: [UInt])])
    {
        var local: [any BatchCloseParticipant] = []
        var killMap: [ObjectIdentifier: (session: TmuxSessionController, windowIds: [UInt])] = [:]
        var order: [ObjectIdentifier] = []
        for c in candidates {
            switch c.batchCloseDisposition {
            case .local:
                local.append(c)
            case .tmuxKill(let session, let windowId):
                let key = ObjectIdentifier(session)
                if killMap[key] == nil {
                    killMap[key] = (session, [])
                    order.append(key)
                }
                killMap[key]!.windowIds.append(windowId)
            }
        }
        return (local, order.map { killMap[$0]! })
    }

    /// Returns false when no tmux tabs are involved (caller keeps its
    /// existing local path, including undo registration).
    static func run(
        _ candidates: [TerminalController],
        presenting window: NSWindow?
    ) -> Bool {
        let (local, kills) = partition(candidates)
        let killCount = kills.reduce(0) { $0 + $1.windowIds.count }
        guard killCount > 0 else { return false }

        let alert = NSAlert()
        alert.messageText = "Close Tabs?"
        alert.informativeText = local.isEmpty
            ? "This will kill \(killCount) tmux window(s) and any processes running in them. This cannot be undone."
            : "This will kill \(killCount) tmux window(s) (cannot be undone) and close \(local.count) local tab(s)."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")

        let execute = {
            for group in kills {
                for id in group.windowIds {
                    group.session.send(.killWindow(windowId: id))
                }
            }
            for c in local {
                (c as? TerminalController)?.closeTabImmediately(registerRedo: false)
            }
        }

        if let window {
            alert.beginSheetModal(for: window) { response in
                guard response == .alertFirstButtonReturn else { return }
                execute()
            }
        } else {
            if alert.runModal() == .alertFirstButtonReturn { execute() }
        }
        return true
    }
}
```

`TerminalController`:

```swift
extension TerminalController: BatchCloseParticipant {
    @objc var batchCloseDisposition: BatchCloseDisposition { .local }
}
```

(`@objc` 若类型不兼容则去掉,用普通计算属性 + TmuxTerminalController override。)

`TmuxTerminalController`:

```swift
    override var batchCloseDisposition: BatchCloseDisposition {
        guard isTmuxManaged, let session else { return .local }
        return .tmuxKill(session: session, windowId: UInt(tmuxWindowId))
    }
```

- [ ] **Step 4: 接线 TerminalController 批量入口 + 移除旧守卫**

`closeTabsOnTheRight` @IBAction(:1329 区域):在收集出右侧候选后、弹既有确认框前插入:

```swift
        let candidates = tabGroup.windows.enumerated()
            .filter { $0.offset > currentIndex }
            .compactMap { $0.element.windowController as? TerminalController }
        if TmuxBatchClose.run(candidates, presenting: window) { return }
        // ……既有纯本地确认+关闭路径不动……
```

`closeOtherTabs` @IBAction 同型(候选=除自身外全部)。
`closeTabsOnTheRightImmediately` / `closeOtherTabsImmediately`:把 Task(昨天)加的 `guard !TmuxTabGuard.blocksBatchClose(...)` 替换为同样的 `if TmuxBatchClose.run(candidates, presenting: window) { return }`(键盘 keybinding 直达路径的翻译)。
`validateMenuItem`(:1627):删 `TmuxTabGuard` 两处 guard,恢复上游原始逻辑。
`TmuxTerminalController.validateMenuItem`:删 `closeOtherTabs/closeTabsOnTheRight → false` 分支(现在这两项在 tmux 标签上也走翻译)。
删除 `TmuxTabGuard.swift` + `TmuxTabGuardTests.swift`;`NSWindow.isTmuxManaged` 扩展若仅守卫使用则一并删,若 `TmuxManagedWindow` 协议还有其它引用(isTmuxManaged 属性 TmuxTerminalController 自身仍用)则保留协议、删扩展——以编译为准。
pbxproj:排除清单 `TmuxTabGuard.swift` → `TmuxBatchClose.swift`。

- [ ] **Step 5: 跑测试确认通过 + 全量 + 提交**

```bash
xcodebuild test ... -only-testing:GhosttyTests/TmuxBatchCloseTests ...   # 新测过
xcodebuild test ... -only-testing:GhosttyTests ...                        # 全绿(TabGuard 测试已删)
git add -A macos/Sources/Features/Tmux/ macos/Sources/Features/Terminal/TerminalController.swift macos/Tests/Tmux/ macos/Ghostty.xcodeproj/project.pbxproj
git commit -m "feat(macos/tmux): batch tab close maps to kill-window with one summary confirm (retires TmuxTabGuard)"
git push backup tmux-cc-core && git push fork tmux-cc-core
```

---

### Task 9: 全量回归 + 自动化冒烟 + 台账收尾

**Files:**
- Modify: `.superpowers/sdd/progress.md`(追记)
- 无生产代码改动(除非冒烟揪出 bug——那走 systematic-debugging,另起修复提交)

**Interfaces:** Consumes 全部前置任务。Produces: 冒烟报告追记 + 用户在场清单。

- [ ] **Step 1: 全量回归**

```bash
env -u ... zig build test -Dtest-filter=tmux --summary all      # 全过,计数记录(预期 ≥224)
env -u ... zig build -Demit-macos-app=false                     # 0 错
xcodebuild test ... -only-testing:GhosttyTests ...              # 全绿
```

- [ ] **Step 2: 构建安装 Debug app(provenance 规避流程,照抄)**

```bash
rm -rf /tmp/gbuild
xcodebuild -project macos/Ghostty.xcodeproj -target Ghostty -configuration Debug CODE_SIGNING_ALLOWED=NO SYMROOT=/tmp/gbuild
codesign --force --deep --sign - /tmp/gbuild/Debug/Ghostty.app
rm -rf macos/build/Debug/Ghostty.app && cp -R /tmp/gbuild/Debug/Ghostty.app macos/build/Debug/Ghostty.app
codesign --verify macos/build/Debug/Ghostty.app
```

- [ ] **Step 3: 自动化冒烟(CLI 注入闭环;AX 不可用,GUI 手势项留用户清单)**

```bash
# 起 app + 日志流(scratchpad 路径按会话取)
/usr/bin/log stream --level info --predicate 'subsystem CONTAINS "mitchellh"' --style compact > smoke.log &
macos/build/Debug/Ghostty.app/Contents/MacOS/ghostty --window-vsync=false --window-save-state=never \
  --command='/opt/homebrew/bin/tmux -CC new-session -A -s p3smoke' 2>stderr.log &
sleep 8
```

可自动验证项:
1. **F2 tmux→GUI 焦点**:`tmux new-window -t p3smoke -n w2; sleep 2; tmux select-window -t p3smoke:0` → 日志出现 focus 应用(补 `applyFocus` 处 info 日志亦可临时 grep `tmux`)且无 select-window 回发风暴(grep 计数 `select-window` ≤1 次/切换)。
2. **F4 编码**:`tmux send-keys -t p3smoke 'cat > /tmp/p3paste.txt' Enter` 后由 pane 内程序侧验证:直接检查日志里 `send-keys ... -l` 命令出现(host→tmux 方向需 GUI 打字,自动化不可达;退而验证:Zig 单测已覆盖编码正确性,冒烟仅确认无回归崩溃)。
3. **F1 命令回流实体化**(服务端模拟):`tmux split-window -t p3smoke; tmux new-window -t p3smoke` → 日志 windows 事件计数正确、无 error。
4. **%error 通道**:`tmux rename-window -t p3smoke:0 'x"y\z'` → 回流 `%window-renamed` 正常改名,无解析错误。
5. 结束:`tmux kill-session -t p3smoke` → 干净 teardown,app 存活。

- [ ] **Step 4: 用户在场清单(记入台账,留给用户复测)**

1. tmux 标签 ⌘T → 新 tmux 标签出现且获焦(`tmux list-windows` 计数 +1);普通窗口 ⌘T 仍本地
2. tmux pane ⌘D/⌘⇧D 四方向 → 真分屏(`list-panes` +1),新 pane 获焦
3. tmux 内 `select-window`/点另一 client 切窗 → 原生 tab 跟随;点原生 tab → tmux current window 跟随(`display-message -p '#{window_id}'`)
4. 右键 tmux 标签 Rename → tmux 侧名字变(`list-windows -F '#{window_name}'`),含特殊字符名
5. 混合组右键普通标签"关闭右侧" → 汇总确认框;确认后 tmux window 真被 kill(重连验证),本地标签关闭可撤销;取消零副作用
6. 大粘贴(50KB+ 文本进 vim)明显快于计划二基线,内容逐字节正确
7. 回归项:关标签确认框、红点 detach、⌘Q 存活、重连

- [ ] **Step 5: 台账 + 提交推送**

```bash
# progress.md 追记:各任务提交区间、测试计数、冒烟结果、遗留
git add -A && git commit -m "docs: plan 3 completion notes" && git push backup tmux-cc-core && git push fork tmux-cc-core
```

---

## Self-Review 结论(已执行)

- **Spec 覆盖**:F1→Task 3,F2→Task 4+5,F3→Task 7,F4→Task 6,R1+F5→Task 8,R2→Task 2,R3→Task 6,ABI→Task 1,冒烟→Task 9。出界项(D2 等)未混入。✓
- **占位符**:无 TBD;两处"以现有代码为准"均指向了具体行号模板(control.zig :996/:1045、TmuxPane :100-106),属防 Zig API 漂移的锚定而非空洞。✓
- **类型一致性**:`TmuxCommand`(Swift enum)/`ghostty_tmux_command_s`(C)/`TmuxCommand`(Zig extern)三层字段与 tag 顺序逐一核对;`session.send(TmuxCommand)` 在 Task 2 定义、Task 3/5/7/8 消费;`BatchCloseParticipant.batchCloseDisposition` Task 8 内闭环;`isTmuxManaged` 沿用 Task 8 不删。✓
- **已知实现风险(标注给实施者)**:① Zig writer API 版本差异(fixed/Allocating)——以邻近现用代码为准;② Swift C struct memberwise init 形参名——以生成接口为准;③ override 默认参数——Swift 不允许,省略即可;④ Task 5 的 Zig union 顺序与 C 枚举对应——以编译/checkGhosttyHEnum 为向导。均为局部机械调整,不影响设计。
