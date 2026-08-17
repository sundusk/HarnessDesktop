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
    private let discovery: any HarnessDiscovering
    private var healthCheckTask: Task<Void, Never>?

    init(settings: AppSettings = AppSettings(),
         discovery: any HarnessDiscovering = LocalHarnessDiscovery()) {
        self.settings = settings
        self.discovery = discovery
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
        connectionState = .discovering
        guard let endpoint = await discovery.discover() else {
            connectionState = .unavailable
            return
        }
        connect(to: endpoint)
    }

    private func connect(to endpoint: HarnessEndpoint) {
        connectionState = .connected
        let model = HarnessWebViewModel(endpoint: endpoint)
        webModel = model
        model.loadInitial()
        startHealthCheck()
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
                self.connectionState = .unavailable
                self.webModel = nil
                return
            }
        }
    }
}
