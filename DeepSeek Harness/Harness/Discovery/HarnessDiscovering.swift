import Foundation

/// Harness 发现协议。
protocol HarnessDiscovering: Sendable {
    /// 探测并返回可用端点；未发现返回 `nil`。
    func discover() async -> HarnessEndpoint?
}
