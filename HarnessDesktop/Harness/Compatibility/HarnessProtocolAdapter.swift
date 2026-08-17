import Foundation

/// Adapter 输出的统一 Domain Event（规格 18）。
///
/// 上层（ActivityReducer / Presentation）只依赖本协议输出，
/// 不依赖具体 Harness wire model。
enum HarnessDomainEvent: Equatable, Sendable {
    case sessionAdded(id: String)
    case sessionRemoved(id: String)
    case sessionRunningChanged(id: String, running: Bool)
    case approvalRequested(sessionID: String)
    case approvalResolved(sessionID: String)
    case questionRequested(sessionID: String)
    case questionResolved(sessionID: String)
    case agentError(sessionID: String, message: String)
    case taskCompleted(sessionID: String)

    /// 事件类型名（用于非敏感日志，不含 session 内容）。
    var typeName: String {
        switch self {
        case .sessionAdded: return "sessionAdded"
        case .sessionRemoved: return "sessionRemoved"
        case .sessionRunningChanged: return "sessionRunningChanged"
        case .approvalRequested: return "approvalRequested"
        case .approvalResolved: return "approvalResolved"
        case .questionRequested: return "questionRequested"
        case .questionResolved: return "questionResolved"
        case .agentError: return "agentError"
        case .taskCompleted: return "taskCompleted"
        }
    }
}

/// Harness 协议适配层（规格 18）。
///
/// 上层不依赖具体 Harness wire model，只消费本协议输出的统一 Domain Event。
protocol HarnessProtocolAdapter: Sendable {
    var supportedVersionRange: ClosedRange<String>? { get }

    func connect() async throws
    func disconnect() async

    var events: AsyncStream<HarnessDomainEvent> { get }
}

/// 事件流连接状态（规格 20，用于诊断 / 测试）。
enum HarnessStreamState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting
}

/// 通用适配器：`host.describe` 握手 + 双事件流（mux / host）消费。
///
/// - 流断开后按退避策略自动重连：500ms / 1s / 2s / 4s / 8s / 10s / 10s…（+少量 jitter）；
/// - 单条坏帧跳过，绝不拖垮整个流（规格 19）；
/// - 双流独立重连，任一流恢复后自动继续（Harness 重启后能够恢复）。
///
/// `@unchecked Sendable` 理由：所有成员均为 Sendable 值类型，
/// 可变状态（`_harnessInfo`、`_streamState`、`_openStreams`）由 `NSLock` 保护。
final class HarnessGenericAdapter: HarnessProtocolAdapter, @unchecked Sendable {
    var supportedVersionRange: ClosedRange<String>? { nil }

    private let endpoint: HarnessEndpoint
    private let transport: HarnessHTTPTransport
    private let webSocketTransport: HarnessWebSocketTransport
    private let eventsStream: AsyncStream<HarnessDomainEvent>
    private let eventsContinuation: AsyncStream<HarnessDomainEvent>.Continuation

    private let lock = NSLock()
    private var _harnessInfo: HarnessDescribeInfo?
    private var _streamState: HarnessStreamState = .disconnected
    private var _openStreams: Set<String> = []

    private var streamsTask: Task<Void, Never>?

    /// 退避延迟（秒）：500ms / 1s / 2s / 4s / 8s / 10s / 10s…（规格 20）。
    private static let backoffDelays: [Duration] = [
        .milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(10), .seconds(10),
    ]

    var harnessInfo: HarnessDescribeInfo? {
        lock.withLock { _harnessInfo }
    }

    var streamState: HarnessStreamState {
        lock.withLock { _streamState }
    }

    init(endpoint: HarnessEndpoint,
         transport: HarnessHTTPTransport = HarnessHTTPTransport(),
         webSocketTransport: HarnessWebSocketTransport = HarnessWebSocketTransport()) {
        self.endpoint = endpoint
        self.transport = transport
        self.webSocketTransport = webSocketTransport
        (eventsStream, eventsContinuation) = AsyncStream.makeStream(of: HarnessDomainEvent.self)
    }

    /// Compatibility Handshake：`host.describe` 成功 → 打开 mux / host 双事件流。
    func connect() async throws {
        let info = try await transport.describe(endpoint: endpoint)
        lock.withLock { _harnessInfo = info }
        startEventStreams()
    }

    func disconnect() async {
        streamsTask?.cancel()
        streamsTask = nil
        lock.withLock {
            _openStreams = []
            _streamState = .disconnected
        }
        eventsContinuation.finish()
    }

    var events: AsyncStream<HarnessDomainEvent> { eventsStream }

    // MARK: - Private

    private func startEventStreams() {
        streamsTask?.cancel()
        streamsTask = Task { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.consumeStream(path: HarnessProtocolPath.muxEvents) }
                group.addTask { await self.consumeStream(path: HarnessProtocolPath.hostEvents) }
                await group.waitForAll()
            }
        }
    }

    /// 单个流的消费循环：断线后按退避策略重连，直到任务取消。
    private func consumeStream(path: String) async {
        var attempt = 0
        while !Task.isCancelled {
            if attempt > 0 {
                let index = min(attempt - 1, Self.backoffDelays.count - 1)
                let jitter = Duration.milliseconds(Int.random(in: 0...300))
                try? await Task.sleep(for: Self.backoffDelays[index] + jitter)
            }
            attempt += 1
            guard !Task.isCancelled else { return }

            AppLogger.compatibility.info("事件流连接中：\(path, privacy: .public)")
            let stream = webSocketTransport.openStream(path: path, endpoint: endpoint) { [weak self] in
                self?.markStreamOpened(path)
            }

            do {
                for try await frame in stream {
                    guard !Task.isCancelled else { return }
                    if let event = Self.mapFrame(frame) {
                        eventsContinuation.yield(event)
                    }
                }
                // 流正常结束（服务端关闭）→ 视为断开，进入重连。
                AppLogger.compatibility.info("事件流结束，准备重连：\(path, privacy: .public)")
            } catch {
                AppLogger.compatibility.error("事件流断开：\(path, privacy: .public) \(String(describing: error), privacy: .public)")
            }
            markStreamClosed(path)
        }
    }

    private func markStreamOpened(_ key: String) {
        lock.withLock {
            _openStreams.insert(key)
            _streamState = _openStreams == Set([HarnessProtocolPath.muxEvents, HarnessProtocolPath.hostEvents])
                ? .connected
                : .connecting
        }
    }

    private func markStreamClosed(_ key: String) {
        lock.withLock {
            _openStreams.remove(key)
            _streamState = _openStreams.isEmpty ? .disconnected : .reconnecting
        }
    }

    /// 帧 → Domain Event 映射。未知帧类型忽略（返回 nil，调用方记录）。
    static func mapFrame(_ frame: HarnessServerRequestFrame) -> HarnessDomainEvent? {
        guard let payload = try? JSONDecoder().decode(HarnessEventFrame.self, from: frame.payload) else {
            AppLogger.compatibility.debug("事件帧 payload 无法解析：method \(frame.method, privacy: .public)")
            return nil
        }

        switch payload.type {
        case "host/session-added", "session/subscribed":
            // session/subscribed：mux 基线帧，表示该 session 已附加 → 视为已存在。
            return payload.sessionId.map { .sessionAdded(id: $0) }
        case "host/session-removed":
            return payload.sessionId.map { .sessionRemoved(id: $0) }
        case "host/session-status":
            guard let sessionId = payload.sessionId, let running = payload.running else { return nil }
            return .sessionRunningChanged(id: sessionId, running: running)
        case "host/agent-error":
            guard let sessionId = payload.sessionId else { return nil }
            return .agentError(sessionID: sessionId, message: payload.message ?? "unknown")
        case "approval/requested":
            return payload.sessionId.map { .approvalRequested(sessionID: $0) }
        case "approval/resolved":
            return payload.sessionId.map { .approvalResolved(sessionID: $0) }
        case "question/requested":
            return payload.sessionId.map { .questionRequested(sessionID: $0) }
        case "question/resolved":
            return payload.sessionId.map { .questionResolved(sessionID: $0) }
        default:
            // 未知事件：忽略 + debug log（规格 19），不得关闭流。
            AppLogger.compatibility.debug("未知事件帧类型：\(payload.type, privacy: .public)")
            return nil
        }
    }
}
