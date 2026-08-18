import Foundation

/// Harness 连接状态。
///
/// 要求：UI 不直接推断网络状态；连接状态只由 Integration 层输出。
enum HarnessConnectionState: Equatable, Sendable {
    case unknown
    case discovering
    case unavailable
    case connecting
    case connected
    case reconnecting
    case degraded(reason: String)
}
