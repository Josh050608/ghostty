# 交接文档:计划三完成 + 仓库二次消失恢复(2026-08-02)

写给下一个上下文。读完本文 + 引用文件即可接手。

## 一句话现状

**计划三(A 级功能补全)九任务全部完成,opus 全分支终审 Ready,终审修复波收官**;期间仓库目录第二次整体消失(疑 iCloud),已从双远程恢复到新落点并全量验证等价(全量 zig test 3125/3141 逐字对齐基线)。**下一步:用户在场 8 项冒烟 → 上游 PR 准备。**

## 仓库与环境(关键,先读)

- **仓库物理位置:`/Users/zouchaoxu/Desktop/ghostty.nosync/ghostty`**;`Desktop/ghostty` 是指向 `ghostty.nosync` 的软链,**旧路径 `Desktop/ghostty/ghostty` 照常解析**。`.nosync` 后缀=iCloud 官方排除约定(防第三次消失,已 brctl 核验无同步活动)。
- 分支 `tmux-cc-core`,HEAD **`cbb6ca72b`**,与 backup/fork 双远程三方对齐。`tmux-cc-upstream` 在 backup 远程(本地未 checkout)。**每次提交后 `git push backup tmux-cc-core && git push fork tmux-cc-core`**。
- **`.superpowers/` 的 git 忽略在 `.git/info/exclude`**(非 .gitignore;原件随旧 .git 丢失后已补——新克隆必须记得补这行)。
- 构建环境坑全量见 auto-memory `[[ghostty-build-environment]]`。**本轮新增三个坑**:
  1. **全量 `zig build test` 会把 `macos/GhosttyKit.xcframework` 覆写成 arm64-only** → 之后必须重跑 `zig build -Demit-macos-app=false` 恢复双架构,再构建 app,否则 x86_64 切片链接失败。
  2. 全量 zig test 可能被内核 OOM 杀 → 加 `-j4`。
  3. **Swift 测试只跑 `-only-testing:GhosttyTests`,严禁全量 `xcodebuild test`**——会拉起未签名 GhosttyUITests-Runner 被 Gatekeeper 拦杀,并在用户屏幕弹 "damaged" 框。计数用 `xcresulttool get test-results summary` 的**顶层字段**(passedTests 等;设备层字段会虚高 ~50,历史上误读过)。
- Zig 门禁是**双 filter**(大小写敏感,小写 `tmux` 不覆盖 TmuxRouter/TmuxKeyEncode 等大写模块名):`-Dtest-filter=tmux` 与 `-Dtest-filter=Tmux` 都跑。ABI 护栏测试(名含 "Action.C")只被全量 test 覆盖,上游前跑一次全量。
- 其余沿用:zig 剥代理前缀跑;app 构建走 SYMROOT=/tmp/gbuild 全新目录→ad-hoc 签名→拷回(provenance 规避);pkill 只用 `"Debug/Ghostty.app"` 模式;AX 半残,GUI 手势验证必须用户在场;锁屏假 OOM 用 `--window-vsync=false`。

## 测试基线(恢复后全量复核,与丢失前逐字一致)

- 全量 zig:`207/207 steps; 3125/3141 tests passed (16 skipped)`
- Zig filter:tmux **217/217**、Tmux **93/93**
- Swift:GhosttyTests 顶层 **265 passed + 1 skipped + 0 failed**
- Debug app 已重建签名安装;GUI 冒烟 5 项(单窗口 0 丢包/回流/rename 注入往返/收尾)通过

## 计划三战果(20 提交,286853b7f..cbb6ca72b)

| 交付 | 内容 | 关键修复轮 |
|---|---|---|
| F1 反向新建 | ⌘T/File>New Tab/标签条"+"经 `requestNewTab` 缝发 `new-window`;四向分屏经 `newSplit` override 发 `split-window -h/-v(-b)`;不做 pane-diff,靠回流实体化 | — |
| F2 反向焦点 | viewer 解析 `%session-window-changed` → `focus` action 全管道 → `applyFocus`;GUI 切 tab 补发 `select-window`;回声抑制 = `TmuxFocusEchoFilter` 吞噬集合(**只为真正执行的操作登记**),`pendingFocus(windowId, paneId?)` 暂存未实体化目标 | 3 轮:时序标志→值比较→吞噬集合→按执行登记;终审波修分屏焦点 |
| F3 rename 双向 | `userDidSetTitleOverride` 缝(Base 上),三入口(TabTitleEditor/promptTabTitle/set_tab_title keybind)全接;非空→`rename-window`(Zig 侧转义 `\ " $ ~`+剥换行),**nil/空→`AUTOMATIC_RENAME` 命令恢复默认**;回流路径不走缝防回环 | 1 轮:空名坏死+第三入口 |
| F4 send-keys 吞吐 | `TmuxKeyEncode.zig` 三级编码:安全 ASCII literal(256B 块)/其余 hex(64B 块);黑名单 `\ " ; $ # ' { } ~ %`;**MIN_LITERAL_RUN=12 短 run 折叠**防命令数退化;0..255 属性测试 | 1 轮:折叠阈值 |
| F5 批量关闭映射 | `TmuxBatchClose` 三段式(收集→多态申报→一个汇总确认框);tmux 侧按 session 分组发 kill-window,GUI 移除靠回流;本地侧保留撤销;**TmuxTabGuard 退役**,菜单验证恢复上游语义 | 1 轮:orderOut(#8336)+泛型化 |
| R1/R2/R3 | 批量关闭多态化 / Swift `TmuxCommand` 类型化构造器(唯一 C 转换点,text 生命周期收口)/ 编码器纯模块 | — |
| **9b ABI bug** | 单窗口 windows 事件被丢的根因:**extern union 里的 `bool`(Task 5 的 Focus.has_pane)经 callconv(.c) 按值传递被 LLVM trunc i8→i1,squash 掉 union 重叠的 nodes 指针低字节**(aarch64 专有;union 布局取最后声明成员)。修复 bool→u8;连带拆掉 KeySequence.C.active/ReloadConfig.soft 两颗同类雷;comptime 护栏 `Action.CValue contains no bool` 防复发 | 评审在 LLVM IR 层复证 |

评审全程战绩:Critical×3(rename $/~ 注入、空名恢复坏死、ABI bool 截断)、Important×8,全部修复闭环。方法论亮点:评审员用**真实 tmux 实测**抓注入绕过、用 **LLVM IR** 复证 ABI 截断、用 **FIFO 论证**推翻时序修复——"评审必须独立验证"这条纪律持续产出真 bug。

## 仓库二次消失事故(已了结)

2026-07-31 00:22 `Desktop/ghostty/` 整体消失(第二次;桌面是 iCloud 同步盘,消失前后出现 `ghostty 2`/`ghostty 3` 近空幽灵目录=iCloud 冲突产物特征)。代码零损失(双远程);丢失=计划一/二 SDD 台账原件与评审 diff(精华在已提交 handoff 里)、计划三报告原件(内容存 `~/.claude` 转录);计划三台账已从控制器上下文**重建**于 `.superpowers/sdd/2026-07-30-tmux-cc-plan3-a-tier/progress.md`。恢复后全量验证与基线逐字一致。详见 auto-memory `[[repo-loss-incident-2]]`。桌面若还有 `ghostty 3` 幽灵目录可删;废纸篓若有旧 ghostty 可捞台账原件。

## 用户在场冒烟清单(8 项,待执行——下一个上下文的首要任务)

1. **tmux 标签四向分屏(⌘D/⌘⇧D)→ 焦点落新 pane**(`tmux display-message -p '#{pane_id}'` 核对;**终审 1 号检查点**,修复波刚改过这条路径)
2. ⌘T → 新 tmux 标签出现且获焦(`list-windows` +1);普通窗口 ⌘T 仍本地
3. tmux 侧 `select-window`/`select-pane` → 原生 tab/pane 跟随;点原生 tab → tmux current window 跟随
4. Rename(右键标签):含 `$ ~ " \` 的名字逐字节生效;**清空恢复默认**(automatic-rename 重新生效,标题回进程名)
5. 混合组右键"关闭右侧/其他标签" → 汇总确认框(kill N + close M 文案);取消零副作用;确认后 kill 生效(重连验证)、本地标签可撤销
6. 大粘贴(JSON/代码,50KB+)进 vim:速度明显快于纯 hex 时代、内容逐字节正确
7. 回归:关标签确认框、红点 detach、⌘Q 存活、重连
8. 观察项(预期行为,不是 bug):app ⌘Tab 重新激活时首次 select-window 回发被吞一次(第二次才发)

冒烟发现问题 → systematic-debugging 流程,修复提交推双远程。

## 上游 PR 准备(冒烟后)

- 剥离 SDD/docs 内部产物、rebase 到 `tmux-cc-upstream`(在 backup 远程,含计划一规范化重述,需追加计划二/三重述)
- 上游注意事项见 `docs/superpowers/handoff/2026-07-27-plan2-complete.md`;**PR 描述需披露**:批量关闭映射为逐窗口命令非真批处理、tmux 仅在 3.7b 实测(门槛 ≥3.2)、send-keys 黑名单保守集
- **仓库 CLAUDE.md 明令 agent 不得创建 issue/PR**;贡献需用户自写 Vouch 讨论 + AI 使用披露
- 上游前跑一次全量 `zig build test`(ABI 护栏不在双 filter 内)

## Backlog(终审已分级,全部可后置)

反向焦点:replaceSurfaceTree keepFocus 与重放的时序依赖未文档化(建议 pendingFocus 存在时不传 moveFocusTo)、不可解析 pendingFocus 复播可能反复抢 tab、apply() 重放接线行无测试。旁路入口:ScriptTab AppleScript 裸 close(自愈软失配)、ScriptTerminal/Shortcuts newSplit nil 误报、Dock 拖放/Service/app 级 newTab 塞本地 tab(混组已兼容)。其他:D2 并组竞态(spec 出界)、tmux 3.2/3.3 版本面未实测、echo filter 正向契约缺测、若干测试/注释小项——完整清单见重建台账末段。

## 必读文件索引

- 本文 + 计划三台账(重建版):`.superpowers/sdd/2026-07-30-tmux-cc-plan3-a-tier/progress.md`(git-ignored)
- 计划三 spec/plan:`docs/superpowers/specs/2026-07-30-tmux-cc-plan3-design.md`、`docs/superpowers/plans/2026-07-30-tmux-cc-plan3-a-tier.md`
- 历史交接:`docs/superpowers/handoff/2026-07-29-smoke-fixes-complete.md`(冒烟 7 bug)、`2026-07-27-plan2-complete.md`(架构速查+上游注意)
- iTerm2 差距分析:`docs/superpowers/specs/2026-07-28-iterm2-tmux-feature-gap.md`(B/C 级=未来 roadmap)
- auto-memory:`[[tmux-cc-project-state]]`、`[[ghostty-build-environment]]`、`[[repo-loss-incident-2]]`

## 流程约定(沿用)

brainstorm→spec→writing-plans→subagent-driven-development;逐任务两段评审+scoped re-review,评审必须独立验证(真 tmux/IR 级);台账实时追记;每任务全量门禁;提交后必推双远程。
