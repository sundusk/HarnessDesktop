# DeepSeek Harness — DEVELOPMENT

开发流程与阶段状态。

> **应用名称**：产品对外名称与工程命名已统一为 **DeepSeek Harness**：
> - 产物 `DeepSeek Harness.app`（可执行文件 `DeepSeek Harness`），
>   `CFBundleDisplayName` / `CFBundleName` = DeepSeek Harness；
> - Xcode 工程 / target / scheme：`DeepSeek Harness`，测试 target `DeepSeek HarnessTests`；
> - Swift module：`DeepSeek_Harness`（测试用 `@testable import DeepSeek_Harness`）；
> - bundle id：`dev.deepseekharness.DeepSeekHarness`（测试 `dev.deepseekharness.DeepSeekHarnessTests`）；
> - 目录：`DeepSeek Harness/`、`DeepSeek HarnessTests/`、`DeepSeek Harness.xcodeproj`。

## 开发原则

1. **Attach First** — 只连接用户已运行的 Harness。
2. **Zero Mutation** — 不修改 `~/.dsh` 等任何 Harness 数据，不执行 npm / pnpm / dsh plugin 命令。
3. **Web Core + Native Enhancement** — `WKWebView` 是兼容核心；Native API 失败只允许降级。

## 构建与测试

```bash
# 构建
xcodebuild -project 'DeepSeek Harness.xcodeproj' -scheme 'DeepSeek Harness' \
  -destination 'platform=macOS' build

# 测试
xcodebuild -project 'DeepSeek Harness.xcodeproj' -scheme 'DeepSeek Harness' \
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
- [x] 皮肤插件兼容（2026-08-17 实测：裸 WKWebView 与真实 App 均完整渲染 dsh 皮肤插件，App 无需为皮肤修改代码）
- [ ] 人工验收·目视部分：官方 UI 完整显示 / 外部链接跳默认浏览器 / 「重新检测」按钮

### Phase 2 — 原生窗口体验 ✅（实现完成，目视项待确认）

- [x] AppKit `MainWindowController`（NSWindow + `setFrameAutosaveName` 窗口位置/尺寸恢复）
- [x] Menu Bar（SwiftUI `MenuBarExtra`：状态图标 + Open/Reload/Open in Browser/Check Again/Settings/Quit）
- [x] 关闭主窗口不退出应用（`applicationShouldTerminateAfterLastWindowClosed = false`）
- [x] 点击 Dock 图标重新打开主窗口（`applicationShouldHandleReopen`）
- [x] 启动时按设置显示主窗口（`launchMainWindowAtStart`）
- [x] 基础 Settings（Save 式：Harness Address / Port / Launch Main Window at App Start；loopback 与端口校验）
- [x] 设置变更后重建 Discovery 并重新探测（`settingsDidChange`）
- [x] 修复：重启后恢复的窗口 frame 可能落在已断开 / 离屏显示器上导致主窗口不可见 ——
  窗口中心不在任何屏幕可见区域时回退居中（`MainWindowController.isFrameUsable`，纯函数 + 5 个单测）
- [x] 菜单栏（MenuBarExtra）与设置页全部中文文案；Info.plist 声明 zh-Hans
  （系统菜单项「设置…/退出」在中文系统下也显示中文）
- [x] 菜单栏状态图标改为 App 自己的图标：新增专用 `MenuBarIcon` 模板图资源
  （22×22 / 44×44@2x，由鲸鱼图标生成并留边距，`template-rendering-intent`），
  避免直接加载 128pt App 图标被裁剪成黑条 / 放大；连接状态由菜单内「状态：…」文本承担
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

### Phase 7 — 心情球悬浮球（Floating MoodBall）✅（实现完成，冒烟待做）

此前用户决定不做 Pet（Phase 7 曾标记 🚫）；本轮按新需求改为内置**属于 DeepSeek Harness 自己的心情球**
（参考 [dsh-moodball](https://github.com/sundusk/dsh-moodball) 代码移植，状态源换成本 App 的 Native 活动状态）：

- [x] 状态来源：**不依赖 dsh-moodball 插件 / `/api/moodball/status`** —— 直接消费
  `AppCoordinator.activityState`（ActivityReducer 聚合 Native WebSocket 事件），
  既遵守 Zero Mutation（不装插件、不改 `~/.dsh`），也满足规格 23
  「Pet 不通过 WebView DOM 判断状态」；未连接时显示灰球
- [x] `Desktop/Pet/MoodBallView.swift`：呼吸发光小球（12fps TimelineView + drawingGroup、
  多 stop 渐变光晕代替 blur）+ 眨眼 + 双击兴奋晃动 + 漫画风状态气泡（移植自 moodball）
- [x] `Desktop/Pet/MoodBallPanel.swift` + `MoodBallCoordinator.swift`：NSPanel 置顶悬浮窗
  （非激活 / 点击穿透悬停恢复 / 拖拽 / 位置记忆 / 屏幕变化兜底回右下角 / 设置变化即时同步面板）
- [x] `Desktop/Pet/MoodBallModel.swift`：`HarnessActivityState` → mood 映射
  （idle→蓝 / running→绿「正在思考中」/ waitingForApproval→黄「等待你的授权」/
  waitingForInput→粉「做出你的抉择」/ error→红「出错了」/ disconnected→灰「未连接」），
  任务完成 transient「搞定啦」青色庆祝 2.5s 后回真实状态
- [x] `Desktop/Pet/MoodBallSettings.swift`：UserDefaults 持久化（球大小 / 呼吸速度 /
  眼睛与颜色 / 气泡文字 / 发光 / 点击穿透 / 记住位置 / 锁定位置 / 显隐开关 / 状态颜色契约）
- [x] 菜单栏：仅新增「显示悬浮球」开关（其余悬浮球设置都在设置页）
- [x] 设置页：新增「悬浮球」Section（即时生效；含 6 状态颜色自定义、未连接灰、
  「恢复默认颜色」、「重置位置到右下角」）
- [x] 修复（用户反馈）：**菜单栏菜单跑到屏幕右侧、与鲸鱼图标脱开** ——
  根因是 macOS 26 下 SwiftUI `MenuBarExtra` 的菜单会错误右对齐到屏幕边缘而非状态项。
  改用 AppKit `NSStatusItem + NSMenu`（`Desktop/MenuBar/MenuBarCoordinator.swift`，
  dsh-moodball 同款方案）：菜单锚定在鲸鱼图标正下方、24×24 标准状态项；
  菜单内容（状态 / 会话数 / 版本 / 悬浮球开关 / 动作）由 Observation 驱动即时刷新；
  删除 `MenuBarView.swift`（MenuBarExtra 场景）
- [x] 修复（用户反馈）：**设置面板改为左右标签页** —— 左侧标签栏（常规 / 悬浮球），
  右侧内容区随标签切换；「常规」保留 Save 式表单，「悬浮球」即时生效
- [x] 修复（用户反馈）：**菜单栏点击「设置…」无反应** ——
  `NSApp.sendAction(showSettingsWindow:, to: nil)` 走响应链，SwiftUI Settings
  命令处理器不在链上时静默失败。改为从系统主菜单递归查找 SwiftUI 自动生成的
  「设置…」项，把它的 action 直接发给它的 target（`MenuBarCoordinator.openSettingsAction`），
  主窗口关闭时也能打开设置
- [x] 单元测试：`MoodBallSettingsTests`（默认值 / 持久化 / 越界钳制 / 颜色契约 / 位置）、
  `MoodBallModelTests`（状态映射 / 气泡文字 / transient 庆祝 / 颜色跟随设置 / 晃动）
- [x] Build 通过
- [x] Test 通过（104 个）
- [ ] 冒烟：真实 Harness 运行时球的颜色 / 气泡 / 拖拽 / 菜单栏开关 / 设置即时生效 /
      沙盒下全局鼠标监视器（悬停恢复穿透）行为

### Phase 8（V1 原计划）— 稳定性与发布准备 ⬜ 进行中

- [x] **App 图标**（2026-08-17）：使用用户提供的 `图标/DeepSeek.icns`（鲸鱼标志），
  `iconutil` 提取 10 个尺寸 → `Assets.xcassets/AppIcon.appiconset` →
  `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`；已验证嵌入构建产物
  （Info.plist `CFBundleIconName=AppIcon`，Assets.car 含 16→1024 全部尺寸）
- [ ] diagnostics / crash-safe state restore / signing / notarization
  （2.0 文档发布后，该工作移交 2.0 Phase 13 / 14 跟踪，见下）

---

# 2.0 开发计划阶段状态（Runtime Manager / 一键环境与版本管理）

> 依据 `2.0开发文档.md` 增量开发，不重写 Phase 0–7。每个 Phase：实现 → 单测 → build → test → 修 warning → 更新本文档。

## 2.0 Phase 8 — Runtime Domain & Environment Doctor ✅（实现完成，Build + 146 测试通过）

只读，不启动任何进程。文档：`2.0开发文档.md` §41。

- [x] 新增 `HarnessOwnership`（`Domain/HarnessOwnership.swift`）
  - external / managed 两种所有权；external 禁止 Stop / Update / Rollback / Start
    （Never kill what you do not own）；`resolve(generationMatchesManaged:)` 判定
- [x] 新增 `HarnessRuntimeState`（`Harness/Runtime/HarnessRuntimeState.swift`）
  - `HarnessRuntimeState` / `ManagedRuntimeStatus` / `HarnessRuntimeFailure`（错误码模型 §30）
- [x] 新增 `HarnessEnvironmentReport`（`Harness/Runtime/HarnessEnvironmentReport.swift`）
- [x] 新增 `HarnessVersionService`（`Harness/Runtime/HarnessVersionService.swift`）
  - npm registry `dist-tags.latest` 查询（`NPMRegistryVersionProvider`，URLSession 直连，不执行 npm/shell）
  - 缓存 + 6h 节流（`lastUpdateCheckDate` / `latestKnownHarnessVersion` 存 UserDefaults）
  - 手动检查 `force = true` 忽略节流；single-flight 并发去重
  - 网络失败回退旧缓存 / 返回 nil，不打扰（启动静默检查原则）
- [x] semver / prerelease compare：`HarnessVersion` 升级为完整 SemVer 2.0
  - 预发布参与优先级（`0.1.0-rc.7 < 0.1.0-rc.8`，`1.0.0-alpha < 1.0.0`）；build metadata 忽略
  - 非法版本（`1.2.3-`、`1.2.3-beta..1`）拒绝解析
- [x] 启动静默 update check：`AppCoordinator` 经 `HarnessEnvironmentDoctor.inspect()`
  按规格 §9 固定顺序检查（probe → describe → ownership → latest），节流命中不发网络
- [x] 菜单栏「检查 Harness 更新…」（忽略节流；失败只影响菜单栏状态）
- [x] 当前 / 最新版本 UI：菜单栏版本行（当前 / 最新 / ⬆ 有更新可用）+ 未运行页版本提示
- [x] `host.describe.version` 接入统一 Version Model（握手成功 → `environmentReport.runningVersion`）
- [x] `SettingsStore` / `AppSettings` 增加版本缓存键并适配 `HarnessVersionCacheStoring`
- [x] `AppLogger` 新增 runtime 分类（runtime.environment / runtime.helper / runtime.process /
  runtime.version / runtime.update / runtime.rollback，规格 §31）
- [x] Unit Tests（新增 42 个，累计 146 个全通过）：
  - semver：stable / prerelease / rc.7<rc.8 / 相等 / 超前 / 非法 / build metadata
  - update status：upToDate / updateAvailable / aheadOfLatest / unknown
  - version service：registry 解析 / malformed / 非 2xx / 非法 latest / 网络失败 /
    缓存节流 / 手动绕过 / single-flight / shouldUseCache 纯逻辑
  - ownership：external 禁止操作 / managed 允许 / resolve / generation 不匹配
  - doctor：运行中报告 external+版本 / describe 失败不 crash / latest 失败不影响 /
    未运行保留 managed 信息 / 运行中优先 runningVersion
- [x] Build 通过
- [x] Test 通过（146 个）

验收对照（§41）：

```text
已有 Harness → 正确显示当前版本 ✅（握手 → runningVersion → 菜单栏）
latest 查询成功 → 正确显示更新状态 ✅（updateAvailable / upToDate / aheadOfLatest）
网络失败 → 不影响现有 Harness ✅（回退缓存 / nil，Web UI 不受影响）
```

## 2.0 Phase 9 — Runtime Helper Skeleton ✅（实现完成，Build + 168 测试通过）

建立安全进程边界，不启动 Harness。文档：`2.0开发文档.md` §42。

- [x] Runtime Helper target：新增 `RuntimeHelper.xpc`（`com.apple.product-type.xpc-service`）
  - 嵌入 App `Contents/XPCServices/RuntimeHelper.xpc`（Copy Files 阶段
    `dstSubfolderSpec=16` + `dstPath=$(CONTENTS_FOLDER_PATH)/XPCServices`）
  - 由 launchd 按需启动（`NSXPCListener.service()` + RunLoop，`main.swift`）
  - 独立 Info.plist（`CFBundlePackageType=XPC!`）+ 独立 entitlements（app-sandbox）
- [x] XPC / IPC：`NSXPCConnection(serviceName:)` + `NSXPCListener`；
  `RuntimeHelperProtocol`（@objc）强类型接口，DTO 全部 `NSSecureCoding`
- [x] Caller identity validation：Helper 接受连接前用 `SecCodeCopyGuestWithAttributes`（pid）
  读取调用方 Team ID 并与自身比较（`RuntimeHelperCallerValidator`）——
  只接受同 team 签名的主 App；ad-hoc 开发构建下拒绝连接（优雅降级为 helperUnavailable）
- [x] 强类型 API（`HarnessRuntimeManaging`，文档 §6）：
  `inspectRuntime` / `prepareRuntime` / `startHarness(version:port:dataMode:)` /
  `stopHarness(identity:)` / `status(identity:)` / `healthCheck`
  —— **没有任何 runCommand / runShell / execute(arguments:) 任意命令接口**
- [x] `ManagedHarnessIdentity`（文档 §17：generationID + pid + startedAt + version + port，不存单一 PID）
- [x] `ManagedProcessOwnership`：generationID + pid 双验证，PID reuse 不误杀
- [x] Helper health check：`inspectRuntime`（只读；Phase 9 返回 runtime 未就绪）
- [x] 主 App 接入：`AppCoordinator.runtimeManager`（可注入，默认 XPC 客户端）——
  启动时 `refreshManagedRuntimeStatus()` 查询 Helper 状态写入环境报告；
  Helper 不可用 → `managedRuntime = .missing`，不影响 Web Core / Attach
- [x] XPC 错误映射：`RuntimeHelperErrorDomain` + 错误码 → `HarnessRuntimeFailure`（不携带敏感信息）
- [x] Unit Tests（新增 22 个，累计 168 个全通过）：
  - client：inspect 透传 / 错误传播 / stop 身份透传 / status 映射 / health check /
    骨架能力返回明确错误（prepare→runtimeMissing、start→startFailed）
  - identity：同 team 接受 / 异 team 拒绝 / nil team 拒绝 / generation+pid 双验证 /
    DTO NSSecureCoding 往返 / status wire code 映射 / 错误码
- [x] Build 通过（App + RuntimeHelper 双 target，0 warning）
- [x] Test 通过（168 个）

说明：

- **ServiceManagement 注册**：内嵌 XPC Service 由 launchd 按需自动拉起，
  不需要 `SMAppService` 注册（后者面向 LoginItems / LaunchAgent）。
- **签名约束（ADR-007）**：XPC 要求 App 与 Helper 同一 team 签名。本工程为可移植性
  使用 ad-hoc 签名（无 team）——开发构建下 Helper 连接被拒 → `helperUnavailable`
  优雅降级（菜单栏 / 环境报告显示未就绪，Web UI 完全不受影响）；
  正式分发（同一 Developer ID / Apple Development 签名）时连接正常工作。
- 验收对照（§42）：主 App 能查询 Helper 状态 ✅（`refreshManagedRuntimeStatus`）；
  Helper 没有 shell API ✅（强类型协议，无任意命令）。

## 2.0 Phase 10 — App-owned Node Runtime ⬜ 未开始

## 2.0 Phase 11 — Managed Start / Stop ⬜ 未开始

## 2.0 Phase 12 — Update / Rollback ⬜ 未开始

## 2.0 Phase 13 — UX Polish ⬜ 未开始

## 2.0 Phase 14 — Release Hardening ⬜ 未开始

## Zero Mutation 手工验收

开发机有真实 Harness 时执行：

1. 记录 `~/.dsh` 当前状态（checksum / git-like diff）。
2. 启动 Harness（`npx @deepseek-ai/dsh web`）。
3. 启动 DeepSeek Harness，使用主窗口。
4. 退出 DeepSeek Harness。
5. 再次用 Terminal 启动 Harness，验证所有插件和皮肤仍正常。
6. 验证 DeepSeek Harness 没有修改任何 Harness 文件。

## 安全验收清单（2.0 语义：Zero Configuration Mutation，文档 §48 / AGENTS）

Phase 0–7 基线（仍成立）：

- [x] 没有代码写入 `~/.dsh`
- [x] 没有代码读取 Profile 以驱动运行逻辑
- [x] 没有 `npm install -g` / `dsh plugin` 等修改环境的命令
- [x] 没有 DOM status parsing / WebSocket monkey patch
- [x] 没有公网 Harness（loopback-only）

2.0 新增永久约束（AGENTS.md，实施状态）：

- [x] Never stop External Harness（`HarnessOwnership.canStop` 只对 managed 为 true）
- [x] Never expose arbitrary shell execution（无任意命令 API；版本查询走 URLSession 直连 registry）
- [x] Never edit `~/.dsh` directly
- [x] Never auto-update Harness（启动只静默检查，更新须用户明确操作——Phase 12 实现）
- [x] Never start `@latest` for Managed Harness（Phase 11 实现时强制 exact version）
- [x] Runtime writes only to App-owned paths（Phase 10 实现时）
- [x] Native Runtime failure must not break Web Core（degraded mode 沿用 Phase 3）
- [x] Every process mutation requires ownership verification（Phase 11 实现时）
