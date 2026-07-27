# 交接文档:tmux -CC 集成 · 计划二(macOS UI)

写给下一个上下文的执行者。读完本文 + 引用的三份文档,你就拥有继续工作所需的全部信息。

## 使命与现状

用户目标:让 Ghostty 支持 `tmux -CC`(iTerm2 式原生渲染:tmux window → 原生标签页,pane → 原生分屏)。

- **计划一(Zig 核心管道)已完成**:分支 `tmux-cc-core`,HEAD `1b592ad`,14 个提交。
  端到端冒烟通过(真实 tmux 3.7b):attach/窗口列表(含名字)/改名/输出/退出全链路到达 Swift 层(目前 Swift 只打日志)。
- **分支 `tmux-cc-upstream`**:同一套改动 rebase 到上游 main、按上游提交风格重述、剔除内部文件——为将来 PR 准备,**不要在上面开发**;开发一律在 `tmux-cc-core`。
- **计划二(本次任务)**:先修成帧缺陷(见下),再做 macOS UI。完成后用户才能真正使用 tmux -CC。

## 必读文件(按序)

1. 设计 spec:`docs/superpowers/specs/2026-07-26-tmux-control-mode-macos-design.md`(计划二 = 其中阶段 3–5)
2. 计划一文档(了解已建成什么):`docs/superpowers/plans/2026-07-26-tmux-control-mode-core.md`
3. 进度台账(含全部评审 Minor 与 backlog):`.superpowers/sdd/progress.md`
4. 冒烟报告(含成帧缺陷完整诊断):`.superpowers/sdd/task-11-smoke-report.md`

## 计划二第一任务(强制):DCS 裸 ST 成帧修复

**不修这个,UI 毫无意义**——控制模式在真实 shell 下约 1 秒即死。

现象与证据(已实证,细节在冒烟报告):
- 真实 pane shell(zsh + ghostty shell 集成)启动时发 `ESC k title ST` 与 OSC 7;tmux 会向"有能力的"客户端终端**裸转发**某些序列(不裹进 `%output`)。
- 裸序列末尾的 ST(`ESC \`)被 ghostty 终端解析器视为 DCS 1000p 透传结束 → unhook → viewer 收到 `.exit` 假退出,而真实 tmux 客户端仍然挂着(`tmux ls` 可证)。
- 对照:pane 跑 `/bin/sh`(不发转义)则控制模式无限稳定——整个冒烟清单就是这么跑通的。
- 已排除:非 control.zig 的 idle 断言(加过字节探针,无毒字节);非 set-titles(用户配置为 off);与外层 TERM 无关(xterm-256color 仍死)。
- iTerm2 明确容忍控制流中穿插的裸转义序列。

修复方向(设计判断留给你):在 `src/terminal/dcs.zig` 的 tmux hook 层面,ST 不应立即视为控制模式终结——tmux 真正退出时先发 `%exit` 行(或 DCS 后紧跟新内容)。可参考 iTerm2 的处理:容忍/丢弃穿插序列,仅在收到 `%exit` 后(或 pty EOF)才结束。注意 `control.zig` 的 idle 态"非 % 即 broken"断言(line ~84)可能也要配合放宽。**先写回放测试**(用冒烟报告里记录的真实字节序列构造 fixture)。

## 计划二主体(spec 阶段 3–5)

用 superpowers:writing-plans 基于 spec 写计划二,再用 subagent-driven-development 执行。核心内容:
- Swift `TmuxSessionController`:attach → 专属窗口组;windows diff(按 id,tmux 保证不复用)→ 原生标签页(macOS 每标签 = 加入 tab group 的 TerminalController)
- 扁平布局树 → `SplitTree` 转换(纯函数,可单测)
- pane surface 创建:`ghostty_surface_config_s` 已有 `tmux_router`(裸指针原样回传)+ `tmux_pane_id` 字段;非空即用 TmuxPane 后端(核心侧全部就绪)
- resize(`refresh-client -C`,复用 `Input.send_command` 通道,可能需要新增 `ghostty_surface_tmux_command()` C API,见 spec)
- 关闭映射(kill-pane/kill-window/detach)、焦点同步(select-pane)
- 版本门槛(tmux ≥3.2)与竞态加固

## 计划二 backlog(来自最终全分支评审,按优先级)

1. DCS 裸 ST 成帧修复(上面,第一)
2. `route()` 同步设计决策:目前宿主线程持三把锁跨线程投递 pane 输出;评审建议改异步投递(pane 侧输出队列 + 唤醒),可永久消除一类死锁(锁拆分已缓解主要 ABBA,但邮箱饱和场景仍在,见台账)
3. Router 生命周期协议:`closed` 标志(宿主亡后 sendCommand 静默丢弃)+ attach 动作携带 GUI 持有的引用(防 UAF 竞态)
4. Viewer `detached` 是终态:pane surface 必须"每 pane 创建一次",GUI 设计要遵守
5. OOM 中途 sweep 孤儿 Terminal、unregister OOM 丢事件(低危,顺手修)
6. send-keys 吞吐(64 字节块 + hex 膨胀;大粘贴慢,考虑可打印段用 `-l`)

## 关键接口速查(计划二要消费的)

- **C action**:`GHOSTTY_ACTION_TMUX`,`ghostty_action_tmux_s { tag: ATTACH|WINDOWS|EXIT, value }`;ATTACH 带 `void* router`(原样存下,建 pane surface 时填回 config);WINDOWS 带 windows/nodes 两个数组(指针+长度,**回调期间有效,必须拷贝**)
- **布局树编码**:nodes 扁平数组;`kind ∈ {PANE, HORIZONTAL, VERTICAL}`;每 window 有 root 下标;分裂节点的孩子是 `[children_start, children_start+children_len)` 连续区间(实现会把孩子根**浅拷贝**成连续段,拷贝项的 children 下标仍指向原位置——按区间遍历即正确重建;嵌套分裂已有单测 `H[p1,V[p2,p3]]`)
- **窗口名**:`name` 为 NUL 结尾 C 串,非空保证成立(Zig 侧 dupeZ)
- Swift 现有日志 handler 在 `macos/Sources/Ghostty/Ghostty.App.swift`(搜 `GHOSTTY_ACTION_TMUX`),计划二用真实控制器替换

## 环境速查(踩过的坑,详见 memory 与冒烟报告)

- zig 一律 `env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY zig ...`(Clash TUN 会挂死 zig 的 HTTP 客户端);依赖已全在缓存
- 测试永远 `-Dtest-filter`;`--summary all` 有 ~70 基线,命中数 = 总数 − 70;当前 tmux 过滤 = **195/195**
- macOS app:`xcodebuild -project macos/Ghostty.xcodeproj -target Ghostty -configuration Debug CODE_SIGNING_ALLOWED=NO`,然后 `xattr -rc macos/build && codesign --force --deep --sign - macos/build/Debug/Ghostty.app`(provenance xattr 会卡内置签名)
- 冒烟启动:`--window-vsync=false --window-save-state=never --command='tmux -CC new-session -s smoke /bin/sh'`;崩溃后删 `~/Library/Saved Application State/com.mitchellh.ghostty.debug.savedState`;锁屏时 CVDisplayLink 假 OOM,靠 `--window-vsync=false` 绕过
- 禁止并发 zig build;警惕 cwd=macos 产生的 `macos/macos/GhosttyKit.xcframework`
- 用户正式版 Ghostty 常驻(/Applications,bundle id 无 .debug 后缀),勿误杀
- Swift 侧验证:`log stream --level info --predicate 'process == "ghostty" AND subsystem CONTAINS "mitchellh"'`

## 上游/PR 背景(用户已知,勿重复调研)

- 上游有已接受 issue #1935(tmux 控制模式);贡献需先 Vouch(用户自写讨论);AI 使用必须披露;agent 不得创建 issue/PR(仓库 CLAUDE.md 明令)
- 建议的第一个 PR 是 UAF 修复(`tmux-cc-upstream` 分支的 `d082e6e8a`),在计划二之外独立可提

## 流程约定(沿用计划一)

- brainstorm 已做(spec 即产物)→ 直接 writing-plans 写计划二 → subagent-driven-development 执行
- 每任务:实现者子代理(简报文件制)→ 评审者子代理(diff 包制)→ 修复循环;台账 `.superpowers/sdd/progress.md` 续写
- 全量构建检查纳入每个任务(计划一的教训:过滤测试放过了非穷尽 switch)
