# 交接文档:tmux -CC 集成 · 计划二完成(终审后更新版)

写给下一个上下文的执行者。读完本文 + 引用文件,你就拥有继续工作所需的全部信息。

## 使命与现状

用户目标:让 Ghostty 支持 `tmux -CC`(iTerm2 式原生渲染)。**计划一(Zig 核心管道)与计划二(macOS UI)均已完成。**

- 分支 `tmux-cc-core`(开发一律在此):计划二代码终点 `54aaaf12c`,其上为文档提交(`1330501b0` 及本文档)。计划二共 12 任务、22+ 提交,起点为计划书提交 `820e521d8`(其下是计划一终点 `d895d4f66`)。
- **终审(opus 全分支评审)结论:Ready to merge(内部阶段),零 Critical、零 Important。**六项跨任务风险全部核清:线程/锁纪律完好(closed 原子标志在一切加锁之前)、router 引用协议 2:2 全路径平衡、apply() 的 prune 顺序与 create-once 一致、C ABI 有 comptime 测试锁定、Task 8 的 pbxproj 改动实为 iOS target 排除所必需(AppKit 文件)、Stream 逐字节接管分支性能可接受(comptime 门控,仅控制流付费)。
- 测试基线:Zig `-Dtest-filter=tmux` = **207/207**(计划一基线 195 + 新增 12);Swift GhosttyTests = **288 全过**;`zig build -Demit-macos-app=false` exit 0。
- 自动化 GUI 冒烟通过(真实 tmux 3.7b + zsh):attach 5 秒、AX 证实原生标签实体化、tmux 侧 new-window/split/rename/kill 回流、kill-session 干净收尾、`%exit` 幂等(解析器 2 次 exit → GUI 恰 1 条)、refresh-client 恰 1 次无风暴、零崩溃零错误日志。**计划二之前真实 zsh 会话约 1 秒即死,现在稳定。**
- `tmux-cc-upstream`:仍只含计划一的规范化重述,**不要在其上开发**;计划二改动尚未 rebase 过去。

## 必读文件(按需)

1. 本文档 + 冒烟报告:`.superpowers/sdd/plan2-smoke-report.md`(自动化结果 + 10 项待用户清单)
2. 计划二计划书(架构与任务定义):`docs/superpowers/plans/2026-07-27-tmux-control-mode-macos-ui.md`
3. 进度台账(每任务提交区间、评审结论、全部 Minor 与 triage):`.superpowers/sdd/progress.md`(**git-ignored 本地文件**,`git clean -fdx` 会毁掉它)
4. 设计 spec 与计划一交接(背景):`docs/superpowers/specs/2026-07-26-tmux-control-mode-macos-design.md`、`docs/superpowers/handoff/2026-07-27-plan2-handoff.md`
5. 环境坑:auto-memory `ghostty-build-environment`(本节末尾有速查)

## 下一步(按序)

### ① 用户在场交互冒烟(10 项,锁屏环境无法自动化)

清单在 `plan2-smoke-report.md` 第三节,核心:确认弹窗恰一次且 Cancel 无副作用;红点关窗 → `tmux ls` 显示 detached 存活 + 重复 attach;最后标签关闭走 detach 而非 kill-pane;tmux 标签右键"关闭右侧标签"灰化;拖拽 resize 防抖单发且 `#{client_width}x#{client_height}` 匹配(含 `window-decorations=false` 精确行数);标签切换无冗余 refresh-client;打字/粘贴/TUI(vim/htop);pane 点击焦点 → tmux active 跟随;双客户端互观 + SSH 远端;tmux 3.1 版本门槛(可装旧版的话)。

启动方式:`open macos/build/Debug/Ghostty.app --args --window-vsync=false --window-save-state=never --command='/opt/homebrew/bin/tmux -CC new-session -s smoke'`(构建流程见环境速查)。

### ② 上游 PR 准备(终审注意事项)

- **剥离内部产物**:分支上误入库的 `.superpowers/sdd/task-5-report.md`、`docs/superpowers/` 下的计划/交接/冒烟文档、`.gitignore` 的 scheduled_tasks.lock 行(42bd88b32)——rebase 到 `tmux-cc-upstream` 时全部剔除。
- **上游前建议修掉的小项**(内部阶段已 triage 为 backlog,上游权重更高):parseVersion 溢出保护(20 位数字 panic)+ 补 `3.10`/`10.0` 版本测试(两位 minor 必须通过);embedded.zig 里悬在 `ghostty_tmux_router_command` 上方的陈旧 "background blur" 注释;closeSurface 多叶节点仅杀 leftmost(改逐叶循环或加断言)。
- **PR 描述需披露的功能缺口**:批量关标签为菜单禁用而非映射;反向焦点(tmux→GUI)与反向新建(GUI→tmux)不做;route() 保持同步(邮箱饱和残余死锁类遗留);GTK 端未做(核心共享)。
- 流程:第一个 PR 仍建议 `tmux-cc-upstream` 上已备好的 UAF 修复 `d082e6e8a`(独立可提);贡献需先 Vouch(用户自写讨论);**AI 使用必须披露;agent 不得创建 issue/PR(仓库 CLAUDE.md 明令)**。

### ③ 二期 backlog(终审 triage 后)

send-keys 吞吐(64B 块 + hex 膨胀,大粘贴慢);route() 异步投递重构;批量关标签映射 + 自定义 `close_tab:other/right` keybinding 绕过;active-pane 反向焦点(需扩 list-windows 格式);GUI 反向新建映射;GTK 端;小项:control.zig 未知通知日志 error→info、bare-ST 终止路径测试、ref/release 恰一次的自动化测试(需 AppKit host)、undo 抑制测试。

## 架构速查(计划二建成了什么)

### Zig 侧

- **成帧修复(Task 1,最关键)**:`src/terminal/stream.zig` — Handler 声明 `tmuxControlActive()` 时(comptime `@hasDecl` 门控,其他 Handler 零开销),控制模式活跃期字节绕过 VT 解析器直接走 dcs_put 派发(`tmuxTakeoverPeel` 统一 peel;激活/中途激活/中途解除三态均正确,labeled loop 续跑剩余字节)。`src/terminal/tmux/control.zig` — idle 态 `esc_skip_start/string/string_esc` 三态跳过裸转义序列(ST/BEL 终结,max_bytes 封顶),`%exit` 现在被解析(接管期间 ST 到不了解析器,`%exit` 是唯一带内退出信号)。`stream_handler.zig` — `tmuxControlActive()` + `tmuxExit` 幂等(%exit 与尾随 ST 双触发只发一次 GUI 事件)。
- **Router 协议(Task 2/3)**:`src/termio/TmuxRouter.zig` — `closed` 原子标志(`close()` 后 sendCommand/register/unregister 静默丢弃,检查在一切加锁之前);unregister 改 events(预留)→panes(删除)→events(填充)三段不嵌套;`formatCommand(buf, apprt.action.TmuxCommand)` 纯函数渲染五种命令。
- **C API(Task 3)**:`ghostty_tmux_router_command(void*, ghostty_tmux_command_s{tag,id,width,height})`、`ghostty_tmux_router_release(void*)`(embedded.zig);tag 枚举 `KILL_PANE/KILL_WINDOW/DETACH/SELECT_PANE/RESIZE`,`checkGhosttyHEnum` 锁定 ABI。**引用协议:每条 attach 事件携带一个 GUI 所有的 router 引用,恰好一次 release**(正常 teardown/重复 attach/无 delegate/App.zig 死 surface 丢弃/幽灵会话清理,全路径已验证)。
- **版本门槛(Task 4)**:viewer `receivedTmuxVersion` — 可解析且 <3.2 → detach-client + exit 同批次;不可解析放行。

### Swift 侧(全部在 `macos/Sources/Features/Tmux/` + `macos/Sources/Ghostty/Ghostty.Tmux.swift`)

- **桥接(Task 5)**:`Ghostty.TmuxEvent`(attach/windows/exit,@unchecked Sendable)与深拷贝模型 `TmuxWindows/TmuxWindow/TmuxNode`(`Int(exactly:)` 防 trap,负/超界 root 拒绝);`.ghosttyTmux` 通知(object=宿主 SurfaceView,主线程已 trace 证实);`SurfaceConfiguration.tmuxRouter/tmuxPaneId`。
- **布局(Task 6)**:`TmuxSplitLayout.build(nodes:root:)` 纯函数——n 叉右结合折叠为二叉 + 轴向尺寸 ratio;`childrenStart+len <= root` 后序不变量保证终止;18 个单测。
- **会话(Task 7/8)**:`TmuxSessionManager.shared`(AppDelegate 挂载,按宿主 ObjectIdentifier 路由;幽灵会话自愈:key 命中但 hostView==nil → 清理重建)。`TmuxSessionController`:windows diff(removed→`tmuxForceClose` 无确认无命令;added→建 `TmuxTerminalController` 带预构建 SplitTree;kept→`tmuxUpdate`)、pane surface **create-once** 缓存(`surfaceView(forPane:)`)、专属 tabbingIdentifier、isRestorable=false、`prunePanes` 只清缓存。
- **标签控制器(Task 9-11)**:`TmuxTerminalController` — `tmuxUpdate` signature 比较跳过无变化重建(pane id+方向+ratio 三位小数),重建复用 view、焦点保持、undo 抑制(`disableUndoRegistration` 包裹);`syncFocusToSurfaceTree` override → select-pane(isKeyWindow 门控防冗余);关闭映射:`closeTab`→确认→kill-window、`closeWindow`(红点)→不确认→detach、`closeSurface`→确认→kill-pane、`validateMenuItem` 禁用批量关标签、`forceClosing`/teardown 直通 super;`windowDidResize` 防抖 0.1s → `contentLayoutRect × scale ÷ cell_px` → session 级去重 → refresh-client。

## 环境速查(比计划一新增的坑,全量见 memory)

- 老规矩:zig 一律代理剥离前缀;测试必 `-Dtest-filter`(tmux 基线现为 **207**);勿并发 zig build;app 构建 `xcodebuild -project macos/Ghostty.xcodeproj -target Ghostty -configuration Debug CODE_SIGNING_ALLOWED=NO` 后 `xattr -rc macos/build && codesign --force --deep --sign - macos/build/Debug/Ghostty.app`(完整 `zig build` 会死在 DockTilePlugin 签名)。
- **用户 zsh 有 `log` 函数遮蔽系统命令**:抓日志必须 `/usr/bin/log stream --level info --predicate 'subsystem CONTAINS "mitchellh"'`(info 不落盘,`log show` 看不到,必须先启动 stream 再触发事件)。
- **GUI 启动的 app PATH 无 /opt/homebrew/bin**:`--command` 里 tmux 写绝对路径,否则静默失败。
- **锁屏使 app 主线程停滞数分钟**:冒烟前 `caffeinate -d -u` 保持唤醒;脚本一律条件驱动等待(grep 日志目标行),不用固定 sleep;AX 断言(`osascript` System Events 窗口枚举)需要**解锁的用户会话**,锁屏返回空列表。
- Swift 测试真实可跑:`xcodebuild test -project macos/Ghostty.xcodeproj -scheme Ghostty -only-testing:GhosttyTests/<套件> CODE_SIGNING_ALLOWED=NO`(从仓库根跑,勿 cwd=macos)。
- 杀调试实例用 `pkill -f "Debug/Ghostty.app"`;勿动 /Applications 正式版。

## 流程约定(沿用)

brainstorm→spec 已有;writing-plans 写计划 → subagent-driven-development 执行(实现者简报文件制 + 评审者 diff 包制 + 修复循环);台账续写 `.superpowers/sdd/progress.md`;每任务含全量构建检查;**修复子代理必须粘贴 verbatim 测试输出**(计划二教训:低配模型曾伪报测试结果)。
