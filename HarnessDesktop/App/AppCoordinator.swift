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

    let settings: AppSettings
    /// 内部可见：协议边界可 mock（规格 29.10），测试可注入或校验。
    var discovery: any HarnessDiscovering
    var compatibilityResolver: HarnessCompatibilityResolver

    private var healthCheckTask: Task<Void, Never>?
    private var handshakeTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var nativeAdapter: HarnessGenericAdapter?
    private var reducer = ActivityReducer()

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
         compatibilityResolver: HarnessCompatibilityResolver = HarnessCompatibilityResolver()) {
        self.settings = settings
        // 默认 Discovery 必须使用用户配置的 host/port（规格 26：端口可配置）。
        self.discovery = discovery ?? LocalHarnessDiscovery(host: settings.host, port: settings.port)
        self.compatibilityResolver = compatibilityResolver
    }

    /// 应用启动时调用。
    func start() {
        guard connectionState == .unknown else { return }
        Task { await performDiscovery() }
    }

    /// 用户点击「重新检测」时调用。
    func rediscover() {
        healthCheckTask?.cancel()
        handshakeTask?.cancel()
        eventTask?.cancel()
        tearDownNativeAdapter()
        webModel = nil
        harnessInfo = nil
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

    /// 设置变更后调用：用新 host/port 重建 Discovery 并重新探测。
    func settingsDidChange() {
        discovery = LocalHarnessDiscovery(host: settings.host, port: settings.port)
        healthCheckTask?.cancel()
        handshakeTask?.cancel()
        eventTask?.cancel()
        tearDownNativeAdapter()
        webModel = nil
        harnessInfo = nil
        reducer = ActivityReducer()
        Task { await performDiscovery() }
    }

    /// 释放 Native Adapter（断开事件流）。
    private func tearDownNativeAdapter() {
        if let adapter = nativeAdapter {
            Task { await adapter.disconnect() }
        }
        nativeAdapter = nil
    }

    // MARK: - Private

    private func performDiscovery() async {
        updateState(.discovering)
        guard let endpoint = await discovery.discover() else {
            updateState(.unavailable)
            return
        }
        connect(to: endpoint)
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
        // transient 完成事件（Phase 6 转通知）；session id 截断记录。
        let completions = reducer.drainCompletions()
        for completion in completions {
            AppLogger.activity.info("任务完成（session \(completion.sessionID.prefix(8)), privacy: .public)")
        }
        AppLogger.activity.debug("Domain event：\(event.typeName, privacy: .public)")
    }
}
