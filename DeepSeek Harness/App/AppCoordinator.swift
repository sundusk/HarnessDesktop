import AppKit
import Foundation
import Observation

/// 应用级协调器：编排 Discovery / WebView / Native 握手 / 连接状态机。
///
/// 这是 orchestration，不是 God Object —— 业务逻辑分布在各自模块中。
@MainActor
@Observable
final class AppCoordinator {
    /// 连接状态只由 Integration 层输出，UI 不得自行推断。
    private(set) var connectionState: HarnessConnectionState = .unknown
    private(set) var webModel: HarnessWebViewModel?
    /// Native 握手成功后读取的 Harness 描述信息（version 等）。
    private(set) var harnessInfo: HarnessDescribeInfo?
    /// Phase 8：环境报告（运行版本 / 所有权 / Managed Runtime / 最新版本 / 更新状态）。
    /// 只由 Environment Doctor 与 Native 握手填充，UI 不自行推断。
    private(set) var environmentReport = HarnessEnvironmentReport()

    let settings: AppSettings
    /// Harness 双版本源服务（GitHub release + npm installable）。
    let versionService: HarnessVersionService
    /// App 自身（macOS 应用）最新版本查询（GitHub releases/latest，沙箱安全）。
    let appUpdateProvider: any GitHubLatestReleaseProviding
    /// 手动检查版本是否进行中（防重复点击）。
    private(set) var isCheckingVersion = false
    /// 手动检查 App 更新是否进行中（防重复点击）。
    private(set) var isCheckingAppUpdate = false
    /// Phase 9：Runtime Manager 客户端（强类型能力协议；Helper 不可用时优雅降级）。
    let runtimeManager: any HarnessRuntimeManaging
    /// 文档 §4：npm / 源码外部 Harness 管理器。
    let externalRuntimeManager: any HarnessRuntimeControlling
    /// npm / 源码候选扫描结果（不作为 runningVersion 来源）。
    private(set) var runtimeInventory = HarnessRuntimeInventory.empty
    /// 用户选择并持久化的源码目录（不作为 runningVersion 来源）。
    private(set) var externalRuntimeConfiguration = HarnessRuntimeConfiguration()
    /// 本应用自己启动的 npm / 源码进程状态。
    private(set) var externalRuntimeStatus: HarnessExternalRuntimeStatus = .stopped
    /// 外部运行时启动是否进行中。
    private(set) var isStartingExternalRuntime = false
    /// 最近一次外部运行时错误（只展示错误码文案，不暴露 stderr）。
    private(set) var externalRuntimeError: String?
    /// Phase 10：一键准备是否进行中（防重复点击）。
    private(set) var isPreparingRuntime = false
    /// Phase 11：Managed Harness 是否正在启动（防重复启动）。
    private(set) var isStartingManaged = false
    /// Phase 11：活跃 Managed Harness 身份（App 记录，供停止 / 状态查询）。
    private(set) var activeManagedIdentity: ManagedHarnessIdentity?
    /// Phase 12：更新 / 回退是否进行中（防并发）。
    private(set) var isUpdatingManaged = false
    /// Phase 13：最近一次连接错误（诊断导出用；只存错误类型，非敏感）。
    private(set) var lastConnectionError: String?

    /// 心情球设置（悬浮球开关 / 外观 / 颜色 / 行为；供菜单栏与设置页共用）。
    let petSettings: MoodBallSettings
    /// 心情球呈现模型（由本协调器的 activityState 派生；coordinator 引用在 init 末尾注入）。
    private(set) var petModel: MoodBallModel
    /// 内部可见：协议边界可 mock（规格 29.10），测试可注入或校验。
    var discovery: any HarnessDiscovering
    var compatibilityResolver: HarnessCompatibilityResolver

    private var healthCheckTask: Task<Void, Never>?
    private var handshakeTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var versionRefreshTask: Task<Void, Never>?
    private var nativeAdapter: HarnessGenericAdapter?
    private var reducer = ActivityReducer()
    private let notificationCoordinator: NotificationCoordinator

    /// 全局活动状态（规格 9：所有 UI 只依赖此状态）。
    var activityState: HarnessActivityState {
        switch connectionState {
        case .connected, .degraded:
            return reducer.globalState()
        default:
            // 连接不存在 → disconnected（规格 8 规则 1）。
            return .disconnected
        }
    }

    /// 当前跟踪的 Session 数（菜单栏展示）。
    var sessionCount: Int {
        reducer.sessions.count
    }

    init(settings: AppSettings = AppSettings(),
         discovery: (any HarnessDiscovering)? = nil,
         compatibilityResolver: HarnessCompatibilityResolver = HarnessCompatibilityResolver(),
         petSettings: MoodBallSettings? = nil,
         versionService: HarnessVersionService? = nil,
         runtimeManager: (any HarnessRuntimeManaging)? = nil,
         externalRuntimeManager: (any HarnessRuntimeControlling)? = nil,
         appUpdateProvider: (any GitHubLatestReleaseProviding)? = nil) {
        self.settings = settings
        // 默认 Discovery 必须使用用户配置的 host/port（规格 26：端口可配置）。
        let configuredDiscovery = discovery ?? LocalHarnessDiscovery(host: settings.host, port: settings.port)
        self.discovery = configuredDiscovery
        self.compatibilityResolver = compatibilityResolver
        self.notificationCoordinator = NotificationCoordinator(settings: settings)
        // Phase 8：版本服务缓存复用 AppSettings（UserDefaults）。
        self.versionService = versionService ?? HarnessVersionService(cache: settings)
        // Phase 9：默认 XPC 客户端（惰性连接；测试注入 fake）。
        self.runtimeManager = runtimeManager ?? RuntimeManagerClient()
        self.externalRuntimeManager = externalRuntimeManager ?? HarnessRuntimeManager(discovery: configuredDiscovery)
        // App 自身更新查询（GitHub releases/latest）。
        self.appUpdateProvider = appUpdateProvider ?? GitHubLatestReleaseProvider()
        // 默认值不能写在参数默认表达式里：MoodBallSettings() 是 MainActor 隔离的，
        // 默认参数在 nonisolated 上下文求值；放在 init 体内（MainActor）创建。
        self.petSettings = petSettings ?? MoodBallSettings()
        let model = MoodBallModel(settings: self.petSettings)
        self.petModel = model
        // 注入 coordinator 引用（模型弱引用本协调器，避免保留环）。
        // 放在 init 末尾：此时所有存储属性已初始化，self 可安全传递。
        model.coordinator = self
    }

    /// 请求通知授权（应用启动时调用）。
    func requestNotificationAuthorization() {
        Task { await notificationCoordinator.requestAuthorization() }
    }

    /// 应用启动时调用。
    func start() {
        guard connectionState == .unknown else { return }
        Task { await performDiscovery() }
        // Phase 9：启动时查询 Helper 状态（只读；Helper 不可用 → managedRuntime = missing，
        // 优雅降级，不影响 Web Core / Attach）。
        Task { await refreshManagedRuntimeStatus() }
        Task { await refreshExternalRuntimeInventory() }
        // Phase 11：退出策略（文档 §19）——App 断开时 Helper 是否停止 Managed Harness。
        Task {
            try? await runtimeManager.setStopOnDisconnect(settings.stopManagedHarnessOnQuit)
        }
    }

    /// Phase 11：一键启动 Managed Harness（文档 §16 启动流程）。
    ///
    /// - Start 前重新 Probe endpoint：已有 Harness → Abort Start → Attach Existing；
    /// - exact version：优先已准备/已持久化的 managedVersion，否则解析 latest 并持久化；
    /// - 只调用 Helper 强类型 `startHarness(version:port:dataMode:)`；
    /// - 成功后等待 loopback ready → Attach。
    func startManagedHarness() {
        guard !isStartingManaged, activeManagedIdentity == nil else { return }
        isStartingManaged = true
        Task {
            defer { isStartingManaged = false }
            // Start 前重新 Probe（文档 §16 / §32）
            if await self.discovery.discover() != nil {
                AppLogger.runtimeProcess.info("检测到已有 Harness，放弃启动 Managed，改为 Attach")
                await self.performDiscovery()
                return
            }
            // exact version（文档 §13：禁止 @latest）
            let version: HarnessVersion
            if let persisted = settings.managedVersion.flatMap(HarnessVersion.init) {
                version = persisted
            } else if let latest = await latestManagedCandidateVersion(force: true) {
                version = latest
            } else {
                environmentReport.managedRuntime = .missing
                AppLogger.runtimeProcess.info("Managed 启动失败：无法解析 exact 版本")
                return
            }
            do {
                let identity = try await self.runtimeManager.startHarness(
                    version: version.description,
                    port: self.settings.port,
                    dataMode: .isolated
                )
                self.activeManagedIdentity = identity
                self.settings.managedVersion = version.description
                self.environmentReport.managedVersion = version
                self.environmentReport.managedRuntime = .ready
                self.environmentReport.ownership = .managed
                self.environmentReport.refreshUpdateStatus()
                AppLogger.runtimeProcess.info(
                    "Managed Harness 已启动：pid \(identity.pid, privacy: .public) / \(version.description, privacy: .public) / port \(self.settings.port, privacy: .public)"
                )
                await attachAfterManagedStart()
            } catch {
                AppLogger.runtimeProcess.info("Managed 启动失败：\(String(describing: error), privacy: .public)")
                environmentReport.managedRuntime = .ready  // runtime 仍在，只是本次启动失败
            }
        }
    }

    /// Phase 11：停止 Managed Harness（只对 App 自己启动的进程；External 不受影响）。
    func stopManagedHarness() {
        guard let identity = activeManagedIdentity else { return }
        Task {
            do {
                try await runtimeManager.stopHarness(identity: identity)
                activeManagedIdentity = nil
                environmentReport.ownership = nil
                webModel = nil
                updateState(.unavailable)
                AppLogger.runtimeProcess.info("Managed Harness 已停止（pid \(identity.pid, privacy: .public)）")
            } catch {
                AppLogger.runtimeProcess.info("Managed 停止失败：\(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Phase 12：更新 Managed Harness（文档 §21 / §23 事务化）。
    ///
    /// 流程：latest 重新验证 → 事务（PrepareCandidate → StopCurrent → LaunchCandidate
    /// → 版本校验 → Commit）；候选失败自动恢复原版本；只在成功提交后才更新
    /// `managedVersion` / `previousManagedVersion`。
    func updateManagedHarness() {
        guard !isUpdatingManaged,
              let current = settings.managedVersion.flatMap(HarnessVersion.init) else { return }
        isUpdatingManaged = true
        Task {
            defer { isUpdatingManaged = false }
            // 1. latest 重新从 registry 验证（手动检查忽略节流）
            guard let latest = await latestManagedCandidateVersion(force: true) else {
                AppLogger.runtimeUpdate.info("更新失败：无法解析最新版本")
                return
            }
            let currentString = current.description
            let latestString = latest.description
            guard latestString != currentString else {
                AppLogger.runtimeUpdate.info("已是最新版本，无需更新")
                return
            }

            let executor = LiveUpdateExecutor(coordinator: self)
            let transaction = HarnessUpdateTransaction(executor: executor)
            let result = await transaction.update(from: currentString, candidate: latestString)

            switch result {
            case .committed(let version):
                self.settings.previousManagedVersion = currentString
                self.settings.managedVersion = version
                self.environmentReport.managedVersion = HarnessVersion(version)
                self.environmentReport.managedRuntime = .ready
                self.environmentReport.ownership = .managed
                self.environmentReport.refreshUpdateStatus()
                AppLogger.runtimeUpdate.info("更新成功并提交：\(version, privacy: .public)")
                await self.attachAfterManagedStart()
            case .restored(let version):
                self.environmentReport.managedRuntime = .ready
                self.environmentReport.ownership = .managed
                AppLogger.runtimeUpdate.info("候选失败，已恢复：\(version, privacy: .public)")
                await self.attachAfterManagedStart()
            case .failed(let failure):
                self.environmentReport.managedRuntime = .ready
                AppLogger.runtimeUpdate.info("更新失败：\(String(describing: failure), privacy: .public)")
            }
        }
    }

    /// Phase 12：回退到上一版本（文档 §22）。
    func rollbackManagedHarness() {
        guard !isUpdatingManaged,
              let current = settings.managedVersion.flatMap(HarnessVersion.init),
              let previous = settings.previousManagedVersion.flatMap(HarnessVersion.init) else { return }
        isUpdatingManaged = true
        Task {
            defer { isUpdatingManaged = false }
            let executor = LiveUpdateExecutor(coordinator: self)
            let transaction = HarnessUpdateTransaction(executor: executor)
            let result = await transaction.rollback(from: current.description, previous: previous.description)

            switch result {
            case .committed(let version):
                // 交换：managedVersion ↔ previousManagedVersion（文档 §22）
                self.settings.managedVersion = previous.description
                self.settings.previousManagedVersion = current.description
                self.environmentReport.managedVersion = HarnessVersion(version)
                self.environmentReport.managedRuntime = .ready
                self.environmentReport.ownership = .managed
                self.environmentReport.refreshUpdateStatus()
                AppLogger.runtimeRollback.info("回退成功：\(version, privacy: .public)")
                await self.attachAfterManagedStart()
            case .failed(let failure):
                // 回退失败：当前记录保留，可「恢复到 X」（文档 §22）
                AppLogger.runtimeRollback.info("回退失败：\(String(describing: failure), privacy: .public)")
            case .restored:
                break
            }
        }
    }

    /// Phase 11：退出 App 时按设置停止 Managed Harness（文档 §19）。
    func stopManagedHarnessForQuit() {
        guard settings.stopManagedHarnessOnQuit, let identity = activeManagedIdentity else { return }
        // 显式通知 Helper 停止（连接失效时 Helper 也会按 stopOnDisconnect 兜底）
        Task {
            try? await runtimeManager.stopHarness(identity: identity)
        }
    }

    // MARK: - npm / 源码 Runtime Manager

    /// 刷新 npm 与源码候选。扫描失败只返回空结果，不影响 Attach。
    func refreshExternalRuntimeInventory() async {
        externalRuntimeConfiguration = await externalRuntimeManager.configuration()
        runtimeInventory = await externalRuntimeManager.detect()
        externalRuntimeStatus = await externalRuntimeManager.status()
    }

    /// 选择并保存外部 Harness 源码目录，支持直接选择 package.json。
    func selectExternalHarnessSource(at url: URL) {
        Task {
            do {
                externalRuntimeConfiguration = try await externalRuntimeManager.selectSourceDirectory(at: url)
                externalRuntimeError = nil
                await refreshExternalRuntimeInventory()
            } catch let failure as HarnessExternalRuntimeFailure {
                externalRuntimeError = failure.userMessage
            } catch {
                externalRuntimeError = HarnessExternalRuntimeFailure.sourceSelectionFailed.userMessage
            }
        }
    }

    /// 文档 §11：后台启动 npm / 源码 Harness，并等待 loopback 可用。
    func startExternalHarness(mode: HarnessRuntimeMode, sourcePath: String? = nil) {
        guard !isStartingExternalRuntime else { return }
        isStartingExternalRuntime = true
        externalRuntimeError = nil
        externalRuntimeStatus = .starting(mode)
        Task {
            defer { isStartingExternalRuntime = false }
            let configured = await externalRuntimeManager.configuration()
            externalRuntimeConfiguration = configured
            let selectedSourcePath = sourcePath ?? configured.sourcePath ?? runtimeInventory.sourceInstallations.first?.path
            do {
                let record = try await externalRuntimeManager.start(
                    mode: mode,
                    sourcePath: selectedSourcePath,
                    port: settings.port
                )
                externalRuntimeStatus = .running(record)
                await performDiscovery()
            } catch let failure as HarnessExternalRuntimeFailure {
                externalRuntimeError = failure.userMessage
                if failure == .harnessAlreadyRunning {
                    // Attach-first：已有实例只连接，不尝试停止或接管。
                    await performDiscovery()
                } else {
                    externalRuntimeStatus = .failed(failure.userMessage)
                }
            } catch {
                externalRuntimeError = "Harness 启动失败，请查看日志。"
                externalRuntimeStatus = .failed(externalRuntimeError ?? "Harness 启动失败")
            }
        }
    }

    /// 文档 §11：停止本应用自己启动的 npm / 源码进程。
    func stopExternalHarness() {
        Task {
            do {
                try await externalRuntimeManager.stop()
                externalRuntimeStatus = .stopped
                externalRuntimeError = nil
                rediscover()
            } catch let failure as HarnessExternalRuntimeFailure {
                externalRuntimeError = failure.userMessage
                externalRuntimeStatus = .failed(failure.userMessage)
            } catch {
                externalRuntimeError = "Harness 停止失败，请查看日志。"
                externalRuntimeStatus = .failed(externalRuntimeError ?? "Harness 停止失败")
            }
        }
    }

    /// 文档 §11：stop → wait → start。
    func restartExternalHarness() {
        guard !isStartingExternalRuntime else { return }
        isStartingExternalRuntime = true
        externalRuntimeError = nil
        Task {
            defer { isStartingExternalRuntime = false }
            do {
                let record = try await externalRuntimeManager.restart()
                externalRuntimeStatus = .running(record)
                await performDiscovery()
            } catch let failure as HarnessExternalRuntimeFailure {
                externalRuntimeError = failure.userMessage
                externalRuntimeStatus = .failed(failure.userMessage)
            } catch {
                externalRuntimeError = "Harness 重启失败，请查看日志。"
                externalRuntimeStatus = .failed(externalRuntimeError ?? "Harness 重启失败")
            }
        }
    }

    /// 等待 Managed 启动后 loopback ready 再 Attach（最多 30s）。
    private func attachAfterManagedStart() async {
        for _ in 0..<30 {
            if await discovery.discover() != nil {
                await performDiscovery()
                return
            }
            try? await Task.sleep(for: .seconds(1))
        }
        updateState(.unavailable)
    }

    /// Phase 9：查询 Runtime Helper 状态并写入环境报告（规格 §42 验收：主 App 能查询 Helper 状态）。
    func refreshManagedRuntimeStatus() async {
        do {
            let inspection = try await runtimeManager.inspectRuntime()
            environmentReport.managedRuntime = inspection.runtimeReady ? .ready : .missing
            AppLogger.runtimeHelper.info(
                "Helper 状态：ready=\(inspection.runtimeReady, privacy: .public) node=\(inspection.nodeVersion ?? "nil", privacy: .public)"
            )
        } catch {
            // Helper 不可用（开发构建无同 team 签名 / 尚未实现）→ 未就绪，不打扰用户。
            environmentReport.managedRuntime = .missing
            AppLogger.runtimeHelper.info("Helper 不可用：\(String(describing: error), privacy: .public)")
        }
    }

    /// Phase 10：一键准备运行环境（文档 §14）。
    ///
    /// - exact 版本由本 App 的版本服务解析（强制检查，失败回退缓存）；
    /// - 只调用 Helper 的强类型 `prepareRuntime(version:)`，不执行任意命令；
    /// - 重复点击去重（`isPreparingRuntime` 门控）。
    func prepareManagedRuntime() {
        guard !isPreparingRuntime else { return }
        isPreparingRuntime = true
        Task {
            defer { isPreparingRuntime = false }
            // 解析 exact version（文档 §13：禁止 @latest；由 registry latest 固定）
            guard let version = await latestManagedCandidateVersion(force: true) else {
                environmentReport.managedRuntime = .missing
                AppLogger.runtimeEnvironment.info("一键准备失败：无法解析 exact 版本")
                return
            }
            do {
                let result = try await runtimeManager.prepareRuntime(version: version.description)
                environmentReport.managedVersion = version
                environmentReport.managedRuntime = .ready
                environmentReport.refreshUpdateStatus()
                AppLogger.runtimeEnvironment.info(
                    "一键准备完成：node \(result.nodeVersion, privacy: .public) / dsh \(result.managedVersion, privacy: .public)"
                )
            } catch {
                environmentReport.managedRuntime = .missing
                AppLogger.runtimeEnvironment.info("一键准备失败：\(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Sole version gateway for Managed prepare/start/update operations.
    /// A GitHub-only release can be announced but never installed from npm.
    func latestManagedCandidateVersion(force: Bool) async -> HarnessVersion? {
        await versionService.latestInstallableVersion(force: force)
            ?? versionService.cachedLatestInstallable
    }

    /// 用户点击「重新检测」时调用。
    func rediscover() {
        healthCheckTask?.cancel()
        handshakeTask?.cancel()
        eventTask?.cancel()
        versionRefreshTask?.cancel()
        tearDownNativeAdapter()
        webModel = nil
        harnessInfo = nil
        environmentReport = HarnessEnvironmentReport()
        reducer = ActivityReducer()
        Task { await performDiscovery() }
    }

    /// 重新加载 Harness Web UI。
    func reload() {
        webModel?.reload()
    }

    /// 在默认浏览器中打开 Harness。
    func openInBrowser() {
        webModel?.openInBrowser()
    }

    /// 菜单栏「检查 Harness 更新…」/ 设置页「检查更新」。
    ///
    /// 沙箱安全的实现（不执行 shell / 不依赖 npx / npm）：
    /// 1. 运行版本：运行中 Harness 的 `host.describe` 版本（`harnessInfo.version`）；
    ///    未连接或握手失败时保持未知，绝不回退到 npm / npx / Managed 版本；
    /// 2. 官方最新版本：GitHub Releases；可安装版本：npm Registry；
    /// 3. 统一交给 `HarnessUpdateStatus` 判断并生成弹窗内容。
    ///
    func checkForUpdates() {
        guard !isCheckingVersion else { return }
        isCheckingVersion = true
        Task {
            defer { isCheckingVersion = false }
            // 1. 当前版本（无需 shell：host.describe 已通过 Native 握手拿到）。
            let described = harnessInfo.flatMap { HarnessVersion($0.version) }
            // 2. 两个源互相独立，并发强制刷新。
            async let release = versionService.latestReleaseVersion(force: true)
            async let installable = versionService.latestInstallableVersion(force: true)
            let (latestRelease, latestInstallable) = await (release, installable)
            environmentReport.setRunningVersion(from: described)
            environmentReport.latestReleaseVersion = latestRelease
            environmentReport.latestInstallableVersion = latestInstallable
            environmentReport.refreshUpdateStatus()
            // 弹窗只消费统一状态机，不自行比较版本。
            AppLogger.version.info(
                "版本检查完成：running \(described?.description ?? "?", privacy: .public) / release \(latestRelease?.description ?? "?", privacy: .public) / installable \(latestInstallable?.description ?? "?", privacy: .public)"
            )
            showVersionCheckPopup(status: environmentReport.updateStatus)
        }
    }

    /// 弹出版本检查结果面板（单个「好」按钮，点击关闭）。
    private func showVersionCheckPopup(status: HarnessUpdateStatus) {
        let content = HarnessVersionCheckPresenter.popupContent(status: status)
        let alert = NSAlert()
        alert.messageText = content.title
        alert.informativeText = content.detail
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    /// 菜单栏「检查 App 更新…」：检测 DeepSeek Harness（macOS App）自身是否有新版本。
    ///
    /// 沙箱安全：当前版本读 `Bundle.main`，最新版本查 GitHub `releases/latest`（URLSession）。
    /// 与 Harness 的「检查更新」分开：Harness 版本管理归设置页，菜单栏只负责 App 自身更新。
    func checkForAppUpdates() {
        guard !isCheckingAppUpdate else { return }
        isCheckingAppUpdate = true
        Task {
            defer { isCheckingAppUpdate = false }
            let current = AppUpdateChecker.currentVersion
            let latest: String?
            do {
                latest = try await appUpdateProvider.fetchLatestTag()
            } catch {
                AppLogger.version.error("App 更新查询失败：\(String(describing: error), privacy: .public)")
                latest = nil
            }
            let status = AppUpdateStatus.status(current: current, latest: latest)
            AppLogger.version.info("App 更新检查：\(status, privacy: .public)")
            showAppUpdatePopup(status: status)
        }
    }

    /// 弹出版本检查结果面板：有新版时提供「打开下载页」跳 GitHub release。
    private func showAppUpdatePopup(status: AppUpdateStatus) {
        let alert = NSAlert()
        switch status {
        case .unknown:
            alert.messageText = "App 版本检测失败"
            alert.informativeText = "无法获取最新版本信息，请检查网络连接。"
            alert.addButton(withTitle: "好")
        case .upToDate(let current):
            alert.messageText = "您使用的就是最新版本"
            alert.informativeText = "当前版本：\(current)"
            alert.addButton(withTitle: "好")
        case .updateAvailable(let current, let latest):
            alert.messageText = "有新版本需要更新"
            alert.informativeText = "当前版本：\(current)\n最新版本：\(HarnessVersion(latest)?.description ?? latest)"
            alert.addButton(withTitle: "打开下载页")
            alert.addButton(withTitle: "好")
        case .aheadOfLatest(let current, let latest):
            alert.messageText = "当前版本高于最新版本"
            alert.informativeText = "当前版本：\(current)\n最新版本：\(HarnessVersion(latest)?.description ?? latest)"
            alert.addButton(withTitle: "好")
        }
        let response = alert.runModal()
        if case .updateAvailable = status, response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(AppUpdateChecker.releasePageURL)
        }
    }

    /// 设置变更后调用：用新 host/port 重建 Discovery 并重新探测。
    func settingsDidChange() {
        discovery = LocalHarnessDiscovery(host: settings.host, port: settings.port)
        let currentDiscovery = discovery
        Task { await externalRuntimeManager.update(discovery: currentDiscovery) }
        healthCheckTask?.cancel()
        handshakeTask?.cancel()
        eventTask?.cancel()
        versionRefreshTask?.cancel()
        tearDownNativeAdapter()
        webModel = nil
        harnessInfo = nil
        environmentReport = HarnessEnvironmentReport()
        reducer = ActivityReducer()
        Task { await performDiscovery() }
        Task { await refreshExternalRuntimeInventory() }
    }

    /// 释放 Native Adapter（断开事件流）。
    private func tearDownNativeAdapter() {
        if let adapter = nativeAdapter {
            Task { await adapter.disconnect() }
        }
        nativeAdapter = nil
    }

    // MARK: - Private

    // MARK: - Phase 12：更新事务执行器

    /// 更新事务执行器（真实实现，接入本协调器的 Runtime Manager / Discovery）。
    @MainActor
    private final class LiveUpdateExecutor: HarnessUpdateExecuting {
        private weak var coordinator: AppCoordinator?

        init(coordinator: AppCoordinator) {
            self.coordinator = coordinator
        }

        func prepareCandidate(version: String) async throws {
            guard let coordinator else { throw HarnessRuntimeFailure.helperUnavailable }
            _ = try await coordinator.runtimeManager.prepareRuntime(version: version)
        }

        func stopCurrent() async throws {
            guard let coordinator else { throw HarnessRuntimeFailure.helperUnavailable }
            guard let identity = coordinator.activeManagedIdentity else { return }
            try await coordinator.runtimeManager.stopHarness(identity: identity)
            coordinator.activeManagedIdentity = nil
            coordinator.environmentReport.ownership = nil
        }

        func launchCandidate(version: String) async throws -> ManagedHarnessIdentity {
            guard let coordinator else { throw HarnessRuntimeFailure.helperUnavailable }
            let identity = try await coordinator.runtimeManager.startHarness(
                version: version,
                port: coordinator.settings.port,
                dataMode: .isolated
            )
            coordinator.activeManagedIdentity = identity
            return identity
        }

        func verifyVersion(expected: String) async -> Bool {
            guard let coordinator else { return false }
            return await AppCoordinator.verifyHarnessVersion(expected: expected, discovery: coordinator.discovery)
        }
    }

    /// 等待 loopback ready（默认最多 30s）并校验 `host.describe` 报告版本 == expected
    /// （文档 §21 health check / §23 version mismatch protection）。
    static func verifyHarnessVersion(expected: String,
                                     discovery: any HarnessDiscovering,
                                     maxAttempts: Int = 30,
                                     pollInterval: Duration = .seconds(1)) async -> Bool {
        var endpoint: HarnessEndpoint?
        for _ in 0..<maxAttempts {
            if let found = await discovery.discover() {
                endpoint = found
                break
            }
            try? await Task.sleep(for: pollInterval)
        }
        guard let endpoint else { return false }
        guard let info = try? await HarnessHTTPTransport().describe(endpoint: endpoint) else { return false }
        return HarnessVersion(info.version) == HarnessVersion(expected)
    }

    /// Phase 8：Environment Doctor（规格 §9 检查顺序，只读）。
    ///
    /// 依赖全部来自本协调器：Discovery、host.describe（HTTP Transport）、版本服务。
    /// 每次构造（computed property）保证读取最新 discovery / versionService。
    private var environmentDoctor: HarnessEnvironmentDoctor {
        HarnessEnvironmentDoctor(
            discovery: discovery,
            describe: { endpoint in
                let transport = HarnessHTTPTransport()
                guard let info = try? await transport.describe(endpoint: endpoint) else { return nil }
                return HarnessVersion(info.version)
            },
            managedRuntimeStatus: { .unknown },
            managedVersion: { nil },
            latestInstallableVersionProvider: { [versionService] in
                await versionService.latestInstallableVersion(force: false)
            }
        )
    }

    private func performDiscovery() async {
        updateState(.discovering)
        let report = await environmentDoctor.inspect()
        environmentReport = report
        // GitHub 仅补充官方 Release 信息，不阻塞 Doctor 的本地探测和 Attach。
        versionRefreshTask?.cancel()
        versionRefreshTask = Task { [weak self] in
            guard let self else { return }
            let release = await self.versionService.latestReleaseVersion(force: false)
            guard !Task.isCancelled else { return }
            self.environmentReport.latestReleaseVersion = release
            self.environmentReport.refreshUpdateStatus()
        }
        guard let endpoint = report.discoveredEndpoint else {
            updateState(.unavailable)
            maybeAutoStartManaged()
            return
        }
        connect(to: endpoint)
    }

    /// Phase 11：自动启动（文档 §27）——用户开启 + 未发现 External + Managed Runtime ready
    /// + managedVersion 有效，才自动启动 Managed Harness。
    private func maybeAutoStartManaged() {
        guard settings.launchManagedHarnessAtAppStart,
              activeManagedIdentity == nil,
              !isStartingManaged,
              environmentReport.managedRuntime == .ready,
              environmentReport.managedVersion != nil else {
            return
        }
        AppLogger.runtimeProcess.info("自动启动 Managed Harness（设置已开启）")
        startManagedHarness()
    }

    private func connect(to endpoint: HarnessEndpoint) {
        updateState(.connected)
        let model = HarnessWebViewModel(endpoint: endpoint)
        webModel = model
        model.loadInitial()
        startHealthCheck()
        startNativeHandshake(endpoint: endpoint)
    }

    /// 统一的状态转换入口：只记录连接状态（非敏感），不记录任何内容数据。
    private func updateState(_ newState: HarnessConnectionState) {
        let old = connectionState
        connectionState = newState
        if old != newState {
            AppLogger.app.info("连接状态：\(String(describing: newState), privacy: .public)")
        }
    }

    /// 连接期间低频健康检查（每 5 秒一次，不高频轮询）。
    ///
    /// Harness 中途关闭 → 进入 `unavailable`（展示未运行页），
    /// 用户点击「重新检测」即可在 Harness 恢复后重新连接。
    private func startHealthCheck() {
        healthCheckTask?.cancel()
        healthCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self else { return }
                let endpoint = await self.discovery.discover()
                guard endpoint == nil else { continue }
                self.environmentReport.clearRunningHarness()
                self.updateState(.unavailable)
                self.webModel = nil
                return
            }
        }
    }

    /// Native Compatibility Handshake（规格 17 / Phase 3）。
    ///
    /// 失败（网络 / 协议 / 不支持版本）→ Degraded Mode（`connectionState = .degraded`），
    /// 但 Web UI 必须继续可用——degraded 只禁用 Native 增强，不影响主窗口。
    private func startNativeHandshake(endpoint: HarnessEndpoint) {
        handshakeTask?.cancel()
        handshakeTask = Task { [weak self] in
            guard let self else { return }
            let adapter = HarnessGenericAdapter(endpoint: endpoint)
            do {
                try await adapter.connect()
                let verdict = self.compatibilityResolver.verdict(for: adapter.harnessInfo?.version)
                switch verdict {
                case .supported, .unknown:
                    // unknown 版本不 crash、宽容视为可用（规格 33 验收）。
                    self.harnessInfo = adapter.harnessInfo
                    self.nativeAdapter = adapter
                    self.consumeAdapterEvents(adapter)
                    // Phase 8：host.describe.version 接入统一 Version Model（规格 §10 / §41）。
                    self.environmentReport.setRunningVersion(
                        from: adapter.harnessInfo.flatMap { HarnessVersion($0.version) }
                    )
                    self.environmentReport.ownership = .external
                    self.environmentReport.refreshUpdateStatus()
                    AppLogger.compatibility.info(
                        "Native handshake 成功：version \(self.harnessInfo?.version ?? "?", privacy: .public)"
                    )
                case .unsupported:
                    self.harnessInfo = nil
                    self.tearDownNativeAdapter()
                    self.updateState(.degraded(reason: "不支持的 Harness 版本"))
                }
            } catch {
                self.harnessInfo = nil
                self.lastConnectionError = String(describing: error)
                self.tearDownNativeAdapter()
                self.updateState(.degraded(reason: "Native 握手失败"))
                AppLogger.compatibility.error(
                    "Native handshake 失败：\(String(describing: error), privacy: .public)"
                )
            }
        }
    }

    /// 消费 Adapter 的 Domain Event 流。
    ///
    /// Phase 4：只记录事件类型（非敏感）；Phase 5 起交给 ActivityReducer 聚合。
    private func consumeAdapterEvents(_ adapter: HarnessGenericAdapter) {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            guard let self else { return }
            for await event in adapter.events {
                self.handleDomainEvent(event)
            }
        }
    }

    private func handleDomainEvent(_ event: HarnessDomainEvent) {
        reducer.reduce(event)
        notificationCoordinator.handle(event: event)
        // transient 完成事件（Phase 6 转通知；Phase 7 心情球短暂庆祝「搞定啦」）；
        // session id 截断记录。
        let completions = reducer.drainCompletions()
        for completion in completions {
            notificationCoordinator.handleCompletion(completion)
            petModel.noteTaskCompletion()
            AppLogger.activity.info("任务完成（session \(completion.sessionID.prefix(8)), privacy: .public)")
        }
        AppLogger.activity.debug("Domain event：\(event.typeName, privacy: .public)")
    }
}

// MARK: - Phase 13：诊断数据提供（文档 §28）

extension AppCoordinator: DiagnosticsProviding {
    var settingsHost: String { settings.host }
    var settingsPort: Int { settings.port }
    var harnessVersion: String? { harnessInfo?.version }
    var managedVersion: HarnessVersion? { environmentReport.managedVersion }
    var latestReleaseVersion: HarnessVersion? { environmentReport.latestReleaseVersion }
    var latestInstallableVersion: HarnessVersion? { environmentReport.latestInstallableVersion }

    var connectionStateDescription: String {
        switch connectionState {
        case .unknown: return "未知"
        case .discovering: return "正在检测"
        case .unavailable: return "Harness 未运行"
        case .connecting: return "连接中"
        case .connected: return "已连接"
        case .reconnecting: return "重连中"
        case .degraded(let reason): return "降级（\(reason)）"
        }
    }

    var nativeIntegrationDescription: String {
        switch connectionState {
        case .connected: return "正常（handshake + 事件流）"
        case .degraded: return "不可用（已降级，Web UI 正常）"
        default: return "未建立"
        }
    }

    var managedRuntimeDescription: String {
        switch environmentReport.managedRuntime {
        case .unknown: return "未知"
        case .missing: return "未准备"
        case .ready: return "已就绪"
        }
    }

    /// 诊断快照文本（复制用）。
    func diagnosticsText() -> String {
        DiagnosticsFactory.make(coordinator: self).text
    }
}
