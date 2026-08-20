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

## 运行版本识别升级

- `runningVersion` 只来自已连接实例的 `host.describe.version`；断开或握手失败时为未知。
- GitHub Release 与 npm Registry 分别表达官方发布版本与可安装版本，保留独立缓存。
- `npx` 可解析版本仅供诊断，禁止作为运行版本的回退。
- 外部 Harness（npm/npx 或源码启动）继续遵守 Attach First 与所有权保护，应用不停止、不更新、不管理它们。

## 2.0 Phase 8 — Runtime Domain & Environment Doctor ✅（实现完成，Build + 146 测试通过）

只读，不启动任何进程。文档：`2.0开发文档.md` §41。

- [x] 新增 `HarnessOwnership`（`Domain/HarnessOwnership.swift`）
  - external / managed 两种所有权；external 禁止 Stop / Update / Rollback / Start
    （Never kill what you do not own）；`resolve(generationMatchesManaged:)` 判定
- [x] 新增 `HarnessRuntimeState`（`Harness/Runtime/HarnessRuntimeState.swift`）
  - `HarnessRuntimeState` / `ManagedRuntimeStatus` / `HarnessRuntimeFailure`（错误码模型 §30）
- [x] 新增 `HarnessEnvironmentReport`（`Harness/Runtime/HarnessEnvironmentReport.swift`）
- [x] `HarnessVersionService` 双版本源（`Harness/Runtime`）
  - GitHub `releases?per_page=20`：解析 `dsh-v*` / `v*`，包含 prerelease、排除 draft，并按 SemVer 取最大值；决定是否存在官方新版本
  - npm registry `dist-tags.latest`：`NPMRegistryVersionProvider` 通过 URLSession 直连，不执行 npm/shell；决定 Managed Runtime 可安装的 exact 版本
  - GitHub release 与 npm installable 分别使用 6h 缓存、节流和 single-flight；手动检查 `force = true` 时并发强制刷新
  - 旧 `runtime.version.latestKnown` / `lastUpdateCheckDate` 懒迁移到 installable 缓存，Release 缓存首次保持为空
  - 任一源失败只回退自己的缓存，不影响 Attach / Web Core / Native / Pet / 已运行 Managed Harness
- [x] semver / prerelease compare：`HarnessVersion` 升级为完整 SemVer 2.0
  - 预发布参与优先级（`0.1.0-rc.7 < 0.1.0-rc.8`，`1.0.0-alpha < 1.0.0`）；build metadata 忽略
  - 非法版本（`1.2.3-`、`1.2.3-beta..1`）拒绝解析
- [x] 启动静默 update check：`AppCoordinator` 经 `HarnessEnvironmentDoctor.inspect()`
  按规格 §9 固定顺序检查（probe → describe → ownership → latest），节流命中不发网络
- [x] 菜单栏「检查 Harness 更新…」（忽略节流；失败只影响菜单栏状态）
- [x] 三版本 UI：当前版本 / 官方最新版本 / npm 可安装版本；GitHub 已发布但 npm 未同步时提示等待并禁用更新
- [x] `host.describe.version` 接入统一 Version Model（握手成功 → `environmentReport.runningVersion`）
- [x] `SettingsStore` / `AppSettings` 增加版本缓存键并适配 `HarnessVersionCacheStoring`
- [x] `AppLogger` 新增 runtime 分类（runtime.environment / runtime.helper / runtime.process /
  runtime.version / runtime.update / runtime.rollback，规格 §31）
- [x] Unit Tests（新增 42 个，累计 146 个全通过）：
  - semver：stable / prerelease / rc.7<rc.8 / 相等 / 超前 / 非法 / build metadata
  - update status：upToDate / updateAvailable / releaseAvailableButNotInstallable / aheadOfLatest / unknown
  - version service：GitHub tag/draft/prerelease/最高 SemVer 解析；npm registry 解析；双缓存节流、迁移、强制刷新隔离、网络降级与独立 single-flight
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

## 2.0 Phase 10 — App-owned Node Runtime ✅（核心实现完成，Build + 181 测试通过）

普通用户不依赖系统 Node。文档：`2.0开发文档.md` §43。

- [x] Node Runtime packaging 机制：`Scripts/fetch-node-runtime.sh`
  - 从 Node.js 官方 tarball（HTTPS）下载 v22 LTS，arm64 / x64 分架构
  - 解包到 `DeepSeek Harness/Resources/Runtime/node/<arch>/`（已 gitignore，Release 打包时随 App 携带）
  - `BundledNodeRuntimeLocator` 按当前架构在 App bundle 中定位 `bin/node`（未携带 → nil）
- [x] arm64 / x86_64：脚本支持 `--all` 双架构；locator 用 `#if arch(arm64)` 区分
- [x] Runtime version inspection：`ManagedRuntimePreparer.validateNode` 用 `ProcessRunner`
  运行 App-owned node `--version`（stdout/stderr 有界 64KB，文档 §32）
- [x] private npm cache：`ManagedPackageCache` 生成子进程环境
  （`npm_config_cache=<AppSupport>/Runtime/npm-cache` + 关闭更新提示），不写全局 npm config
- [x] Managed Harness Home：`ManagedRuntimePaths.managedHarnessHome`（隔离 DSH_HOME 目录）
- [x] `ManagedRuntimePaths`：App-owned 目录布局 + **根目录限制**
  （`isInsideRoot` / `child(relativePath:)` 拒绝 `..`、绝对路径、越界——文档 §32）
- [x] 一键准备流程：`RuntimePreparation` 状态机（固定顺序：
  校验 Node → 校验 exact 版本 → 准备 cache → 拉取包 → 验证可执行），执行器协议注入，
  单测不启动真实 Node / npm（规格 §34）
- [x] Helper 侧实现：`ManagedRuntimePreparer`（App-owned npm install exact version 到
  私有目录，`--no-save/--no-audit/--no-fund`；验证 `node_modules/.bin/dsh` 可执行）
- [x] XPC 契约扩展：`prepareRuntime(version:)` + `RuntimePreparationResultDTO`；
  客户端 `HarnessRuntimeManaging.prepareRuntime(version:)` 透传 exact version；
  错误码 `packagePreparationFailed` 映射
- [x] Runtime preparation UI（文档 §25）：未运行页在 Managed Runtime 未就绪时显示
  「一键准备」+ 免责说明（不会修改系统 Node / Homebrew / Shell / 已有 Harness 数据），
  准备中显示进度；`AppCoordinator.prepareManagedRuntime()`（exact 版本由版本服务解析，
  防重复点击门控）
- [x] Helper entitlements 增加 `network.client`（npm 拉取需要网络，最小化）
- [x] Zero system mutation smoke：机制上不写 `/usr/local`、`/opt/homebrew`、`~/.npm`；
  真实 Node 下载 / 拉包的 smoke 需在 Release 环境执行（见下）
- [x] Build 通过（0 warning）
- [x] Test 通过（181 个，新增 13 个：路径限制 / cache 环境 / 版本安全 /
  准备状态机成功与各步失败 / 客户端 prepareRuntime 透传与错误）

待人工/Release 验收：

```text
一台没有 Homebrew / Node 的 Mac
→ 运行 Scripts/fetch-node-runtime.sh --all（或 Release 构建时打包）
→ App 一键准备 → Helper 用 App-owned Node 拉取 exact dsh 包
→ 系统 PATH 不变 ✅（机制保证，需实机验证）
```

## 2.0 Phase 11 — Managed Start / Stop ✅（核心实现完成，Build + 194 测试通过）

文档：`2.0开发文档.md` §44。

- [x] `ManagedProcessSupervisor`（长生命周期单例，跨 XPC RPC 共享活跃 generation）
  - `posix_spawn` + `POSIX_SPAWN_SETPGROUP`：子进程**自成进程组**，向组发信号可清理
    整棵进程树（避免「npx 退出、node 子进程仍存活」）
  - stdout / stderr 管道**有界读取**（64KB，文档 §32）
- [x] generation ownership：`ManagedHarnessIdentity`（generationID + pid + startedAt +
  version + port）；Stop / Kill 前必须验证 generationID **且** pid 与活跃注册一致
  （PID reuse 不误杀；测试覆盖「PID 相同 generation 不匹配 → 拒绝停止」）
- [x] exact Harness version：启动 `node <package>/lib/bin.js web --port <port>`（README 核对
  CLI），包路径含 exact version，禁止 @latest
- [x] endpoint collision protection：**Start 前重新检查 endpoint**（Helper TCP 探测
  `127.0.0.1:port`）+ App 侧 Start 前重新 Probe（已有 Harness → Abort Start → Attach）
- [x] one-click Start：未运行页「启动 Harness」按钮；`AppCoordinator.startManagedHarness()`
  （防重复启动门控；成功后等待 loopback ready → 自动 Attach）
- [x] graceful Stop：SIGINT → 等待 3s → SIGTERM → 等待 3s →（仍 owned 才）SIGKILL 兜底
  （文档 §18；不默认 kill -9）
- [x] process tree cleanup：进程组信号（`kill(-pid, ...)`）
- [x] unexpected exit handling：启动后异步监视，意外退出清理注册 + 补 SIGKILL
- [x] auto-start setting：`launchManagedHarnessAtAppStart`（默认 false；文档 §27——
  用户开启 + 无 External + Runtime ready + managedVersion 有效才自动启动）
- [x] App exit policy：`stopManagedHarnessOnQuit`（默认 true；文档 §19 V1 推荐）
  - App 退出时显式停止；Helper 侧连接失效兜底（`setStopOnDisconnect` 契约，
    断开时按策略 `stopActive()`）；External Harness 永不被动
- [x] External Harness protection：所有权验证贯穿（`HarnessOwnership.canStop` /
  `ManagedProcessOwnership` / supervisor 身份校验）；菜单栏「停止 Harness」仅
  Managed 运行中显示
- [x] managedVersion 持久化（Desktop 自己的设置，禁止写 Harness Profile；文档 §13）
- [x] Unit Tests（新增 13 个，累计 194 全通过）：
  - supervisor：启动 env/参数（DSH_HOME / npm_config_cache / --port / exact bin）、
    端口占用拒绝、非法版本/端口、重复启动、无 Node、错误身份停止拒绝（PID reuse）、
    SIGINT 优雅停止、SIGTERM/SIGKILL 升级、status、意外退出清注册
  - client：startHarness 身份透传、setStopOnDisconnect 透传
- [x] Build 通过（0 Swift warning）
- [x] Test 通过（194 个）

待人工/实机验收：

```text
Smoke B（Managed Start）：Prepare → Start → 3080 ready → host.describe → ownership=managed
  → Stop → Harness 正常退出（需 Release 签名构建 + 真实 Node）
Smoke C（Collision）：Start 前另一进程占用 port → 不启动第二份 → Attach Existing
Smoke A（External）：Terminal Harness 运行 → App Attach → Stop 不可用 → 退出 App 不影响
```

## 2.0 Phase 12 — Update / Rollback ✅（核心实现完成，Build + 204 测试通过）

文档：`2.0开发文档.md` §45（更新事务化语义 §23 / 更新 UX §20 / 回退 §22）。

- [x] `managedVersion` / `previousManagedVersion` 持久化（Desktop 自己的设置，
  禁止写 Harness Profile；更新成功后交换记录）
- [x] `HarnessUpdateTransaction` 状态机（协议注入，单测不启动真实进程）：
  - Update：PrepareCandidate → StopCurrent → LaunchCandidate → 版本校验 → Commit
  - 候选准备失败 → 当前版本**完全不受影响**（.failed）
  - 候选启动失败 / 版本不符 → 自动恢复 fallback（.restored）
  - 恢复也失败 → 明确错误（.failed，不删除任何版本记录）
  - Rollback：StopCurrent → LaunchPrevious → 版本校验 → Commit（失败保留当前记录）
- [x] health-check-before-commit（§23）：`verifyHarnessVersion`——等待 loopback ready
  后 `host.describe` 报告版本 == expected 才提交（version mismatch protection）
- [x] 版本隔离：候选包落在 version-keyed 目录（Phase 10），更新不触碰当前版本缓存
- [x] 更新确认 UI（§21）：菜单栏「更新 Harness…」（仅 Managed + 有更新可用时显示）
  → NSAlert 确认（当前/最新 + 快速迭代兼容性警告）→ 事务执行
- [x] 回退 UI（§22）：菜单栏「回退到 X…」（仅 Managed + 有上一版本时显示）
  → NSAlert 确认 → 事务执行（成功后 managedVersion ↔ previousManagedVersion 交换）
- [x] 更新失败恢复：候选失败自动恢复原版本并重新 Attach
- [x] 并发控制：`isUpdatingManaged` 门控（更新与回退互斥）
- [x] 日志：`runtime.update` / `runtime.rollback` 分类（只记录版本与阶段，非敏感）
- [x] Unit Tests（新增 10 个，累计 204 全通过）：
  - update 成功（阶段顺序 / committed）、候选准备失败（不停止不启动）、
    停止失败、候选启动失败→恢复、版本校验失败→恢复、恢复也失败、
    rollback 成功 / 启动失败、verify 不可达快速失败、previousManagedVersion 持久化
- [x] Build 通过（0 warning）
- [x] Test 通过（204 个）

待实机验收：

```text
Smoke D（Update）：Managed vA → mock latest vB → update → vB 校验成功 →
  managedVersion=vB / previous=vA
Smoke E（Failed Update）：Managed vA → 候选 vB 失败 → 恢复 vA → App 可继续使用
```

## 2.0 Phase 13 — UX Polish ✅（核心实现完成，Build + 208 测试通过）

文档：`2.0开发文档.md` §46。

- [x] Runtime Settings tab（文档 §26）：设置页新增「运行环境」标签
  - Harness 模式（外部 / Managed / 未运行）、Managed 当前/上一/最新版本
  - [检查更新] [更新 Harness…] [回退…] 动作（启用条件与文档一致：Managed + 有更新 /
    有上一版本）
  - 启动：打开 App 时自动启动 Managed Harness（即时生效）
  - 退出：停止 / 保持运行（`stopManagedHarnessOnQuit`，即时生效）；
    footer 明确「External Harness 永远不会被本应用停止」
  - 数据：隔离模式 + ManagedHarnessHome 路径显示
- [x] 未运行页升级（Phase 10/11 已完成：一键准备 / 启动 / 停止 / 免责说明）
- [x] Error diagnostics（文档 §28 / §30）：`DiagnosticsSnapshot`（App 版本 / macOS /
  端点 / 可达 / Harness 版本 / 连接状态 / Native 集成 / Managed Runtime / 版本 /
  最近错误）——非敏感；菜单栏「复制诊断信息」导出
- [x] Accessibility labels：一键准备 / 启动 / 停止按钮（VoiceOver 可用）
- [x] 中文文案统一（菜单 / 设置 / 弹窗全中文）
- [x] Offline UX：版本检查失败静默降级（不打扰；菜单栏状态显示 unknown）
- [x] Unit Tests（新增 4 个，累计 208 全通过）：诊断快照字段渲染 / unknown /
  nil managed / 错误字段
- [x] Build 通过（0 Swift warning；仅环境噪音警告）
- [x] Test 通过（208 个）

待人工验收：

```text
- 设置页「运行环境」标签交互 / 即时生效
- 菜单栏「复制诊断信息」输出内容目视
- Intel（x86_64）机器 smoke（本机为 arm64，机制已按架构分支处理）
```

## 2.0 Phase 14 — Release Hardening ✅（可本地验证项完成，Build + 214 测试通过）

文档：`2.0开发文档.md` §47。

- [x] Helper signing 机制：App 与 RuntimeHelper.xpc 同 target 构建 + Copy Files
  `CodeSignOnCopy`；`Scripts/sign-and-notarize.sh` 发布流水线（同 Developer ID 签名 +
  notarytool 公证 + stapler，含凭据未提供时的本地开发回退）——需在持有证书的发布机执行
- [x] Hardened Runtime：App 与 Helper 均 `ENABLE_HARDENED_RUNTIME = YES`（已启用）
- [x] Notarization 流程：脚本化（需 Developer ID + App 专用密码）
- [x] Runtime binary integrity verification：`RuntimeIntegrityVerifier`
  - `Scripts/fetch-node-runtime.sh` 下载后写入 `sha256.txt`（bin/node 的 SHA-256）
  - `ManagedRuntimePreparer.validateNode` 启动前校验（CryptoKit）：清单缺失（开发构建）
    跳过并记录；哈希不匹配 → `runtimeIncompatible` 拒绝使用
- [x] Update security review：更新走 `HarnessUpdateTransaction` 事务（health-check-before-
  commit / 失败恢复 / 不删除旧版本），`previousManagedVersion` 只读自 Desktop 设置
- [x] Zero Configuration Mutation audit：代码不含对 `~/.dsh`、Shell、PATH、全局 npm 的写入；
  所有写入限制在 App-owned 根目录（`ManagedRuntimePaths` 根限制，单测覆盖）
- [x] External Harness protection audit：Stop/Update/Rollback 均要求
  `ownership == .managed` + generation 身份验证；External 永不被动（单测覆盖）
- [x] Crash recovery：Helper 连接失效处理（`setStopOnDisconnect` + `supervisor.stopActive()`）
  ——App 崩溃 / 退出后按策略清理遗留 Managed 进程（`stopActive` 单测覆盖）
- [x] stale managed identity cleanup：`stopActive()` 幂等清理活跃 generation 注册
- [x] full regression of Phase 0–7：214 个测试全部通过（含 Phase 0–7 全部既有测试）
- [x] README / ARCHITECTURE / DEVELOPMENT / AGENTS 同步（本阶段起）
- [x] Build 通过（0 Swift warning；仅环境噪音警告）
- [x] Test 通过（214 个）

发布前人工清单：

```text
[ ] 在发布机运行 ./Scripts/fetch-node-runtime.sh --all（打包 App-owned Node）
[ ] ./Scripts/sign-and-notarize.sh（同 Developer ID 签名 + 公证；XPC 同 team 要求）
[ ] Zero Mutation 手工验收（记录 ~/.dsh 前后 checksum）
[ ] Smoke A–F 全量（External / Managed Start / Collision / Update / Failed Update / 零变更）
[ ] Intel（x86_64）机器冒烟
```

---

# 3. 2.0 阶段总结

| Phase | 内容 | 状态 | 测试 |
|-------|------|------|------|
| 8 | Runtime Domain & Environment Doctor | ✅ | 146 |
| 9 | Runtime Helper Skeleton（XPC） | ✅ | 168 |
| 10 | App-owned Node Runtime | ✅ | 181 |
| 11 | Managed Start / Stop | ✅ | 194 |
| 12 | Update / Rollback | ✅ | 204 |
| 13 | UX Polish | ✅ | 208 |
| 14 | Release Hardening | ✅（可本地验证项） | 214 |

遗留（需发布环境 / 实机）：Node 二进制打包、签名公证、Smoke A–F 实机、Intel 冒烟。

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
