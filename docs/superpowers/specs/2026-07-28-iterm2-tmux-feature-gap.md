# iTerm2 tmux -CC 功能差距分析

日期:2026-07-28。基线:我们 `tmux-cc-core` @ `4ba7d05f7`;iTerm2 master @ `88af3edcc`(2026-07-26)。
方法:三个并行探索代理逐层通读 iTerm2 源码(协议层 / 会话管理层 / 用户功能层),与我们的实现逐项对照(`src/terminal/tmux/`、`src/termio/TmuxRouter.zig`、`macos/Sources/Features/Tmux/`)。iTerm2 的 file:line 引用均相对其仓库根。

## 总体结论

我们实现的是**核心渲染管道 + 基本窗口生命周期**;iTerm2 是十几年积累的全功能集成。主干道(attach → 原生标签/分屏 → tmux 侧增删改回流 → 输入输出 → 关闭语义)已对齐。差距集中三块:

1. **GUI→tmux 反向操作**(新建窗口/分屏/改名)——交互断层最明显;
2. **吞吐与流控**(大粘贴 hex 膨胀、无 pause 流控);
3. **周边生态**(Dashboard、剪贴板、状态栏、持久化)——不影响主干可用性。

## 我们的现状底账

- **`%` 通知(13 种)**:`%begin` `%end` `%error` `%output` `%exit` `%layout-change` `%window-add` `%window-renamed` `%window-pane-changed`(仅解析,未接 UI)`%session-changed` `%sessions-changed` `%client-detached` `%client-session-changed`。
- **启动序列**:版本门槛(<3.2 → detach+exit)→ list-windows → capture-pane(`-e`,含全量历史 `-S -`+可见屏)→ list-panes 状态(光标等)。
- **GUI→tmux 命令(5 种,TmuxRouter.formatCommand)**:`kill-pane` `kill-window` `detach-client` `select-pane` `refresh-client -C WxH`。
- **输入**:`send-keys -H`(纯 hex),64 字节块。
- **无显式 `%window-close` 解析**:窗口关闭靠通知触发的 list-windows 全量重同步覆盖(冒烟已验证行为正确,代价是每次多一轮往返)。

## 一、协议层差距

| 能力 | iTerm2 | 我们 | 评估 |
|---|---|---|---|
| `%` 通知覆盖 | ~20 种(TmuxGateway.m:263-866) | 13 种 | 见下 |
| `%begin/%end/%error` 命令队列 | ✅ ID 匹配+批量失败传播+5s 超时提示 detach | ✅ | 对齐 |
| `%output` 八进制解码 | ✅(TmuxGateway.m:147-177) | ✅ | 对齐 |
| `%exit` | ✅ 含 tmux 1.8 bug 绕过 | ✅ 幂等(双触发只发一次) | 对齐 |
| `%extended-output`(带延迟,3.2+) | ✅ 流控数据源(TmuxGateway.m:179-256) | ❌ | 流控前置 |
| `%pause`/`%continue` 流控 | ✅ `refresh-client -fpause-after=N` + 缓冲监视线性回归预测(iTermTmuxBufferSizeMonitor.m)+ 暂停 UI | ❌ | 大输出无保护 |
| `%window-close`/`%unlinked-*` | ✅ 显式(TmuxGateway.m:370-378) | ❌(重同步覆盖) | 行为等价,多一轮往返 |
| `%session-renamed` | ✅ | ❌ | 小 |
| `%session-window-changed` | ✅ → 反向焦点 | ❌ | 反向焦点另一半 |
| `%paste-buffer-changed` | ✅(限 `buffer[0-9]+` 防注入) | ❌ | 剪贴板前置 |
| `%subscription-changed`(3.2+) | ✅ `refresh-client -B` 订阅机制 | ❌ | 状态栏/标题前置 |
| `%pane-mode-changed` / `%noop` | 显式忽略 | 未知通知路径忽略 | 等价 |
| 按键编码 | 三级(TmuxGateway.m:937-1025):ASCII→literal(单块 1000 字符)、非 ASCII→hex(~125 码点/块)、C0→`send -H`(3.0a+);批量 sendCommandList | 纯 hex + 64B 块 | **大粘贴慢**(backlog 已有) |
| 版本策略 | 1.8+ 全兼容,십几个版本逐级降级(TmuxController.m:1455-1599) | 一刀切 ≥3.2 | 设计取舍:省掉大半版本分支;PR 披露即可 |
| 版本探测 | `display-message -p "#{version}"` + 多级回退,字母后缀 2.9a→2.91 | 同命令;parseVersion 溢出保护待补(终审 backlog) | 基本对齐 |

## 二、会话/窗口管理层差距

| 能力 | iTerm2 | 我们 | 评估 |
|---|---|---|---|
| attach 布局解析→原生分屏 | ✅ TmuxLayoutParser 递归下降+同向合并 | ✅ TmuxSplitLayout n 叉折叠二叉 | 对齐 |
| 历史恢复 | ✅ `capture-pane -peqJN -S -N` 主屏+备用屏(`-a`) | ✅ 主屏历史+可见屏;无备用屏 | 小差距 |
| 状态恢复(list-panes 格式) | ✅ 光标+滚动区+tabstops+鼠标模式+括号粘贴+DECTCEM 等(TmuxStateParser.m:85-104) | 🟡 光标等基本状态 | 小差距 |
| tmux→GUI 布局/增/改名回流 | ✅ 树比较,匹配则只 resize | ✅ signature 比较跳过无变化重建 | 对齐 |
| tmux→GUI 焦点回流 | ✅ `%window-pane-changed`+`%session-window-changed`→原生焦点,`_suppressActivityChanges` 防回环 | ❌(前者已解析未接 UI) | **A 级** |
| GUI→tmux 新建窗口 | ✅ `new-window`(含 affinity、初始目录) | ❌ | **A 级,最大交互缺口** |
| GUI→tmux 分屏 | ✅ `split-window`,前后 list-panes diff 取新 pane id(TmuxController.m:1912-1985) | ❌ | **A 级** |
| GUI→tmux 改名 | ✅ `rename-window`(转义反斜杠/去换行) | ❌ | A 级 |
| GUI→tmux 关闭语义 | ✅ | ✅ 关标签→确认→kill-window;红点→detach;关 pane→确认→kill-pane;批量关禁用 | 对齐(批量关是禁用而非映射,PR 披露) |
| pane 拖动重排 → `move-pane` | ✅ | ❌ | 低 |
| resize | ✅ `refresh-client -C`;另支持 2.9+ 每窗口独立尺寸(`-C @win:WxH`)与多窗取最小 | ✅ 客户端级,防抖 0.1s+会话级去重 | 起步够用 |
| 位置/affinity/隐藏窗口持久化 | ✅ 存 tmux 会话变量 `@origins`/`@affinities`/`@hidden`(TmuxController.m:2582-2705) | ❌ | C 级 |
| 多会话并发 | ✅ TmuxControllerRegistry 按客户端 | ✅ TmuxSessionManager 按宿主 ObjectIdentifier(双客户端冒烟验证) | 对齐 |
| pane 进程壳 | 只读 JobManager(fd=-1,进程在 tmux 侧) | SurfaceConfiguration.tmuxRouter/tmuxPaneId 后端 | 思路等价 |

## 三、用户功能层差距(iTerm2 有、我们全无)

- **Dashboard**(TmuxDashboardController):会话表(增/删/改名/attach/detach)+ 窗口表(增/删/改名/隐藏/开成 tab 或 window)+ 多连接切换。
- **菜单栏 Shell>tmux 子菜单**:Detach、Force Detach、New Tmux Window(⌃⌘N)、New Tmux Tab(⌃⌘T)、Pause Pane、Dashboard。我们只有关闭映射+菜单禁用。
- **9 项偏好**:窗口开成 window/tab、自动隐藏 client 会话、专用 profile、状态栏镜像、暂停阈值/自动恢复/暂停前警告、剪贴板同步、隐藏窗口时自动开 Dashboard。
- **状态栏镜像**:订阅 `#{T:status-left/right}` 进原生状态栏(3.2+ 订阅,2.9+ 轮询回退)。
- **剪贴板同步**:`%paste-buffer-changed` → `show-buffer` → NSPasteboard(偏好开关,默认关)。
- **暂停 UX**:pane 内横幅"已暂停"+ Resume 按钮 + 自动恢复选项。
- **掩埋窗口 / 每窗口字体与 profile 记忆 / OSC 4/52 多客户端委托(3.6+,iTermTmuxClientTracker)/ 布局预设右键菜单(even-horizontal 等)/ tmux 变量体系**。

## 补全分级与建议

**A 级(影响日常可用,建议作为计划三)**:
1. GUI 反向新建:新标签→`new-window`、分屏→`split-window`(借鉴 pane-diff 取 id);
2. send-keys 吞吐:literal 快路径+大块分片(照抄 iTerm2 三级编码,我们 ≥3.2 可无条件用 `send -H`);
3. 反向焦点:补 `%session-window-changed`,把 `%window-pane-changed` 接到原生焦点,加抑制标志防回环;
4. rename 双向:GUI 改名→`rename-window`。

**B 级(明显加分,规模适中)**:pause 流控(我们 3.2+ 门槛使其零版本分支,比 iTerm2 好做)、剪贴板同步、`%window-close` 显式处理(省一轮 list-windows)、备用屏历史恢复。

**C 级(重量级生态,后置)**:Dashboard、隐藏/掩埋窗口+位置持久化、状态栏镜像+订阅、每窗口 profile、OSC 委托、`move-pane` 重排。

**路线建议**:10 项人工冒烟 → 计划三补 A 级(规模约计划二的 1/3)→ 上游 PR。A1 是评审者第一个会试的操作;其余缺口在 PR 描述里披露为 roadmap(与既有披露口径合并)。

## 参考

- iTerm2 源码:https://github.com/gnachman/iTerm2 @ `88af3edcc`;本地浅克隆(临时):`/private/tmp/claude-501/-Users-zouchaoxu-Desktop-ghostty/1b3b4398-e73d-4b4b-9e68-7b28da6f38ed/scratchpad/iTerm2`
- 关键文件:TmuxGateway.m(协议)、TmuxController.m(命令/版本/流控)、TmuxWindowOpener.m + TmuxLayout/History/StateParser.m(attach 恢复)、iTermTmuxBufferSizeMonitor.m(流控)、TmuxDashboardController.m(UI)、iTermTmuxClientTracker.swift(OSC 委托)
- 我们侧:`docs/superpowers/handoff/2026-07-27-plan2-complete.md`(现状与既有 backlog)
