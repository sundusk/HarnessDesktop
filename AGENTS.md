# DeepSeek Harness for macOS — 开发规格文档

> 工作名称：`DeepSeek Harness`
>
> 项目定位：DeepSeek Harness 的 **macOS 原生客户端 / 宿主**，不是 DeepSeek Harness 的二次发行版。
>
> 上游项目：<https://github.com/deepseek-ai/deepseek-harness>
>
> 本文档用于直接交给 Codex 执行开发。除非本文明确允许，否则不要自行扩大产品边界。

---

## 0. 给 Codex 的最高优先级指令

实现本项目时，必须始终遵守以下三条架构原则：

1. **Attach First**
   - 优先连接用户已经运行的 DeepSeek Harness。
   - 第一阶段只支持连接，不负责启动、安装或管理 Harness。

2. **Zero Mutation**
   - 应用不得修改用户的 DeepSeek Harness 环境。
   - 不得写入、删除、迁移、修复或重建 `~/.dsh`、`$DSH_HOME`、Profile、插件、patch、`node_modules` 等任何 Harness 数据。
   - 不得执行 `npm install`、`pnpm install`、`dsh plugin ...` 等会修改 Harness 环境的命令。

3. **Web Core + Native Enhancement**
   - 官方 DeepSeek Harness Web UI 是核心功能和兼容层。
   - macOS Native API、菜单栏、通知、悬浮状态球等属于增强功能。
   - Native 增强层发生兼容问题时，必须优雅降级，不能导致主 Web UI 不可用。

### 绝对禁止

Codex 不得为了“更方便”或“更完整”擅自加入以下内容：

- 不得 fork、vendor、复制或内嵌完整 DeepSeek Harness Runtime。
- 不得打包 Node.js。
- 不得打包 npm / pnpm。
- 不得内置或固定某个 DeepSeek Harness 版本。
- 不得自动执行 `npx @deepseek-ai/dsh@latest web`。
- 不得自动升级用户 Harness。
- 不得安装、更新或卸载 Harness 插件。
- 不得修改 Harness Profile。
- 不得创建自己的 DeepSeek Harness 插件。
- 不得注入或 monkey patch 官方 Web UI 的 JavaScript Runtime。
- 不得通过 DOM class、CSS selector 或 UI 文本判断 Harness 任务状态。
- 不得使用 Electron。
- 不得使用 Tauri。
- 第一阶段不得启动或 kill 用户的 Harness 进程。
- 第一阶段不得支持局域网或公网 Harness。

如果某功能必须违反以上任一原则才能实现，**本阶段直接不实现该功能**。

---

# 1. 项目目标

开发一个原生 macOS 应用，为已经安装并运行 DeepSeek Harness 的用户提供桌面体验。

用户典型流程：

```text
Terminal
    ↓
npx @deepseek-ai/dsh web
    ↓
DeepSeek Harness
    ↓
http://127.0.0.1:3080
    ↑
    │
DeepSeek Harness
```

应用启动后：

1. 自动检测 `http://127.0.0.1:3080`。
2. 如果检测到 Harness：
   - 连接现有实例；
   - 在 `WKWebView` 中加载官方 Harness Web UI。
3. 如果未检测到 Harness：
   - 显示“DeepSeek Harness 未运行”状态页；
   - 提供可复制的启动命令；
   - 不自动运行命令。
4. 在后续阶段，通过 Harness 当前公开的 HTTP / WebSocket 接口读取任务状态。
5. 将任务状态映射到：
   - Menu Bar；
   - macOS 通知；
   - Dock 状态；
   - 悬浮桌面状态球 / Desktop Pet。

---

# 2. 项目非目标

以下内容不是 V1 的目标：

- 重写 Harness 聊天 UI。
- 重写 Session / Workspace / Settings / Plugin 页面。
- 开发自己的 Agent Runtime。
- 开发自己的模型层。
- 替代 Harness Web UI。
- 管理 Harness Plugin。
- 管理 Harness Profile。
- 管理 Node 环境。
- 管理 pnpm。
- 管理 npm。
- 管理 Harness 版本。
- 远程控制另一台电脑上的 Harness。
- 手机远程控制。
- 多机同步。
- Harness 插件市场。
- Managed Harness Runtime。

核心思想：

> Harness 负责 Harness；macOS App 只负责 macOS 桌面体验。

---

# 3. 技术栈

优先使用 Apple 原生技术，不增加第三方依赖，除非确实无法合理实现。

## 3.1 主技术

- Swift
- SwiftUI
- AppKit
- WebKit / `WKWebView`
- Foundation
- `URLSession`
- `URLSessionWebSocketTask`
- Swift Concurrency
- Observation / `@Observable`
- UserNotifications
- OSLog / `Logger`

## 3.2 系统要求

默认：

```text
Deployment Target: macOS 14.0+
Architecture: Apple Silicon + Intel
```

要求：

- 不得无理由只支持最新 macOS。
- 如果某个 API 必须提升 Deployment Target，先寻找兼容实现。
- 保持代码可在当前稳定 Xcode / Swift 工具链中构建。

## 3.3 第三方依赖政策

默认：

```text
Third-party dependency count = 0
```

如果确实需要第三方库：

1. 先确认 Apple 原生 API 无法合理解决。
2. 在 PR / commit 中说明引入原因。
3. 不得为了 JSON、网络、日志、状态管理等已有系统能力引入依赖。
4. 禁止引入任何 Node / JS Runtime 依赖。

---

# 4. 总体架构

```text
┌────────────────────────────────────────────┐
│              DeepSeek Harness                │
│                                            │
│ ┌────────────────────────────────────────┐ │
│ │ Presentation                           │ │
│ │                                        │ │
│ │ MainWindow                             │ │
│ │ MenuBar                                │ │
│ │ Notifications                          │ │
│ │ FloatingPet                            │ │
│ └──────────────────┬─────────────────────┘ │
│                    │                       │
│ ┌──────────────────▼─────────────────────┐ │
│ │ Domain                                 │ │
│ │                                        │ │
│ │ HarnessConnectionState                 │ │
│ │ HarnessActivityState                   │ │
│ │ SessionRuntimeState                    │ │
│ │ ActivityReducer                        │ │
│ └──────────────────┬─────────────────────┘ │
│                    │                       │
│ ┌──────────────────▼─────────────────────┐ │
│ │ Harness Integration                    │ │
│ │                                        │ │
│ │ HarnessDiscovery                       │ │
│ │ HarnessWebSurface                      │ │
│ │ HarnessTransport                       │ │
│ │ HarnessProtocolAdapter                 │ │
│ │ CompatibilityResolver                  │ │
│ └──────────────┬──────────────┬──────────┘ │
│                │              │            │
│              HTTP/WS       WKWebView       │
└────────────────┼──────────────┼────────────┘
                 │              │
                 ▼              ▼
        ┌───────────────────────────────┐
        │       DeepSeek Harness        │
        │                               │
        │ http://127.0.0.1:3080         │
        │                               │
        │ /                             │
        │ /api                          │
        │ /api/events.mux               │
        │ /api/events.host              │
        └───────────────┬───────────────┘
                        │
                        ▼
                     ~/.dsh

        DeepSeek Harness 不得写入此处
```

---

# 5. 故障模型

必须按照以下故障模型设计。

## 5.1 Web UI 是核心

如果：

```text
Native Harness API 不兼容
```

允许：

```text
Menu Bar 状态不可用
通知不可用
Pet 高级状态不可用
```

但是：

```text
WKWebView 官方 Harness UI 必须仍然可以使用
```

## 5.2 不允许单点耦合

禁止：

```text
Native API 连接失败
    ↓
整个 App 拒绝打开
```

必须：

```text
Native API 连接失败
    ↓
进入 Compatibility / Degraded Mode
    ↓
继续显示官方 Web UI
```

这叫：

> Graceful Degradation

---

# 6. 工程目录建议

建议按以下结构创建工程：

```text
DeepSeek Harness/
├── DeepSeek Harness.xcodeproj
├── DeepSeek Harness/
│   ├── App/
│   │   ├── DeepSeek HarnessApp.swift
│   │   ├── AppCoordinator.swift
│   │   └── AppEnvironment.swift
│   │
│   ├── Domain/
│   │   ├── HarnessEndpoint.swift
│   │   ├── HarnessConnectionState.swift
│   │   ├── HarnessActivityState.swift
│   │   ├── SessionRuntimeState.swift
│   │   ├── HarnessSnapshot.swift
│   │   └── ActivityReducer.swift
│   │
│   ├── Harness/
│   │   ├── Discovery/
│   │   │   ├── HarnessDiscovering.swift
│   │   │   └── LocalHarnessDiscovery.swift
│   │   │
│   │   ├── Web/
│   │   │   ├── HarnessWebView.swift
│   │   │   ├── HarnessWebViewModel.swift
│   │   │   └── HarnessNavigationPolicy.swift
│   │   │
│   │   ├── Transport/
│   │   │   ├── HarnessTransporting.swift
│   │   │   ├── HarnessHTTPTransport.swift
│   │   │   ├── HarnessWebSocketTransport.swift
│   │   │   └── HarnessConnectionController.swift
│   │   │
│   │   └── Compatibility/
│   │       ├── HarnessProtocolAdapter.swift
│   │       ├── HarnessGenericAdapter.swift
│   │       ├── HarnessCompatibilityResolver.swift
│   │       └── HarnessProtocolModels.swift
│   │
│   ├── Desktop/
│   │   ├── Window/
│   │   │   ├── MainWindowCoordinator.swift
│   │   │   └── MainWindowView.swift
│   │   │
│   │   ├── MenuBar/
│   │   │   └── MenuBarCoordinator.swift
│   │   │
│   │   ├── Notifications/
│   │   │   └── NotificationCoordinator.swift
│   │   │
│   │   ├── Pet/
│   │   │   ├── FloatingPetCoordinator.swift
│   │   │   ├── FloatingPetView.swift
│   │   │   └── PetPresentationState.swift
│   │   │
│   │   └── Dock/
│   │       └── DockCoordinator.swift
│   │
│   ├── Infrastructure/
│   │   ├── Settings/
│   │   │   ├── AppSettings.swift
│   │   │   └── SettingsStore.swift
│   │   ├── Logging/
│   │   │   └── AppLogger.swift
│   │   └── Diagnostics/
│   │       └── DiagnosticsSnapshot.swift
│   │
│   └── Resources/
│
├── DeepSeek HarnessTests/
├── DeepSeek HarnessUITests/
├── README.md
├── ARCHITECTURE.md
├── AGENTS.md
└── DEVELOPMENT.md
```

不要为了“Clean Architecture”继续增加没有价值的层级。

---

# 7. Domain 模型

## 7.1 HarnessEndpoint

```swift
struct HarnessEndpoint: Equatable, Sendable {
    let baseURL: URL
}
```

默认：

```text
http://127.0.0.1:3080
```

V1 只允许 loopback：

- `127.0.0.1`
- `localhost`
- `::1`

用户可以修改端口，但不能输入公网地址。

---

## 7.2 HarnessConnectionState

建议：

```swift
enum HarnessConnectionState: Equatable, Sendable {
    case unknown
    case discovering
    case unavailable
    case connecting
    case connected
    case reconnecting
    case degraded(reason: String)
}
```

要求：

- UI 不直接推断网络状态。
- 连接状态只由 Integration 层输出。

---

## 7.3 HarnessActivityState

建议：

```swift
enum HarnessActivityState: Equatable, Sendable {
    case disconnected
    case idle
    case running
    case waitingForInput
    case waitingForApproval
    case error(message: String?)
}
```

`completed` 不建议作为长期全局状态。

任务完成应作为 transient event：

```swift
struct HarnessCompletionEvent: Sendable {
    let sessionID: String
    let timestamp: Date
}
```

UI 可以短暂播放完成动画，然后回到 `idle`。

---

## 7.4 SessionRuntimeState

多 Session 必须从第一天考虑。

```swift
struct SessionRuntimeState: Equatable, Sendable {
    let id: String

    var isRunning: Bool
    var pendingApprovalCount: Int
    var pendingQuestionCount: Int
    var lastError: String?
    var lastUpdatedAt: Date
}
```

禁止使用单一：

```swift
var isRunning: Bool
```

代表整个 Harness。

---

# 8. 全局状态优先级

当多个 Session 同时存在时：

```text
Error
  >
Waiting For Approval
  >
Waiting For Input
  >
Running
  >
Idle
```

规则：

1. 连接不存在：
   - `disconnected`
2. 任一 Session 有错误：
   - `error`
3. 任一 Session 等待 Approval：
   - `waitingForApproval`
4. 任一 Session 等待用户回答：
   - `waitingForInput`
5. 任一 Session 正在运行：
   - `running`
6. 否则：
   - `idle`

实现到：

```text
ActivityReducer
```

Presentation 层禁止自己实现状态优先级。

---

# 9. ActivityReducer

职责：

```text
Harness Event
    ↓
ActivityReducer
    ↓
SessionRuntimeState[]
    ↓
HarnessActivityState
```

所有 UI：

```text
MenuBar
Notification
Dock
FloatingPet
```

只能依赖：

```text
HarnessActivityState
```

不得直接依赖：

```text
MuxFrame
HostFrame
SessionEvent
```

这样可以将 Harness 协议变化限制在 Compatibility 层。

---

# 10. Harness Discovery

## 10.1 协议

```swift
protocol HarnessDiscovering: Sendable {
    func discover() async -> HarnessEndpoint?
}
```

## 10.2 V0.1 实现

默认检测：

```text
http://127.0.0.1:3080
```

检测方式：

- 使用短超时 HTTP 请求；
- 成功返回 2xx / 3xx 即认为 Web 服务存在；
- 必须防止请求长期挂起；
- 不扫描本机进程；
- 不读取 shell；
- 不读取 `~/.dsh`；
- 不扫描 Node；
- 不执行 `which dsh`；
- 不执行终端命令。

建议超时：

```text
1 ~ 2 秒
```

不要高频轮询。

---

# 11. Harness 未启动页面

如果没有发现 Harness：

显示 Native SwiftUI 页面：

```text
DeepSeek Harness 未运行

请先在终端运行：

npx @deepseek-ai/dsh web

[复制命令]
[重新检测]
```

要求：

- “复制命令”只复制文本。
- 不自动打开 Terminal 执行。
- 不自动安装任何东西。
- “重新检测”只重新请求 localhost。

---

# 12. WKWebView 方案

## 12.1 核心原则

直接加载：

```text
http://127.0.0.1:3080/
```

不要：

```text
file://local/index.html
```

不要自己做中间 Web 前端。

原因：

- 保持 Harness 页面和 `/api` 同源；
- 最大限度兼容官方插件和皮肤；
- 官方 Web UI 升级后无需同步重写；
- 避免自己维护前端协议。

---

## 12.2 WebView 职责

`HarnessWebView` 只负责：

- 加载页面；
- reload；
- 页面加载状态；
-错误页；
-导航控制；
- 外部链接处理。

不得：

- 注入状态监听 JavaScript；
- 修改 Harness DOM；
- 改 CSS；
- hook `window.WebSocket`；
- hook `fetch`；
-读取页面 DOM 推断状态。

---

## 12.3 导航策略

以下地址可在 WebView 内：

```text
当前 Harness loopback origin
```

例如：

```text
http://127.0.0.1:3080/...
```

以下地址默认交给：

```swift
NSWorkspace.shared.open(...)
```

例如：

- GitHub
- DeepSeek 官网
- 文档站
- 任意外部 HTTP/HTTPS 地址

避免 DeepSeek Harness 变成通用浏览器。

---

## 12.4 WebView 数据存储

优先使用持久化 `WKWebsiteDataStore.default()`，确保 Harness Web UI 自己的合法浏览器状态能够保留。

不要擅自清空：

- Cookie
- LocalStorage
- IndexedDB
- Cache

如果以后增加“清理 Web 数据”功能，必须显式提示用户。

---

# 13. App Sandbox 与网络安全

V1 建议启用：

```text
App Sandbox
```

需要最小 entitlement：

```text
com.apple.security.network.client = true
```

对于 localhost HTTP：

- 优先使用最小化 ATS 配置；
- 可配置 `NSAllowsLocalNetworking`；
- 不允许使用 `NSAllowsArbitraryLoads = true` 作为偷懒方案。

目标：

> 应用从权限模型上就没有理由修改 `~/.dsh`。

V1 不请求：

- Downloads 全盘权限；
- Home Directory 全盘权限；
- Full Disk Access；
- Automation；
- Apple Events；
- Terminal 控制权限。

---

# 14. Native Harness API

Native API 属于增强层，不属于 V0.1 必需项。

实现顺序：

```text
host.describe
    ↓
events.host
    ↓
events.mux
```

在真正实现任何 RPC 前：

1. 检查当前官方 `deepseek-harness` 源码中的 wire contract。
2. 确认当前 endpoint、request envelope、response envelope。
3. 不从旧博客、旧 fork 或第三方 Desktop 推断协议。
4. 所有协议细节只能存在于 `HarnessProtocolAdapter` / Transport 层。

---

# 15. Native Transport

使用：

```text
URLSession
URLSessionWebSocketTask
```

不要引入 JS。

抽象：

```swift
protocol HarnessTransporting: Sendable {
    func connect(to endpoint: HarnessEndpoint) async throws
    func disconnect() async
}
```

HTTP 和 WebSocket 可以拆开。

---

# 16. 当前已知 Harness WebSocket

当前 Harness Web Client 使用两个下行 WebSocket：

```text
/api/events.mux
/api/events.host
```

但注意：

> 路径和 schema 都属于可能变化的上游协议。

因此不要让路径散落在代码里。

集中到：

```swift
enum HarnessProtocolPath {
    static let api = "/api"
    static let muxEvents = "/api/events.mux"
    static let hostEvents = "/api/events.host"
}
```

如果以后协议版本化，只修改 Adapter。

---

# 17. `host.describe` 作为 Compatibility Handshake

连接 Native 增强层时优先执行：

```text
host.describe
```

从返回值读取：

- Harness version
- cwd
- provider
- model
- attachedSessions
- capability flags

不要假设所有版本字段永远存在。

Compatibility 流程：

```text
发现 Harness
    ↓
Web UI 可打开
    ↓
尝试 Native handshake
    ↓
成功
    ↓
CompatibilityResolver
    ↓
选择 Adapter
```

如果 handshake 失败：

```text
Web UI 正常
Native Enhancements = disabled
```

进入：

```text
Degraded Mode
```

---

# 18. HarnessProtocolAdapter

必须建立适配层。

```swift
protocol HarnessProtocolAdapter: Sendable {
    var supportedVersionRange: ClosedRange<String>? { get }

    func connect() async throws
    func disconnect() async

    var events: AsyncStream<HarnessDomainEvent> { get }
}
```

不要让上层依赖具体 Harness wire model。

Adapter 输出统一 Domain Event：

```swift
enum HarnessDomainEvent: Sendable {
    case sessionAdded(id: String)
    case sessionRemoved(id: String)
    case sessionRunningChanged(id: String, running: Bool)
    case approvalRequested(sessionID: String)
    case approvalResolved(sessionID: String)
    case questionRequested(sessionID: String)
    case questionResolved(sessionID: String)
    case agentError(sessionID: String, message: String)
    case taskCompleted(sessionID: String)
}
```

---

# 19. JSON 解码兼容原则

Swift `Decodable` 必须遵循：

> Parse what we need, ignore what we do not need.

例如：

```swift
struct SessionStatusFrame: Decodable {
    let type: String
    let sessionId: String
    let running: Bool
}
```

如果官方新增字段：

```json
{
  "type": "host/session-status",
  "sessionId": "abc",
  "running": true,
  "newField": "value"
}
```

仍然必须正常解析。

未知 event：

```text
忽略 + debug log
```

不得：

```text
未知 event
  ↓
关闭整个 WebSocket
```

除非协议本身已完全无法解析。

---

# 20. Connection Controller

参考官方思路，但用 Swift 独立实现。

状态：

```text
connecting
connected
reconnecting
disconnected
```

连接成功条件建议：

```text
host.describe 成功
+
events.host 建立
+
events.mux 建立
```

如果 WebSocket 断开：

```text
500ms
1s
2s
4s
8s
10s
10s
...
```

增加少量 jitter。

要求：

- 网络恢复后自动重连；
- App 前后台切换不崩；
- Harness 重启后能够恢复；
- WebView 和 Native Transport 生命周期互相独立。

---

# 21. Menu Bar

V0.3 后实现。

建议展示：

```text
● Harness

Status: Working
Sessions: 2
Version: x.x.x

Open Harness
Reload
Open in Browser

Quit
```

根据状态改变图标/描述。

Menu Bar 只消费：

```text
HarnessActivityState
```

---

# 22. Notifications

使用：

```text
UNUserNotificationCenter
```

通知场景：

1. `approval/requested`
   - 立即通知。
2. `question/requested`
   - 立即通知。
3. Agent 从 running → idle
   - 可视为任务完成；
   - 需要防止瞬态抖动。
4. error
   - 有意义时通知。

规则：

- 同一 Session 同类事件做 debounce / dedupe。
- 不允许快速状态变化造成通知轰炸。
- 默认不在用户正在前台使用主窗口时反复发送完成通知。
- 日志中不得记录消息正文或敏感 prompt。

---

# 23. Floating Pet / 状态球

该功能属于 Desktop Enhancement。

状态映射建议：

```text
Disconnected       → 灰 / 静止
Idle               → 蓝 / 缓慢呼吸
Running            → 绿 / 流动
WaitingForInput    → 黄
WaitingForApproval → 橙黄 / 更明显提醒
Error              → 红
Completed          → 短暂闪动后回 Idle
```

注意：

- 颜色只是 Presentation。
- Domain 层不应包含颜色。
- 悬浮窗口使用 AppKit `NSPanel`。
- 支持拖拽位置。
- 支持记住位置。
- 不抢键盘焦点。
- 默认可置于普通窗口上方，但不要强制覆盖全屏游戏等所有系统层级。
- 主窗口关闭后，Pet 可独立存在。
- Pet 不通过 WebView DOM 判断状态。

---

# 24. AppKit / SwiftUI 分工

## SwiftUI

负责：

- 启动状态页；
- 设置页；
- 基础菜单内容；
- 状态视图；
- Pet 内容 View。

## AppKit

负责：

- `NSWindow`
- `NSPanel`
- `NSStatusItem`
- 窗口层级
- 窗口位置恢复
- Pet floating window
- Dock / Activation Policy 等 macOS 生命周期细节

## WebKit

负责：

- Harness Web UI。

不要为了“全 SwiftUI”牺牲 macOS 行为稳定性。

---

# 25. AppCoordinator

建议设置单一应用级协调器：

```swift
@MainActor
@Observable
final class AppCoordinator {
    ...
}
```

负责协调：

```text
Discovery
WebView
ConnectionController
ActivityReducer
MenuBar
Notifications
Pet
```

但不要把所有业务逻辑写进 `AppCoordinator`。

它是 orchestration，不是 God Object。

---

# 26. Settings

V1 设置项保持极简：

```text
Harness Address
Harness Port
Launch Main Window at App Start
Enable Notifications
Enable Menu Bar
Enable Floating Pet
```

默认：

```text
host = 127.0.0.1
port = 3080
```

禁止用户配置非 loopback host。

存储：

```text
UserDefaults / AppStorage
```

不需要数据库。

---

# 27. Logging

使用：

```swift
Logger
```

建议 category：

```text
app
discovery
webview
transport
compatibility
activity
notification
pet
```

必须避免记录：

- API Key
- Credential
- Prompt 全文
- Session 对话全文
- 用户文件内容
- Secret settings

日志只记录：

```text
连接状态
版本
错误类型
event type
session ID（必要时可做截断）
```

---

# 28. Diagnostics

提供一个简单诊断视图或 Debug Export：

```text
App Version
macOS Version
Harness Endpoint
Harness Reachable
Harness Version
Native Integration State
WebSocket State
Last Connection Error
```

不要包含：

```text
Credentials
Prompt
用户文件
完整 session 内容
```

---

# 29. 代码质量要求

Codex 实现时必须遵守：

1. Swift Concurrency 优先。
2. UI 更新全部 MainActor。
3. 网络和解析不阻塞 Main Thread。
4. 避免 callback pyramid。
5. 所有资源生命周期明确。
6. WebSocket 必须能 cancel。
7. Observer / Notification 必须释放。
8. 不使用 force unwrap，除非静态保证且注释原因。
9. 不使用全局 singleton 保存业务状态。
10. 协议边界可 mock。
11. 网络错误不能导致 crash。
12. 不为“未来可能需要”提前过度抽象。

---

# 30. 测试策略

## 30.1 Unit Tests

至少覆盖：

### ActivityReducer

```text
idle
running
waiting input
waiting approval
error
```

多 Session：

```text
Session A running
Session B approval
→ waitingForApproval
```

### Compatibility Resolver

```text
supported
unsupported
unknown
```

### Endpoint Validation

必须拒绝：

```text
8.8.8.8
example.com
192.168.1.100
```

必须允许：

```text
127.0.0.1
localhost
::1
```

### JSON Decode

- 新增未知字段仍可解析。
- 未知事件不会 crash。
- malformed payload 被安全忽略 / 记录。

---

## 30.2 Integration Tests

使用 mock transport 测试：

```text
connect
disconnect
reconnect
event stream
unknown event
protocol failure
```

不要要求 CI 上必须安装 DeepSeek Harness。

---

## 30.3 Manual Compatibility Test

开发机有真实 Harness 时执行：

### Zero Mutation Test

1. 记录 `~/.dsh` 当前状态。
2. 启动 Harness。
3. 启动 DeepSeek Harness。
4. 使用主窗口。
5. 使用 MenuBar / Pet / Native 状态。
6. 退出 DeepSeek Harness。
7. 再用 Terminal 启动 Harness。
8. 验证所有插件和皮肤仍正常。
9. 验证 DeepSeek Harness 没有修改任何 Harness 文件。

理想情况下可使用目录 checksum / git-like diff 工具辅助验证。

---

# 31. 安全验收标准

V1 发布前必须满足：

```text
[ ] 没有代码写入 ~/.dsh
[ ] 没有代码读取 Profile 以驱动运行逻辑
[ ] 没有 npm
[ ] 没有 pnpm
[ ] 没有 Node
[ ] 没有 dsh plugin
[ ] 没有 @latest
[ ] 没有 kill Harness
[ ] 没有自动启动 Harness
[ ] 没有 DOM status parsing
[ ] 没有 WebSocket monkey patch
[ ] 没有公网 Harness
```

---

# 32. 开发阶段

---

## Phase 0 — 项目骨架

目标：

创建可编译、可测试的原生 macOS 工程。

实现：

- macOS App target；
- SwiftUI App lifecycle；
- App Sandbox；
- 网络 entitlement；
- 基础 `AppCoordinator`；
- `README.md`；
- `ARCHITECTURE.md`；
- `AGENTS.md`；
- Unit Test target。

验收：

```text
xcodebuild build
xcodebuild test
```

均通过。

---

## Phase 1 — Attach + WKWebView

这是第一个真正可用版本。

实现：

```text
HarnessDiscovery
HarnessEndpoint
Harness 未启动页
WKWebView
外部链接策略
Reload
Open in Browser
```

流程：

```text
App Launch
   ↓
Detect 127.0.0.1:3080
   ↓
reachable?
  ↙     ↘
yes     no
 ↓       ↓
WebUI   Native Error Page
```

验收：

```text
[ ] Terminal 启动 Harness 后 App 可以打开官方 Web UI
[ ] 官方皮肤正常
[ ] 官方第三方插件 UI 正常
[ ] 浏览器里看到什么，App 基本看到什么
[ ] 关闭 App 后 Harness 无影响
[ ] 卸载 App 后 Harness 无影响
```

Phase 1 完成前不要开始 Native API。

---

## Phase 2 — 原生窗口体验

实现：

- AppKit WindowCoordinator；
- 窗口位置恢复；
- Menu Bar；
- Reload；
- Open in Browser；
- 未连接状态；
- 基础 Settings。

此阶段仍然不需要 Harness Event API。

验收：

```text
[ ] 关闭主窗口不导致 Harness 停止
[ ] MenuBar 可重新打开窗口
[ ] 外部链接交给默认浏览器
[ ] WebView 生命周期稳定
```

---

## Phase 3 — Native Handshake

只实现最小 Native API：

```text
host.describe
```

目的：

- 获取 Harness 版本；
- 确认 Native API 是否可用；
- 建立 Compatibility Resolver。

实现：

```text
HarnessHTTPTransport
HarnessProtocolAdapter
HarnessCompatibilityResolver
```

失败：

```text
进入 Degraded Mode
```

而不是阻止主 Web UI。

验收：

```text
[ ] host.describe 成功时显示 Harness version
[ ] host.describe 失败时 Web UI 仍正常
[ ] unknown version 不 crash
```

---

## Phase 4 — WebSocket Event Layer

实现：

```text
/api/events.host
/api/events.mux
```

必须再次根据当前官方 upstream 源码核对 wire contract。

实现：

- WebSocket Transport；
- reconnect；
- decode；
- unknown frame handling；
- Domain Event mapping。

优先映射：

```text
host/session-added
host/session-removed
host/session-status
host/agent-error
approval/requested
approval/resolved
question/requested
question/resolved
```

验收：

```text
[ ] Harness 重启后自动恢复
[ ] 未知 event 不 crash
[ ] 单条坏 event 不拖垮整个 App
[ ] WebSocket 层坏掉 Web UI 仍可用
```

---

## Phase 5 — ActivityReducer

实现：

- SessionRuntimeState；
- 多 Session；
- global activity；
- transient completion event。

验收：

所有 reducer unit tests 通过。

---

## Phase 6 — Notifications

实现：

- approval；
- question；
- completion；
- error；
- dedupe / debounce。

验收：

```text
[ ] 不刷屏
[ ] 不重复通知
[ ] 前台使用时行为合理
```

---

## Phase 7 — Floating Pet

把现有状态映射成原生悬浮状态球。

实现：

- NSPanel；
- 拖拽；
- 位置保存；
- 状态动画；
- 状态颜色；
- completed transient animation。

验收：

```text
[ ] Harness 工作时 Pet 能反映状态
[ ] 切到其他 App Pet 仍可见
[ ] Pet 不抢键盘焦点
[ ] 关闭主 Harness 窗口 Pet 仍可工作
```

---

## Phase 8 — 稳定性与发布准备

实现：

- diagnostics；
- crash-safe state restore；
- better error messages；
- app icon；
- signing；
- notarization；
- release build；
- README 使用说明。

验收：

执行完整 Zero Mutation Test。

---

# 33. 暂不实现的 Process Supervisor

未来可以考虑：

```text
Harness Process Supervisor
```

但不得进入 V1 MVP。

未来如果实现，必须使用：

```swift
enum HarnessProcessOwnership {
    case external
    case owned
}
```

规则：

### external

用户 Terminal 启动：

```text
Desktop 只能 attach
```

禁止：

```text
stop
kill
restart
update
```

### owned

只有 Desktop 自己未来明确启动的进程才能管理。

即使未来实现 supervisor：

> Process Manager 也不是 Package Manager。

仍然禁止：

```text
npm install
pnpm install
dsh plugin
update Harness
```

---

# 34. 暂不实现 Managed Runtime

V1 不提供：

```text
Desktop 自带 Harness
```

原因：

- 会产生 Harness 版本耦合；
- 会产生 Node Runtime 耦合；
- 会增加 Profile / Plugin 兼容问题；
- 会把项目重新变成 Harness 二次发行版。

如果未来 V2 确实需要：

必须完整隔离：

```text
~/Library/Application Support/DeepSeek Harness/ManagedRuntime/
├── node/
├── harness/
├── dsh-home/
├── npm-cache/
├── pnpm-home/
└── cache/
```

并设置独立：

```text
DSH_HOME
NPM_CONFIG_CACHE
PNPM_HOME
XDG_CACHE_HOME
```

不得复用：

```text
~/.dsh
```

但这不是当前开发任务。

---

# 35. README.md 要求

Codex 在 Phase 0 创建 README。

README 必须明确写：

```text
This is an unofficial macOS client for DeepSeek Harness.
```

说明：

- 非官方；
- 不包含 DeepSeek Harness；
- 不管理 Harness；
- 需要用户自己运行 Harness；
- 默认连接 `127.0.0.1:3080`；
- 不修改 `~/.dsh`；
- 不安装插件；
- 不自动更新 Harness。

README 不要宣传尚未实现的功能。

---

# 36. ARCHITECTURE.md 要求

必须记录以下三条 Decision：

## ADR-001 — Attach First

为什么优先连接现有 Harness，而不是启动新的 Runtime。

## ADR-002 — Zero Mutation

为什么 Desktop 不管理：

```text
~/.dsh
Profile
Plugins
pnpm
npm
```

## ADR-003 — Web Core + Native Enhancement

为什么：

```text
WKWebView = compatibility core
Native API = optional enhancement
```

以及为什么 Native API failure 只能造成 degradation，而不能造成 App failure。

---

# 37. AGENTS.md 要求

给所有后续 AI Coding Agent 的永久约束。

至少写入：

```text
- Do not mutate DSH_HOME.
- Do not add a Node runtime.
- Do not add npm or pnpm management.
- Do not add Harness plugin management.
- Do not vendor DeepSeek Harness.
- Do not auto-update Harness.
- Do not parse Harness DOM for activity state.
- Keep WKWebView usable when native integration fails.
- Prefer Apple frameworks over third-party dependencies.
- Run build and tests after meaningful changes.
- Keep protocol-specific code inside Harness/Compatibility or Harness/Transport.
```

---

# 38. Codex 实施方法

Codex 不要一次性把所有 Phase 写完。

必须按阶段推进：

```text
Phase 0
 ↓
build + test
 ↓
commit-ready
 ↓
Phase 1
 ↓
build + test
 ↓
manual smoke test
 ↓
Phase 2
...
```

每完成一个 Phase：

1. 编译。
2. 运行 Unit Tests。
3. 修复 warning。
4. 检查是否违反 Zero Mutation。
5. 更新 DEVELOPMENT.md 的完成状态。
6. 更新 README（如果用户可见行为变化）。
7. 再进入下一阶段。

---

# 39. 第一轮 Codex 任务

收到本文件后，Codex 第一轮只执行：

```text
Phase 0 + Phase 1
```

不要一次开发全部功能。

第一轮目标：

> 做出一个稳定、纯原生、不会污染用户 Harness 的 macOS Web Client。

第一轮必须完成：

```text
[ ] 创建工程
[ ] App Sandbox
[ ] LocalHarnessDiscovery
[ ] HarnessEndpoint
[ ] Harness 未运行页
[ ] WKWebView
[ ] 外部链接策略
[ ] Reload
[ ] Open in Browser
[ ] README
[ ] ARCHITECTURE
[ ] AGENTS
[ ] Unit Tests
[ ] Build Pass
[ ] Test Pass
```

第一轮禁止：

```text
[ ] Native Harness WebSocket
[ ] Pet
[ ] Notification
[ ] Process Supervisor
[ ] Harness install/update
```

---

# 40. Phase 1 Definition of Done

Phase 1 只有满足以下所有条件才算完成：

```text
[ ] `npx @deepseek-ai/dsh web` 已经运行时，App 能自动连接
[ ] Harness 页面完整显示
[ ] 当前 WebUI 皮肤插件正常
[ ] 第三方 Harness Web 插件不因 Desktop 失效
[ ] App 不修改 ~/.dsh
[ ] App 不运行任何 npm/pnpm/dsh plugin 命令
[ ] App 未发现 Harness 时不会 crash
[ ] Harness 中途关闭后 App 能显示错误状态
[ ] Harness 恢复后用户可重新连接
[ ] 外部链接在默认浏览器打开
[ ] Build 无 error
[ ] Tests 全部通过
```

---

# 41. 最重要的产品验收

最终产品应该满足：

```text
DeepSeek Harness 安装前：
Terminal Harness 正常

DeepSeek Harness 安装后：
Terminal Harness 正常

DeepSeek Harness 使用中：
Terminal Harness 正常

DeepSeek Harness 退出后：
Terminal Harness 正常

DeepSeek Harness 删除后：
Terminal Harness 正常
```

这比任何桌面功能都重要。

---

# 42. 一句话架构定义

整个项目始终遵循：

> **Harness is the server. DeepSeek Harness is a native macOS client.**

以及：

> **Attach First. Zero Mutation. Web Core, Native Enhancement.**

任何新功能，只要开始要求 Desktop 进入 Harness 的 Runtime / Profile / Plugin / pnpm 体系，就应该默认判定为架构退化，除非未来单独进行新的架构决策。

---

# 43. Codex 开始开发时的执行提示

建议将以下内容作为第一次 Codex 指令：

```text
Read DEVELOPMENT.md, ARCHITECTURE.md and AGENTS.md first.

Implement only Phase 0 and Phase 1.

The most important constraints are:
1. Attach First.
2. Zero Mutation of DSH_HOME.
3. WKWebView is the compatibility core.
4. Do not add Node/npm/pnpm/Harness runtime.
5. Do not implement plugin/profile management.
6. Do not implement native event integration yet.
7. Build and test before finishing.

Do not broaden the scope without an explicit architecture decision.
```

