# HarnessDesktop — DEVELOPMENT

开发流程与阶段状态。

## 开发原则

1. **Attach First** — 只连接用户已运行的 Harness。
2. **Zero Mutation** — 不修改 `~/.dsh` 等任何 Harness 数据，不执行 npm / pnpm / dsh plugin 命令。
3. **Web Core + Native Enhancement** — `WKWebView` 是兼容核心；Native API 失败只允许降级。

## 构建与测试

```bash
# 构建
xcodebuild -project HarnessDesktop.xcodeproj -scheme HarnessDesktop \
  -destination 'platform=macOS' build

# 测试
xcodebuild -project HarnessDesktop.xcodeproj -scheme HarnessDesktop \
  -destination 'platform=macOS' test
```

每次有意义的修改后必须：构建 → 跑测试 → 修复 warning → 检查 Zero Mutation → 更新本文档完成状态。

## 阶段状态

### Phase 0 — 项目骨架 ✅

- [x] macOS App target（SwiftUI App lifecycle）
- [x] App Sandbox + `com.apple.security.network.client` entitlement
- [x] 基础 `AppCoordinator`
- [x] `README.md` / `ARCHITECTURE.md` / `AGENTS.md` / `DEVELOPMENT.md`
- [x] Unit Test target
- [x] `xcodebuild build` 通过
- [x] `xcodebuild test` 通过

### Phase 1 — Attach + WKWebView ✅

- [x] `HarnessEndpoint`（loopback-only 校验）
- [x] `LocalHarnessDiscovery`（短超时 HTTP，2xx/3xx 即存在；不扫进程 / 不读 shell / 不读 `~/.dsh`）
- [x] Harness 未运行页（复制命令 + 重新检测，不自动运行命令）
- [x] `WKWebView` 直接加载 `http://127.0.0.1:3080/`（持久化数据存储，不注入 JS / 不改 DOM）
- [x] 外部链接策略（同 origin 留在 WebView，其余交给默认浏览器）
- [x] Reload（⌘R）与 Open in Browser
- [x] 连接期间低频健康检查（每 5s），Harness 中途关闭显示错误状态，恢复后可重新连接
- [x] Unit Tests（Endpoint 校验 / Discovery mock / 导航策略）
- [x] Build 通过
- [x] Test 通过
- [x] 人工验收·自动部分（2026-08-17）：真实 Harness 自动连接 / 未运行页 / 恢复重连 / 中途关闭进入错误状态 / Zero Mutation 校验均通过
- [x] 验收发现并修复：AppCoordinator 默认 Discovery 未使用 settings 端口（已修复 + 3 个回归测试）
- [x] 为可观测性补充非敏感诊断日志（连接状态 / 页面加载完成）
- [ ] 人工验收·目视部分：官方 UI 完整显示 / 皮肤插件兼容 / 外部链接跳默认浏览器 / 「重新检测」按钮

### Phase 2 — 原生窗口体验 ✅（实现完成，目视项待确认）

- [x] AppKit `MainWindowController`（NSWindow + `setFrameAutosaveName` 窗口位置/尺寸恢复）
- [x] Menu Bar（SwiftUI `MenuBarExtra`：状态图标 + Open/Reload/Open in Browser/Check Again/Settings/Quit）
- [x] 关闭主窗口不退出应用（`applicationShouldTerminateAfterLastWindowClosed = false`）
- [x] 点击 Dock 图标重新打开主窗口（`applicationShouldHandleReopen`）
- [x] 启动时按设置显示主窗口（`launchMainWindowAtStart`）
- [x] 基础 Settings（Save 式：Harness Address / Port / Launch Main Window at App Start；loopback 与端口校验）
- [x] 设置变更后重建 Discovery 并重新探测（`settingsDidChange`）
- [x] Build 通过
- [x] Test 通过（25 个，含 settings 持久化与 settingsDidChange 回归）
- [x] 冒烟：菜单栏应用启动、自动连接、页面加载完成
- [ ] 目视确认：菜单栏图标/菜单、窗口位置保存恢复、关窗不退出、Dock 重开窗口、Settings 保存生效

### Phase 3 — Native Handshake ✅（实现完成，冒烟通过）

- [x] 核对上游 wire contract（`@deepseek-ai/dsh-host-apiproxy` 源码 + 真实实例探测）
  - `POST /api/host.describe`，body `{"type":"client-request","rpcId","method","payload":{}}`
  - 响应 `{"type":"server-response","rpcId","result":{"ok":true,"value":{version,cwd,provider?,model?,attachedSessions,canOpenPath}}}`
- [x] `HarnessHTTPTransport`（URLSession，POST `/api/<method>`）
- [x] `HarnessProtocolAdapter` 协议（含 `HarnessDomainEvent`，规格 18 形状；events 流 Phase 4 接入）
- [x] `HarnessGenericAdapter`（describe 握手，NSLock 保护状态，符合 Sendable 协议形状）
- [x] `HarnessCompatibilityResolver` + `HarnessVersion`（supported / unsupported / unknown；未知版本不 crash）
- [x] 协议模型宽松解码（规格 19：未知字段 / 可选字段缺失 / 失败分支均安全）
- [x] 握手成功 → 菜单栏显示 Version（真实 Harness 冒烟：version 0.0.1）
- [x] 握手失败 → `degraded(reason:)`，但 Web UI 继续可用（冒烟：临时服务 501 → degraded + 页面加载完成）
- [x] 修复：degraded 状态下主窗口仍显示 WebView（规格 5.1）
- [x] Build 通过
- [x] Test 通过（41 个，含 resolver / 宽松解码 / transport mock 16 个新测试）

### Phase 4 — WebSocket Event Layer ✅（实现完成，冒烟通过）

- [x] 核对上游 wire contract（`dsh-client-connection` 服务器源码 + 真实 WebSocket 探测）
  - **运行实例的 events 传输是 WebSocket**（upstream npm 客户端包是 SSE fetch 变体，差异隔离在传输层）：
    `GET` upgrade 到 `ws://<host>:<port>/api/events.<mux|host>`，由路径决定流；
  - 客户端**只收不发**——发送任何数据消息都会被服务器以 1008 "downlink only" 关闭；
  - 每帧 JSON：`server-request` 信封，`payload` 为事件帧（`session/subscribed`、`host/session-status`、`approval/*`、`question/*` 等）
- [x] `HarnessWebSocketTransport`（URLSessionWebSocketTask；坏帧记录+跳过，不拖垮流）
- [x] `HarnessEventFrames` 宽松模型 + Adapter 双流消费（mux / host 独立重连）
- [x] 退避重连：500ms / 1s / 2s / 4s / 8s / 10s / 10s…（+jitter，规格 20）
- [x] Domain Event 映射：session-added/removed/status、agent-error、approval-requested/resolved、question-requested/resolved
- [x] 未知帧类型 / 坏帧：忽略 + debug log，不关闭流（规格 19）
- [x] 真实冒烟：连接后收到 6 个 `session/subscribed` 基线帧（6 个附加会话），流持久打开、无崩溃
- [x] Build 通过
- [x] Test 通过（59 个，含 WS 帧解析 / URL 构造 / 映射 / 宽松解码 18 个新测试）

### Phase 5 — ActivityReducer ✅

- [x] `SessionRuntimeState`（多 Session，规格 7.4；禁止单一 isRunning 代表整个 Harness）
- [x] `ActivityReducer`：事件 → `SessionRuntimeState[]` → 全局 `HarnessActivityState`
- [x] 全局优先级（规格 8）：Error > Waiting For Approval > Waiting For Input > Running > Idle
- [x] transient completion（规格 7.3）：running→idle 与 `taskCompleted` 事件产出 `HarnessCompletionEvent`
- [x] 映射补充：`session/subscribed`（mux 基线帧）→ `sessionAdded`（基线会话可跟踪）
- [x] AppCoordinator 接入 reducer，暴露 `activityState` / `sessionCount`；连接不存在 → `.disconnected`
- [x] 菜单栏显示活动状态（Working / Waiting for Approval / Waiting for Input / Error / Idle）+ Sessions 数
- [x] 真实冒烟：基线帧 → 6 个 `sessionAdded`，reducer 跟踪 6 个会话
- [x] Test 通过（79 个，含 19 个 reducer 测试：单 Session 各状态 / 多 Session 优先级 / transient completion / 容错）

### Phase 6 — Notifications ✅

- [x] `NotificationCoordinator`（UNUserNotificationCenter）
- [x] approval / question requested → 立即通知
- [x] running → idle 任务完成 → 通知（**App 前台时抑制**，防瞬态抖动）
- [x] agent-error → 通知（60s debounce）
- [x] 同 Session 同类事件 debounce / dedupe（`NotificationDebouncePolicy`，30s/60s）
- [x] 通知正文不含错误消息 / prompt / 会话内容；session id 只显示截断前缀
- [x] Settings 新增「Enable Notifications」开关（默认开）
- [x] 启动时请求通知授权
- [x] Test 通过（85 个，含 6 个防抖策略测试）
- [x] 冒烟：应用运行正常（首次启动会弹通知授权提示）

### Phase 7 — Floating Pet 🚫 不实现（用户决定）

用户明确决定不做悬浮状态球，相关代码已删除（`Desktop/Pet/`、设置项、测试）。
如未来需要，按规格 23 实现：NSPanel 非激活面板 / 拖拽 / 位置记忆 / 状态动画 /
completed 闪动，状态只来自 `HarnessActivityState`。

### Phase 8 — 稳定性与发布准备 ⬜ 进行中

- [x] **App 图标**（2026-08-17）：使用用户提供的 `图标/DeepSeek.icns`（鲸鱼标志），
  `iconutil` 提取 10 个尺寸 → `Assets.xcassets/AppIcon.appiconset` →
  `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`；已验证嵌入构建产物
  （Info.plist `CFBundleIconName=AppIcon`，Assets.car 含 16→1024 全部尺寸）
- [ ] diagnostics / crash-safe state restore / signing / notarization

## Zero Mutation 手工验收

开发机有真实 Harness 时执行：

1. 记录 `~/.dsh` 当前状态（checksum / git-like diff）。
2. 启动 Harness（`npx @deepseek-ai/dsh web`）。
3. 启动 HarnessDesktop，使用主窗口。
4. 退出 HarnessDesktop。
5. 再次用 Terminal 启动 Harness，验证所有插件和皮肤仍正常。
6. 验证 HarnessDesktop 没有修改任何 Harness 文件。

## 安全验收清单

- [ ] 没有代码写入 `~/.dsh`
- [ ] 没有代码读取 Profile 以驱动运行逻辑
- [ ] 没有 npm / pnpm / Node / dsh plugin / @latest
- [ ] 没有 kill Harness / 自动启动 Harness
- [ ] 没有 DOM status parsing / WebSocket monkey patch
- [ ] 没有公网 Harness
