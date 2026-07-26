# Ghostty tmux 控制模式(tmux -CC)macOS 原生集成 · 设计文档

日期:2026-07-26
状态:已获用户批准的设计,待制定实现计划

## 1. 目标与范围

让 `tmux -CC attach` 在 Ghostty macOS 中获得与 iTerm2 同类的原生体验:

- tmux window → Ghostty 原生标签页(attach 时新开一个专属窗口组)
- tmux pane → Ghostty 原生分屏(SplitTree)
- MVP 档位:**可用的交互终端**
  - attach 后窗口/分屏正确呈现,含历史与可见内容
  - 内容实时同步(`%output`)
  - 键盘输入(`send-keys`)
  - 尺寸同步(`refresh-client -C`,layout 回流重排)
  - tmux 侧变化(新建/关闭/分屏)实时反映到 UI
  - 原生"关闭"操作映射(kill-pane / kill-window / detach)
  - detach 与 `%exit` 优雅退出

### 本期明确不做(二期)

- 新建 window/split 的反向映射(`new-window` / `split-window`)
- 分屏拖拽 resize(`resize-pane`)
- 会话选择器 UI、剪贴板/鼠标高级集成
- GTK(Linux)端 UI(核心层全部共享,GTK 只需补 UI 层)
- 运行时配置项(现有构建开关 `tmux_control_mode` 已够用)

### 成功标准

在 Ghostty 中对本机或 SSH 远端运行 `tmux -CC attach`,tmux 窗口以原生标签页
呈现、pane 以原生分屏呈现,打字、resize、tmux 侧结构变化实时同步,关闭操作
行为符合 tmux 心智(关专属窗口 = detach,会话保留)。

## 2. 现状基础(已存在的代码)

协议层已基本完成(约 4300 行,上游 2025 年 12 月的工作):

| 模块 | 状态 |
|------|------|
| `src/terminal/dcs.zig` | `DCS 1000p` 进入/退出检测,构建开关门控 |
| `src/terminal/tmux/control.zig` | 控制模式通知解析(`%output`、`%layout-change` 等) |
| `src/terminal/tmux/layout.zig` | layout 字符串解析 |
| `src/terminal/tmux/output.zig` | 输出解析 |
| `src/terminal/tmux/viewer.zig` | 状态机:连接、版本协商、list-windows、capture-pane 抓取历史/可见区;每个 Pane 持有完整 Ghostty `Terminal` |
| `src/termio/stream_handler.zig` | 创建/销毁 Viewer、转发通知、处理 `.command` action;**`.windows` action 是 TODO(本设计的起点)** |

缺失的是 UI 集成层:Viewer 状态 → GUI、pane 渲染、输入路由、原生操作映射。

## 3. 架构方案(已选定:方案 A)

每个 tmux pane 是**真正的原生 Surface**,termio 后端用新的 `TmuxPane`
(与 `Exec` 并列),无子进程、无 pty。理由:

- 完全复用现有 Surface 架构:渲染、滚动、选择、搜索、字体缩放免费获得
- 锁模型不变:每个渲染器锁自己的终端
- 上游 Viewer 的 action 设计(emit `.windows` 让调用者 diff)正是朝此方向铺路
- 核心层跨平台,GTK 二期可复用

否决的备选:
- 方案 B(Viewer 持有一切、渲染器只读共享):N 个渲染器共享一把锁,pane
  生命周期悬垂风险高,长期技术债
- 方案 C(单 Surface 合成渲染):得不到原生标签页/分屏,失去意义

### 角色分工

- **宿主 Surface**:用户运行 `tmux -CC attach` 的 surface,其 pty 是与
  tmux 服务器的唯一信道。attach 期间保持存在但静默(显示控制模式提示)。
- **Viewer**(现有,宿主 IO 线程):协议状态机 + 命令队列。
- **apprt `.tmux` action**(新):结构变化上报 GUI(attach / windows / exit)。
  pane 输出字节**不走**此路径。
- **macOS `TmuxSessionController`**(新,Swift):专属窗口组管理、windows
  diff → 标签页、layout → SplitTree、pane surface 创建/销毁。
- **pane Surface**:原生 Surface + `TmuxPane` 后端。

### 数据流

输出方向(tmux → 屏幕):

```
pty 字节 → 宿主 IO 线程 → DCS/ControlParser → Viewer
  ├─ 结构变化(.windows)→ 宿主 surface 邮箱 → apprt action → Swift diff
  │    → 建/删标签页与 pane surface
  └─ %output → 路由表(pane_id → pane termio 邮箱)→ pane 终端状态机 → 渲染
```

输入方向(键盘 → tmux):

```
pane 键入 → TmuxPane 后端 → send-keys -t %<id> -H … → 宿主邮箱
  → Viewer 命令队列(维持 %begin/%end 配对)→ 写入真实 pty
```

resize:原生窗口 resize → `refresh-client -C <w>x<h>` → tmux 重算布局 →
`%layout-change` 回流 → 重排 SplitTree。应用 tmux 布局导致的 pane resize
**不再**反向发命令,避免回环。

### pane Terminal 所有权交接

1. `loading`:pane surface 尚未创建/注册,Viewer 持有 Terminal,自行消化
   capture-pane 初始内容与后续 `%output`,无数据丢失。
2. `attached`:pane surface 注册后,Terminal 经邮箱消息**转移所有权**给
   pane surface(消息传递即同步点),surface 在自己渲染锁内替换默认终端;
   此后 Viewer 对该 pane 只发 `.pane_output` action,由 stream_handler 路由。

## 4. 组件明细

### Zig 核心

**① `src/termio/TmuxPane.zig`(新後端)**
- 配置:宿主 termio 邮箱引用 + pane id
- `queueWrite` → 包装 `send-keys -t %<id> -H …` 投递宿主邮箱
- `threadEnter` → 发注册消息;收到回传 `*Terminal` 后在渲染锁内接管
- `resize` → 不发命令(pane 尺寸由 layout 决定)
- 进程信息 / 异常退出等回调 → 空实现
- `termio.backend.Kind/Config/Backend/ThreadData` 各 union 加 `tmux_pane` 变体

**② `src/terminal/tmux/viewer.zig` 扩展**
- `Pane` 状态:`loading` → `attached`
- 新 `Action.pane_output: { pane_id, data }`(attached pane 的 `%output`)
- 新 `Input.send_command`:外部命令统一入命令队列
- `Window.name` 字段:`list-windows` 格式扩展 + `%window-renamed` 处理

**③ `src/termio/stream_handler.zig`(实现 TODO)**
- 路由表 `pane_id → pane termio 邮箱`;注册/反注册消息处理
- `.windows` → 序列化(扁平数组表示 layout 树)→ apprt action
- `.pane_output` → 查表投递字节

**④ apprt / C API**
- `apprt.Action` 新增 `.tmux`:`attach`(宿主标识)、`windows`(窗口+布局
  扁平数组)、`exit`
- `ghostty_surface_config_s` 新增 tmux pane 字段(宿主 surface 指针 +
  pane id);`Surface.init` 见到即用 `TmuxPane` 后端并跳过 shell 集成
- 新 C 函数 `ghostty_surface_tmux_command(host, cmd)`:类型化枚举
  (`kill_window(id)` / `kill_pane(id)` / `detach` / `select_pane(id)`),
  命令字符串拼接留在 Zig 侧
- 若在 C 头文件中新增枚举,遵守项目规则:最后一项加
  `_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE` 哨兵

### macOS Swift 层

**⑤ `TmuxSessionController`(新)**
- `attach` → 开专属窗口组;`windows` → 按 id diff(tmux 保证 id 稳定
  不复用)→ 增/删/改标签页(每个标签 = 加入 tab group 的
  `TerminalController`)
- layout → `SplitTree` 转换为**纯函数**(可单测)
- pane surface 复用现有 `SurfaceView`,surface 配置带 tmux 字段
- 标签标题 = tmux window 名;焦点变化 → `select_pane`(fire-and-forget)

**⑥ 原生操作映射(MVP 最小反向控制)**
- 关闭 pane → `kill-pane`(复用现有关闭确认)
- 关闭标签页 → `kill-window`
- 关闭专属窗口 → `detach-client`(会话保留)
- tmux 窗口内的新建标签/分屏 → 忽略并提示(二期映射)

纳入"关闭"的理由:不做会出现关不掉的窗口或状态错乱,是可用性底线;
"新建"缺失只是少功能。

## 5. 错误处理与边界情况

- **竞态**:pane 注册时已被 tmux 删除 → 宿主回复"已失效",surface 显示
  关闭并请求 GUI 销毁。diff 一律以 Viewer 状态为准,GUI 是从属方。
- **宿主关闭**:pty 断开 → Viewer 销毁 → `tmux exit` action → GUI 关闭
  全部 tmux 标签页。pane 关闭必须经宿主邮箱反注册,杜绝悬垂路由。
- **`%exit` / detach**:Viewer defunct → `exit` action → GUI 收尾;宿主
  回到普通终端(DCS 退出路径已存在)。
- **版本门槛**:最低 tmux 3.2;更低版本 → 主动 detach 并在宿主终端打印
  原因,不进入半残状态。
- **`%error`**:fire-and-forget 命令失败记日志;影响状态的失败(如初始
  `list-windows`)→ defunct 流程。
- **背压**:大量粘贴时 `send-keys` 按块拆分;上限保护记日志截断。

## 6. 测试策略

- **Zig 单测**(`zig build test -Dtest-filter=…`):Viewer 新状态转换
  (loading→attached、pane_output 路由、send_command 入队)、TmuxPane
  后端(mock 邮箱验证 send-keys 封装)、layout 序列化往返。
- **回放测试**:录制真实 `tmux -CC` 字节流,喂给 DCS→Viewer 全链路,
  断言 action 序列(扩展 viewer.zig 现有测试基建:attach、分屏、关窗、
  detach、乱序场景)。
- **Swift 单测**:layout→SplitTree 转换、windows diff 两个纯函数。
- **手动冒烟**:本机 tmux、SSH 远端、双客户端同时 attach(普通 tmux +
  Ghostty -CC)互相观察同步、iTerm2 对照。

## 7. 实施顺序(每步独立可验证)

1. **管道打通**:apprt `.tmux` action + C API 序列化,macOS 先只打日志
   ——验证 windows 列表从 pty 一路到 Swift。
2. **单 pane 渲染**:TmuxPane 后端 + 注册/接管/输出路由——单窗口单 pane
   会话能看能打字。
3. **完整 UI**:`TmuxSessionController` + 标签页 diff + SplitTree + 标题。
4. **交互闭环**:resize、焦点同步、关闭映射、detach 收尾。
5. **加固**:版本检查、竞态处理、回放测试补全、错误路径。
