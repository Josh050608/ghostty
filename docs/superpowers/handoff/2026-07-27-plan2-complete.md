# 交接文档:tmux -CC 集成 · 计划二完成

日期:2026-07-27。分支 `tmux-cc-core`。计划二(macOS UI)12 任务全部完成并通过逐任务评审(计划:`docs/superpowers/plans/2026-07-27-tmux-control-mode-macos-ui.md`;台账:`.superpowers/sdd/progress.md`;冒烟:`.superpowers/sdd/plan2-smoke-report.md`)。

## 已建成(计划二增量)

- **Task 1(关键)**:DCS 裸转义序列成帧修复——Stream 层接管(tmux 控制模式活跃期字节绕过 VT 解析器直入 dcs_put;`@hasDecl` comptime 门控零开销)+ control.zig idle 态 esc-skip 状态机 + `%exit` 解析 + tmuxExit 幂等。真实 zsh 会话由约 1 秒死亡变为稳定。
- **Task 2-4**:OOM 窗口收窄(router unregister 预留、viewer take 预留);Router 生命周期协议(closed 原子标志、GUI 持有引用、`ghostty_tmux_router_command/release` C API、Zig 侧命令格式化);Viewer 版本门槛(<3.2 → detach+exit 同批次)。
- **Task 5-7**:Swift 深拷贝事件模型(`Ghostty.TmuxEvent/TmuxWindows/...`,Int(exactly:) 防 trap)、SurfaceConfiguration tmux 字段、`.ghosttyTmux` 通知(主线程已 trace 证实);`TmuxSplitLayout.build` 纯函数(后序不变量保证终止);`TmuxSessionManager/Controller` 生命周期(每 attach 恰一次 release 全路径验证、幽灵会话自愈)。
- **Task 8-11**:windows diff → 专属窗口组原生标签页(create-once pane surface、tabbingIdentifier 隔离、isRestorable=false);布局重建(signature 跳过、view 复用、undo 抑制)+ 焦点→select-pane(isKeyWindow 门控);关闭映射(标签→kill-window 带确认、红点→detach 不确认、pane→kill-pane 带确认、teardown 直通、批量关标签菜单禁用);resize(防抖 0.1s、session 去重、contentLayoutRect 精确换算、初始对齐)。

测试基线:Zig tmux filter **207/207**;Swift GhosttyTests **288 通过**。

## Backlog(按优先级,含来源)

1. **用户在场冒烟清单**(plan2-smoke-report.md 第三节 10 项)——锁屏环境无法自动化的交互/视觉验证,建议用户回来后先过一遍。
2. send-keys 吞吐(64B 块 + hex 膨胀;大粘贴慢)——计划一遗留。
3. route() 同步→异步投递(邮箱饱和残余死锁类)——计划二既定决策 1,留给上游评审阶段。
4. 批量关标签映射(现为菜单禁用;可做成逐窗 kill-window)+ 自定义 close_tab:other/right keybinding 绕过(配置门控)。
5. tmux→GUI active-pane 反向焦点(需扩展 list-windows 格式)。
6. 反向新建映射(GUI 新建标签/分屏 → new-window/split-window)——spec 二期。
7. GTK(Linux)端 UI——核心层全部共享。
8. 小项:control.zig 未知通知日志降级(error→info)、parseVersion 溢出保护、closeSurface 多叶断言、Int(windows_len) 精确转换。

## 上游/PR(不变)

- UAF 修复(`tmux-cc-upstream` 分支 `d082e6e8a`)独立可提;贡献需先 Vouch,AI 使用必须披露;agent 不得创建 issue/PR。
- `tmux-cc-upstream` 需要把计划二的改动重新 rebase/重述后追加(目前只含计划一)。

## 环境(全部记录在 auto-memory `ghostty-build-environment`)

关键新增:用户 zsh 遮蔽 `log` → 用 `/usr/bin/log stream --level info`(info 不落盘);GUI 启动 PATH 无 homebrew → `--command` 里 tmux 用绝对路径;锁屏使 app 主线程停滞数分钟 → 冒烟前 `caffeinate -d -u` + 条件驱动等待;AX 断言需解锁会话。
