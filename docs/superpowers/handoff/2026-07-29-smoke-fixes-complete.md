# 交接文档:tmux -CC 用户在场冒烟完成 · 7 bug 修复(2026-07-29)

写给下一个上下文。读完本文 + 引用文件即可接手并自主决定下一步。

## 一句话现状

计划一(Zig 核心)+ 计划二(macOS UI)早已完成并通过 opus 终审;**2026-07-28/29 用户在场跑冒烟清单,抓出并修复了 7 个真 bug,用户已逐一复测通过**。软件现在真实可用(nvim/vim、打字、滚动、关标签/关格子、重连、⌘Q 存活全部正常)。分支干净,已推双远程。**下一步由你和用户在新上下文里决定**(候选见末节)。

## 仓库与环境(关键,先读)

- **仓库路径:`/Users/zouchaoxu/Desktop/ghostty/ghostty`(注意嵌套两层 ghostty)**。历史上仓库被移动/误删过,现稳定在此。一切 git/构建操作 cd 到这里。
- 分支:开发一律在 **`tmux-cc-core`**(HEAD `3c7aa4bb4`)。`tmux-cc-upstream` 只含计划一规范化重述,勿在其上开发。
- **云端备份(本轮新增,务必续用)**:私有 `Josh050608/ghostty-backup`(remote 名 `backup`,三分支)+ 公开 fork `Josh050608/ghostty`(remote 名 `fork`,两条 tmux 分支)。**每次提交后 `git push backup tmux-cc-core && git push fork tmux-cc-core`**——本地分支从未进过官方仓库,云端是唯一异地副本(教训:仓库曾整个消失)。
- 构建环境坑全量见 auto-memory `[[ghostty-build-environment]]`。**本轮新增两个关键坑**:
  1. **provenance 签名坑**:app 被 GUI(open/Finder)启动过后,LaunchServices 给 bundle 盖 `com.apple.provenance` 扩展属性,`xattr` 删了内核立即恢复,增量重构建后 `codesign` 必报 "detritus not allowed"。**解法:全新目录构建** `xcodebuild ... SYMROOT=/tmp/gbuild` → 对 `/tmp/gbuild/Debug/Ghostty.app` 签名 → `rm -rf macos/build/Debug/Ghostty.app && cp -R` 回标准路径(签名随拷贝保持)。每次 app 被 GUI 启动过再重签都走这条。
  2. **本机 AX 半残**:`osascript` System Events 的 `frontmost` 可用,但窗口枚举恒返回 0、`keystroke` 静默失效。**GUI 断言/按键注入不可用,视觉验证必须用户在场**。
- `pkill` 只用 `pkill -f "Debug/Ghostty.app"` 或 gbuild 路径,**切勿**用 `"Ghostty.app/Contents"` 宽模式(会误杀 /Applications 正式版)。

## 标准构建 + 安装流程(照抄)

```bash
cd /Users/zouchaoxu/Desktop/ghostty/ghostty
# Zig 一律剥代理前缀:
env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY \
  zig build test -Dtest-filter=tmux --summary all      # 基线 213/213
env -u ... zig build -Demit-macos-app=false            # 库
# app(用全新 SYMROOT 绕 provenance):
rm -rf /tmp/gbuild
xcodebuild -project macos/Ghostty.xcodeproj -target Ghostty -configuration Debug \
  CODE_SIGNING_ALLOWED=NO SYMROOT=/tmp/gbuild
codesign --force --deep --sign - /tmp/gbuild/Debug/Ghostty.app
rm -rf macos/build/Debug/Ghostty.app && cp -R /tmp/gbuild/Debug/Ghostty.app macos/build/Debug/Ghostty.app
codesign --verify macos/build/Debug/Ghostty.app
```

Swift 测试:`xcodebuild test -project macos/Ghostty.xcodeproj -scheme Ghostty -only-testing:GhosttyTests CODE_SIGNING_ALLOWED=NO`(从仓库根跑)。

## 全自主 GUI 调试闭环(本轮建立,AX 失效下的标准姿势)

用户在场只需"操作 + 报现象",复现/定位/验证全部可自主完成:

1. **spawn app 并抓 stderr**:`/tmp/gbuild/Debug/Ghostty.app/Contents/MacOS/ghostty --window-vsync=false --window-save-state=never --command='/opt/homebrew/bin/tmux -CC new-session -A -s smoke' 2> stderr.log &`(Zig panic 落在 stderr)。
2. **抓崩溃栈**:同样命令套 `lldb --batch -o run -k 'bt' -k 'quit' -- <app 二进制> ...`,`grep "frame #" out.log` 拿到精确到 `file:line` 的调用栈。
3. **注入激励**:`/opt/homebrew/bin/tmux send-keys -t smoke 'vim' Enter` 从服务端注键;`/opt/homebrew/bin/tmux capture-pane -p -t smoke` 读服务端屏;`list-panes -F '#{alternate_on} #{pane_current_command}'` 读 pane 状态。
4. **日志计数**:先启 `/usr/bin/log stream --level info --predicate 'subsystem CONTAINS "mitchellh"' --style compact > live.log &`,再触发事件,grep `viewer action=`、`send-keys`、`window_close` 等。注意用户 zsh 的 `log` 是函数,必须写 `/usr/bin/log` 全路径。

## 本轮修复的 7 个 bug(全部已提交,含根因)

基线从 195→**213**(新增 window-close 4 测)。`4ba7d05f7..HEAD` 共 7 提交:

| 提交 | 层面 | 根因一句话 |
|---|---|---|
| `b27832559` | 协议 | `%output` 载荷未做 vis(3) 八进制解码(`\033` 直通)→ 乱码。加 `unescapeOctal` 原地解码 |
| `d959cb101` | 时序 | `tmuxDrainRouter` 后漏 `mailbox.notify()`,send-keys 写请求坐等下一次无关唤醒 → 按键秒级延迟、孤立按键永不达 |
| `373337245` | 状态恢复 | attach 恢复 pane 后未按 `alternate_on` 归位活动屏 → 主屏 pane 表现如备用屏(滚动变翻历史) |
| `0d6941ace` | **设计** | pane surface 曾是"主动终端":抢答设备查询(DA1/OSC11)+ 主动焦点上报,经 send-keys 变幽灵按键。nvim 启动查 OSC11 背景色撞 `colorOperation` 的 `.get().?` null 裸解 → **崩整个 app**。修复=被动镜像(`tmux_passive`:丢弃 write 类消息、跳过焦点上报、颜色查询短路) |
| `db2b0e064` | 协议 | 杀非当前 window 只发 `%window-close`(无 layout-change),而我们从未解析它 → 死标签僵在 GUI(叉号/⌘W/右键全失灵),但 kill 已达 tmux。修复=解析 window-close + unlinked-* 三变体,resync list-windows |
| `3c7aa4bb4` | UI | `anyLiveWindow()` 返回刚插入字典的自身窗口 → 自己跟自己成组 → 多 window 开成独立 macOS 窗口。修复 `excluding` 自身 |
| `3c7aa4bb4` | UI | tmux pane 无本地进程 → `needsConfirmQuit` 恒 false → ⌘W 关 pane/tab 无确认。改按"kill 不可逆"强制确认(detach 仍不确认) |

## 已知遗留(未修,供决策)

- **菜单"关闭右侧标签页"应灰化,实测可点**(冒烟清单第 4 项)。低优先级验证项,不影响使用。`validateMenuItem` 里对该 selector 的禁用可能没覆盖 tmux tab 场景,值得一查。
- **冒烟清单未做项**:双客户端互观(需第二个 `tmux attach -t smoke` 无 -CC)、SSH 远端、tmux 3.1 版本门槛(需装旧版)。都需用户/远程环境配合。
- **欠单测**:修复 #2(mailbox 唤醒)、#4(被动镜像)需线程/AppKit 环境,较难纯单测;#3(活动屏归位)可用 testViewer 断言 active screen,值得补。

## 下一步候选(在新上下文和用户敲定)

1. **顺手清尾**:修菜单灰化小项 + 补 #3 的单测(成本低,把冒烟彻底关闭)。
2. **计划三(A 级功能补全)**:见 `docs/superpowers/specs/2026-07-28-iterm2-tmux-feature-gap.md`。四项——① GUI 反向新建 window/pane(`new-window`/`split-window`,评审者第一个会试的操作,最大交互缺口)② send-keys 吞吐(literal 快路径,大粘贴慢)③ 反向焦点(`%session-window-changed` + 接 `%window-pane-changed` 到原生焦点)④ rename 双向。规模约计划二 1/3。
3. **上游 PR 准备**:见 `docs/superpowers/handoff/2026-07-27-plan2-complete.md` 的 upstream 注意事项(剥离 SDD/docs 内部产物、rebase 到 tmux-cc-upstream、parseVersion 溢出保护、blur 注释)。**仓库 CLAUDE.md 明令:agent 不得创建 issue/PR**;贡献需用户自写 Vouch 讨论 + AI 使用披露。这 7 个 bug 修复本身是很好的 PR 素材。

## 必读文件索引

- 本文 + 计划二终审交接:`docs/superpowers/handoff/2026-07-27-plan2-complete.md`(架构速查、终审结论、原始 backlog)
- iTerm2 差距分析:`docs/superpowers/specs/2026-07-28-iterm2-tmux-feature-gap.md`(计划三蓝本,三层逐项对比 + A/B/C 分级)
- 进度台账(git-ignored 本地):`.superpowers/sdd/progress.md`(每任务提交区间、本轮 7 bug 的完整调试记录与方法论)
- 冒烟清单:`.superpowers/sdd/plan2-smoke-report.md`(第三节 10 项,含未做项)
- 计划二计划书:`docs/superpowers/plans/2026-07-27-tmux-control-mode-macos-ui.md`
- auto-memory:`[[tmux-cc-project-state]]`(项目状态)、`[[ghostty-build-environment]]`(全量环境坑)

## 流程约定(沿用)

brainstorm→spec→writing-plans→subagent-driven-development;台账续写 `.superpowers/sdd/progress.md`;每任务含全量构建检查;修复子代理必须粘贴 verbatim 测试输出;**提交后必推 backup + fork 双远程**。
