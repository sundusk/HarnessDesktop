import Foundation
import Observation

/// 应用级协调器：编排 Discovery / WebView / 连接状态机。
///
/// 这是 orchestration，不是 God Object —— 业务逻辑分布在各自模块中。
@MainActor
@Observable
final class AppCoordinator {
    /// 连接状态只由 Integration 层输出，UI 不得自行推断。
    private(set) var connectionState: HarnessConnectionState = .unknown
    private(set) var webModel: HarnessWebViewModel?

    let settings: AppSettings
    /// 内部可见：协议边界可 mock（规格 29.10），测试可注入或校验。
    let discovery: any HarnessDiscovering
    private var healthCheckTask: Task<Void, Never>?

    init(settings: AppSettings = AppSettings(),
         discovery: (any HarnessDiscovering)? = nil) {
        self.settings = settings
        // 默认 Discovery 必须使用用户配置的 host/port（规格 26：端口可配置）。
        self.discovery = discovery ?? LocalHarnessDiscovery(host: settings.host, port: settings.port)
    }

    /// 应用启动时调用。
    func start() {
        guard connectionState == .unknown else { return }
        Task { await performDiscovery() }
    }

    /// 用户点击「重新检测」时调用。
    func rediscover() {
        healthCheckTask?.cancel()
        webModel = nil
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
}
