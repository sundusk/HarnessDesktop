import Foundation

/// Adapter 输出的统一 Domain Event（规格 18）。
///
/// Phase 3 仅定义契约；事件流在 Phase 4（WebSocket Event Layer）接入。
enum HarnessDomainEvent: Sendable {
    case sessionAdded(id: String)
    case sessionRemoved(id: String)
    case sessionRunningChanged(id: String, running: Bool)
    case approvalRequested(sessionID: String)
    case approvalResolved(sessionID: String)
    case questionRequested(sessionID: String)
    case questionResolved(sessionID: String)
    case agentError(sessionID: String, message: String)
    case taskCompleted(sessionID: String)
}

/// Harness 协议适配层（规格 18）。
///
/// 上层（ActivityReducer / Presentation）不依赖具体 Harness wire model，
/// 只消费本协议输出的统一 Domain Event。
protocol HarnessProtocolAdapter: Sendable {
    var supportedVersionRange: ClosedRange<String>? { get }

    func connect() async throws
    func disconnect() async

    var events: AsyncStream<HarnessDomainEvent> { get }
}

/// 通用适配器：基于 HTTP Transport 的 `host.describe` 握手。
///
/// Phase 3 实现 describe；events 流在 Phase 4 接入 WebSocket 后填充。
///
/// `@unchecked Sendable` 理由：所有成员均为 Sendable 值类型，
/// 唯一可变状态 `_harnessInfo` 由 `NSLock` 保护。
final class HarnessGenericAdapter: HarnessProtocolAdapter, @unchecked Sendable {
    var supportedVersionRange: ClosedRange<String>? { nil }

    private let endpoint: HarnessEndpoint
    private let transport: HarnessHTTPTransport
    private let eventsStream: AsyncStream<HarnessDomainEvent>
    private let eventsContinuation: AsyncStream<HarnessDomainEvent>.Continuation
    private let lock = NSLock()
    private var _harnessInfo: HarnessDescribeInfo?

    var harnessInfo: HarnessDescribeInfo? {
        lock.withLock { _harnessInfo }
    }

    init(endpoint: HarnessEndpoint, transport: HarnessHTTPTransport = HarnessHTTPTransport()) {
        self.endpoint = endpoint
        self.transport = transport
        (eventsStream, eventsContinuation) = AsyncStream.makeStream(of: HarnessDomainEvent.self)
    }

    /// Compatibility Handshake：`host.describe` 成功即视为 Native API 可用。
    func connect() async throws {
        let info = try await transport.describe(endpoint: endpoint)
        lock.withLock { _harnessInfo = info }
    }

    func disconnect() async {
        eventsContinuation.finish()
    }

    var events: AsyncStream<HarnessDomainEvent> { eventsStream }
}
