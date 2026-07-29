# 计划三设计:tmux -CC A 级功能补全

日期:2026-07-30。基线:`tmux-cc-core` @ `2479ee88a`(Zig tmux 214/214,Swift 全绿)。
蓝本:`docs/superpowers/specs/2026-07-28-iterm2-tmux-feature-gap.md`(A 级四项)。
经用户逐节确认的 brainstorm 产物;实施计划见后续 writing-plans 输出。

## 目标与范围

**做**(五项功能 + 三处配套重构):

- F1 GUI 反向新建:⌘T→`new-window`;分屏手势→`split-window`
- F2 反向焦点:tmux 侧切 window/pane → 原生焦点跟随;GUI 切 tab 补发 `select-window`
- F3 rename 双向:GUI 改名 → `rename-window`
- F4 send-keys 吞吐:literal 快路径三级编码,替换纯 hex
- F5 批量关闭映射:"关闭右侧/其他标签"从置灰改为翻译成批量 `kill-window`
- R1 批量关闭多态化重构(服务 F5)
- R2 Swift 类型化命令构造器(服务 F1/F3)
- R3 按键编码器独立纯模块(服务 F4)

**不做**(明确出界):

- D2 并组竞态(tmux 首窗口有时并进普通窗口标签组)——留 backlog,修复会改默认观感需单独裁定
- pause 流控、剪贴板同步、`%window-close` 省往返、备用屏历史(B 级)
- Dashboard、隐藏窗口、状态栏、持久化(C 级)
- viewer.zig 拆分——大而内聚,仓库惯例养大文件,拆分只给上游 PR 添移动噪音
- new-window 传 cwd/affinity——tmux default-path 说了算,YAGNI

## 关键决策(经用户确认)

1. **⌘T 直接接管**:焦点在 tmux 标签上时 ⌘T 发 `new-window`(iTerm2 同款语义);焦点在普通标签上保持本地行为。⌘N 不接管。附带效果:消灭"⌘T 往 tmux 标签组里插本地标签"的混组来源之一。
2. **命令通道走方案 A(类型化枚举扩展)**,拒绝"Swift 拼原始字符串"的方案 B。理由:转义/注入边界必须落在有测试基建的 Zig 侧(控制模式里换行=命令分隔符,rename 携带任意用户文本);GTK 前端将来白拿 `formatCommand`;枚举有 `checkGhosttyHEnum` 编译期看守;viewer 队列得以保持"入队即格式良好"的假设。
3. **重构随任务走**:R1/R2/R3 是计划内前置任务,每个重构是独立纯机械提交,行为变更另起提交(上游评审友好)。

## 架构

零新增长期组件。五项功能是在既有六环节(controller → session.send → C ABI → formatCommand → viewer 队列 → tmux)上加分支;新状态仅两处:Swift 侧焦点抑制标志 + `pendingFocusWindowId`,viewer 侧 `tmux_focus` action。

```
GUI 手势/菜单                        tmux 通知
    │                                   │
    ▼                                   ▼
TmuxTerminalController            viewer.zig(+%session-window-changed 解析)
    │ session.send(.newWindow 等)      │ 新 action: tmux_focus{window_id, pane_id?}
    ▼    (R2 构造器)                    ▼
ghostty_tmux_router_command       apprt action → TmuxSessionController
    │ (struct +text 字段)              │ 抑制标志置位 → 选原生 tab/pane → 复位
    ▼                                   │ (置位期间不回发 select-pane/-window)
TmuxRouter.formatCommand               │ 未知 window → pendingFocusWindowId
    │ (+5 case,rename 转义)
    ▼
viewer 命令队列(现有)→ tmux
```

### ABI 扩展(方案 A)

- `ghostty_tmux_command_tag_e` 追加:`NEW_WINDOW`、`SPLIT_HORIZONTAL`、`SPLIT_VERTICAL`、`RENAME_WINDOW`、`SELECT_WINDOW`
- `ghostty_tmux_command_s` 追加 `const char* text`(rename 用,其余 NULL;入口同步消费,借 Swift 字符串安全——`ghostty_tmux_router_command` 当场 format 进栈缓冲)
- `formatCommand` 新 case;rename 转义在此:剥 `\n\r`、转义 `\` 与 `"`
- 分屏方向映射:右→`split-window -h`,下→`-v`,左→`-h -b`,上→`-v -b`(3.2+ 有 `-b`,我们版本门槛内),target = 焦点 pane id

### R2:Swift 命令构造器

Swift enum `TmuxCommand`(`.killPane(id)`、`.renameWindow(id, String)` 等)→ 一处转换为 C 结构体,text 的 CString 生命周期用 `withCString` 收口在转换函数内。全部现有调用点迁移。约 60 行新文件。

## 功能数据流

### F1 反向新建

- `TmuxTerminalController` override `newTab` → `.newWindow`;override 分屏动作 → `.splitH/.splitV(±before, 焦点 pane id)`
- **不做 pane-diff 取 id**(iTerm2 TmuxController.m:1912-1985 那套不抄):tmux 回流 window-add/layout-change 走现有重同步自动实体化
- teardown/forceClosing 时落回 super(与现有 close 系 override 同款守卫)

### F2 反向焦点

- viewer:补 `%session-window-changed`(`$session @window`)解析;连同已解析的 `%window-pane-changed`(`@window %pane`)发 `tmux_focus` action
- Swift:按 window id 找 controller → 选中原生 tab;有 pane id 则聚焦对应 SurfaceView。全程置抑制标志
- GUI→tmux 半边:切原生 tab 时在 `syncFocusToSurfaceTree` 补发 `select-window -t @id`(现在只发 select-pane,不切 tmux 当前 window),抑制标志置位时跳过
- **时序**:⌘T 后 `%session-window-changed` 可能先于新窗口实体化到达 → `pendingFocusWindowId` 暂存,`apply()` 添加窗口后补应用;后续焦点事件自然覆盖过期值
- 回环分析:GUI 发 select-window → tmux 回 `%session-window-changed` → 应用时目标已是当前 tab,幂等 + 抑制,不再回发

### F3 rename 双向

- tmux→GUI 已通(`%window-renamed` → titleOverride),零改动
- GUI→tmux:"Rename Tab..." 提交在 tmux 标签上 override → `.renameWindow(id, name)`
- **无本地乐观更新**:等 `%window-renamed` 回流改标题(毫秒级),保持 tmux 权威单向流
- 手动 rename 后 tmux 自动关该 window 的 automatic-rename——tmux 惯例,不额外处理

### F4 send-keys 吞吐(R3 一体)

- 新纯模块 `src/termio/TmuxKeyEncode.zig`:字节流 → 安全段/其他段切分 → 安全可打印 ASCII 段走 literal(`send-keys -t %d -l -- "…"`,块上限 256B),其余(C0、非 ASCII、`"` `\` `;` `$` `#` 等高危字符)走现有 hex(`-H`)
- 转义表照抄 iTerm2(TmuxGateway.m:937-1025)并显式加 tmux 命令分隔符 `;` 入黑名单;≥3.2 门槛 → 三级里的版本分支全删
- `TmuxPane.queueWrite` 只做调用;段序=入队序,天然保序
- 收益:大粘贴从 3x hex 膨胀 + 64B/命令 → 1:1 literal + 256B/命令,命令数降一个数量级

### F5 批量关闭映射(R1 一体)

- 新 helper `TmuxBatchClose`(~100 行)三段式:**收集**(右侧/其他标签)→ **申报**(controller 多态:普通→本地关+撤销;tmux→kill-window 不可逆)→ **一个确认框**汇总("将 kill N 个 tmux window、关闭 M 个本地标签,kill 不可撤销"),取消零副作用
- 执行:tmux 侧按所属 session 分组循环 `.killWindow(id)`(覆盖 D2 竞态造出的多会话混组);本地侧走现有 `closeTabImmediately`(撤销只对本地标签注册)
- tmux 标签的 GUI 移除不主动做——等 kill 回流重同步走现有 `tmuxForceClose`(与单个 kill-window 同一条已验证路径)
- 菜单验证恢复上游语义(右侧有标签即亮);**`TmuxTabGuard` 退役删除**(翻译取代禁用;sweep 自己分流,键盘绕过验证的洞结构性堵死)
- 原生 `performCloseOtherTabs:` 不动(逐 tab 走 windowShouldClose→tmux 映射,已安全)

## 错误处理

- 新命令错误走现有 `%error` 通道(viewer 已解析记日志);closed router 上静默丢弃(现有语义)
- `pendingFocusWindowId`:未知 window 的焦点通知暂存;重同步后补应用;窗口不再出现则被后续焦点事件覆盖,无泄漏
- rename 空名:照发,tmux 自行处理(可能触发 automatic-rename),不拦

## 测试策略

- **Zig**:`formatCommand` 新 5 case + rename 转义表(注入向量:内嵌换行/引号/分号);viewer `%session-window-changed` 解析、`tmux_focus` 发射、焦点先于 window-add 的时序用例;`TmuxKeyEncode` 穷举单测(分段边界、转义 round-trip、纯 hex/纯 literal/混合流)——转义 bug 即命令注入,此处测试密度最高
- **Swift**:`TmuxBatchClose` 申报/分组(协议桩,沿 TmuxTabGuardTests 手法);R2 构造器转换正确性(含 text 字段 marshaling)
- **GUI 冒烟**:全自主闭环(tmux CLI 注入 + `/usr/bin/log` stream)覆盖 ⌘T/四向分屏/rename/批量关;大粘贴 literal vs hex 耗时对比;收尾用户在场交互清单
- 全程基线:Zig tmux filter(当前 214)只增不减;GhosttyTests 全绿;lib 构建 0 错

## 实施顺序建议(供 writing-plans)

1. ABI 扩展 + formatCommand 新 case + R2 构造器(纯管道,无行为变化)
2. F1 反向新建(管道首个消费者,冒烟即时可感)
3. F2 反向焦点(viewer 解析 + Swift 应用 + 抑制;与 F1 冒烟联动)
4. F3 rename(小,复用管道)
5. R3+F4 编码器(独立于 1-4,可并行)
6. R1+F5 批量关闭(依赖 R2;TmuxTabGuard 退役)
7. 全量回归 + 自动化 GUI 冒烟 + 用户在场清单

## 参考

- iTerm2 @ `88af3edcc`:TmuxGateway.m(按键编码/通知)、TmuxController.m(命令形态/转义/抑制标志)。本地克隆已清,实施时 `git clone --depth 1 https://github.com/gnachman/iTerm2` 到 scratchpad
- 我们侧:`src/termio/TmuxRouter.zig`(formatCommand)、`src/termio/TmuxPane.zig`(queueWrite)、`src/terminal/tmux/viewer.zig`(通知解析)、`macos/Sources/Features/Tmux/`(Swift 层)
- 流程台账:`.superpowers/sdd/progress.md`
