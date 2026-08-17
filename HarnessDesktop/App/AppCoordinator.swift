import Foundation
import Observation

/// 应用级协调器：编排 Discovery / WebView / 状态机。
///
/// 这是 orchestration，不是 God Object —— 业务逻辑分布在各自模块中。
@MainActor
@Observable
final class AppCoordinator {
    /// 连接状态只由 Integration 层输出，UI 不得自行推断。
    private(set) var connectionState: HarnessConnectionState = .unknown

    let settings: AppSettings

    init(settings: AppSettings = AppSettings()) {
        self.settings = settings
    }

    /// 应用启动时调用。
    ///
    /// Phase 0 为骨架实现；Phase 1 在此接入 LocalHarnessDiscovery。
    func start() {
        connectionState = .discovering
        // Phase 1: 接入真实 Discovery 并连接 Harness。
        connectionState = .unavailable
    }

    /// 用户点击「重新检测」时调用。
    func rediscover() {
        // Phase 1: 重新探测 loopback 端点。
    }

    /// 重新加载 Harness Web UI。
    func reload() {
        // Phase 1: 转发给 HarnessWebViewModel。
    }

    /// 在默认浏览器中打开 Harness。
    func openInBrowser() {
        // Phase 1: 使用 NSWorkspace 打开端点。
    }
}
