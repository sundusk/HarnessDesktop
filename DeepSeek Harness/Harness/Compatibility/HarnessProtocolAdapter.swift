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

/// 通用适配器：认证交换 + `session/list` 基线 + `$events` 事件流消费。
///
/// Wire contract 对照上游 `dsh-v0.1.2-alpha.1`（旧版 `host.describe` /
/// `events.mux` / `events.host` 已在该版本移除）：
///
/// - 握手 = 认证交换 + `session/list` 成功（同时验证认证、路由与协议版本）；
/// - 事件流 = `/api/remote.mux` WebSocket 上的 `$events` 逻辑流；
/// - `emit` 帧 → Domain Event；`waterfall` 帧 → requested 事件 + 应答 `next`
///   （纯观察者，绝不代替用户审批/答题；全部客户端放行后 Host 链才继续）；
/// - `cancel` 帧 → 对应 resolved 事件（被认领 / 全员放行 / 撤销都终结为 cancel）；
/// - 流断开后按退避策略自动重连：500ms / 1s / 2s / 4s / 8s / 10s / 10s…（+少量 jitter），
///   每次（重）连补拉一次 session 基线（emit 不回放）；
/// - 单条坏帧跳过，绝不拖垮整个流（规格 19）。
///
/// `@unchecked Sendable` 理由：可变状态（`_handshakeInfo`、`_clientId`、
/// `_streamState`、`_pendingWaterfalls`）中仅流转计数与心跳在锁外，
/// 共享状态全部由 `NSLock` 保护。
final class HarnessGenericAdapter: HarnessProtocolAdapter, @unchecked Sendable {
    var supportedVersionRange: ClosedRange<String>? { nil }

    private let endpoint: HarnessEndpoint
    private let transport: HarnessHTTPTransport
    private let webSocketTransport: HarnessWebSocketTransport
    private let eventsStream: AsyncStream<HarnessDomainEvent>
    private let eventsContinuation: AsyncStream<HarnessDomainEvent>.Continuation

    private let lock = NSLock()
    private var _handshakeInfo: HarnessHandshakeInfo?
    private var _clientId: String?
    private var _streamState: HarnessStreamState = .disconnected
    /// 待决 waterfall：eventId → (事件名, agentId)。仅在事件消费循环内读写。
    private var pendingWaterfalls: [String: (event: String, agentId: String?)] = [:]

    private var streamsTask: Task<Void, Never>?

    /// 退避延迟（秒）：500ms / 1s / 2s / 4s / 8s / 10s / 10s…（规格 20）。
    private static let backoffDelays: [Duration] = [
        .milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(10), .seconds(10),
    ]

    var handshakeInfo: HarnessHandshakeInfo? {
        lock.withLock { _handshakeInfo }
    }

    var streamState: HarnessStreamState {
        lock.withLock { _streamState }
    }

    init(endpoint: HarnessEndpoint,
         transport: HarnessHTTPTransport = HarnessHTTPTransport(),
         webSocketTransport: HarnessWebSocketTransport = HarnessWebSocketTransport()) {
        self.endpoint = endpoint
        if endpoint.authenticatedURL != nil,
           transport.session === URLSession.shared,
           webSocketTransport.session === URLSession.shared {
            // HTTP 的认证交换必须与 WebSocket 共用 Cookie 存储；否则 native 握手虽成功，
            // 事件流仍会被 Harness 的认证栅栏拒绝。
            let session = URLSession(configuration: .default)
            self.transport = HarnessHTTPTransport(session: session)
            self.webSocketTransport = HarnessWebSocketTransport(session: session)
        } else {
            self.transport = transport
            self.webSocketTransport = webSocketTransport
        }
        (eventsStream, eventsContinuation) = AsyncStream.makeStream(of: HarnessDomainEvent.self)
    }

    /// Compatibility Handshake：认证交换 + session 基线成功 → 打开 `$events` 流。
    func connect() async throws {
        try await transport.authenticate(endpoint: endpoint)
        // 新协议没有 host.describe：session/list 同时充当协议可达性探测与基线来源。
        let baseline = try await transport.listSessions(endpoint: endpoint)
        lock.withLock {
            _handshakeInfo = HarnessHandshakeInfo(hostHome: nil)
            _clientId = nil
        }
        startEventStreams(baseline: baseline)
    }

    func disconnect() async {
        streamsTask?.cancel()
        streamsTask = nil
        lock.withLock {
            _clientId = nil
            pendingWaterfalls.removeAll()
            _streamState = .disconnected
        }
        eventsContinuation.finish()
    }

    var events: AsyncStream<HarnessDomainEvent> { eventsStream }

    // MARK: - Mapping（纯函数，供单测）

    /// session 基线 → Domain Events（added + 可选 running 同步）。
    static func domainEvents(forSummary summary: HarnessSessionSummary) -> [HarnessDomainEvent] {
        var events: [HarnessDomainEvent] = [.sessionAdded(id: summary.sessionId)]
        if summary.running == true {
            events.append(.sessionRunningChanged(id: summary.sessionId, running: true))
        }
        return events
    }

    /// `emit` 帧 → Domain Events。未知事件返回空数组（规格 19：忽略，不得关流）。
    ///
    /// 事件名与 args 形状对照上游 `packages/api/session-controller/src/index.ts`：
    /// - `api-session/added`   `[summary{sessionId,running,...}]`
    /// - `api-session/removed` `[sessionId]`
    /// - `api-session/status`  `[sessionId, Bool]`（Bool = status === 'running'）
    /// - `api-session/error`   `[sessionId, message]`
    /// - `api-session/activity`（无领域对应，忽略）
    static func domainEvents(forEmit event: String, args: [HarnessJSONValue]) -> [HarnessDomainEvent] {
        switch event {
        case "api-session/added":
            guard let summary = args.first else { return [] }
            guard let id = summary["sessionId"]?.stringValue else { return [] }
            var events: [HarnessDomainEvent] = [.sessionAdded(id: id)]
            if summary["running"]?.boolValue == true {
                events.append(.sessionRunningChanged(id: id, running: true))
            }
            return events
        case "api-session/removed":
            guard let id = args.first?.stringValue else { return [] }
            return [.sessionRemoved(id: id)]
        case "api-session/status":
            guard let id = args.first?.stringValue else { return [] }
            guard let running = args.dropFirst().first?.boolValue else { return [] }
            return [.sessionRunningChanged(id: id, running: running)]
        case "api-session/error":
            guard let id = args.first?.stringValue else { return [] }
            let message = args.dropFirst().first?.stringValue ?? "unknown"
            return [.agentError(sessionID: id, message: message)]
        default:
            // 未知事件：忽略 + debug log（规格 19），不得关闭流。
            AppLogger.compatibility.debug("未知 emit 事件：\(event, privacy: .public)")
            return []
        }
    }

    /// `waterfall` 交付 → Domain Event（观察者视角：开始等待 → requested）。
    static func domainEvent(fromWaterfall event: String, agentId: String?) -> HarnessDomainEvent? {
        guard let agentId, !agentId.isEmpty else { return nil }
        switch event {
        case "approval/request":
            return .approvalRequested(sessionID: agentId)
        case "user-questions/request":
            return .questionRequested(sessionID: agentId)
        default:
            AppLogger.compatibility.debug("未知 waterfall 事件：\(event, privacy: .public)")
            return nil
        }
    }

    /// `cancel` 帧 → Domain Event（等待终结 → resolved）。
    static func resolutionEvent(forWaterfall event: String, agentId: String?) -> HarnessDomainEvent? {
        guard let agentId, !agentId.isEmpty else { return nil }
        switch event {
        case "approval/request":
            return .approvalResolved(sessionID: agentId)
        case "user-questions/request":
            return .questionResolved(sessionID: agentId)
        default:
            return nil
        }
    }

    // MARK: - Private

    private func startEventStreams(baseline: [HarnessSessionSummary]) {
        streamsTask?.cancel()
        // 先补基线（emit 不回放；reducer 对 sessionAdded 幂等、对 running 同步安全）。
        for summary in baseline {
            for event in Self.domainEvents(forSummary: summary) {
                eventsContinuation.yield(event)
            }
        }
        streamsTask = Task { [weak self] in
            await self?.consumeEventStream()
        }
    }

    /// 事件流消费循环：断线后按退避策略重连，直到任务取消。
    private func consumeEventStream() async {
        var attempt = 0
        while !Task.isCancelled {
            if attempt > 0 {
                let index = min(attempt - 1, Self.backoffDelays.count - 1)
                let jitter = Duration.milliseconds(Int.random(in: 0...300))
                try? await Task.sleep(for: Self.backoffDelays[index] + jitter)
            }
            attempt += 1
            guard !Task.isCancelled else { return }

            do {
                // 每次（重）连补拉基线：覆盖断线期间错过的 session 增删与状态迁移。
                let baseline = try await transport.listSessions(endpoint: endpoint)
                guard !Task.isCancelled else { return }
                for summary in baseline {
                    for event in Self.domainEvents(forSummary: summary) {
                        eventsContinuation.yield(event)
                    }
                }
                AppLogger.compatibility.info("事件流连接中：\(HarnessProtocolPath.remoteMux, privacy: .public)")
                for try await frame in webSocketTransport.openEventStream(endpoint: endpoint) {
                    guard !Task.isCancelled else { return }
                    handle(frame: frame)
                }
                // 流正常结束（服务端关闭）→ 视为断开，进入重连。
                AppLogger.compatibility.info("事件流结束，准备重连")
            } catch {
                AppLogger.compatibility.error(
                    "事件流断开：\(String(describing: error), privacy: .public)"
                )
            }
            markStreamClosed()
        }
    }

    /// 单帧处理：ready / emit / waterfall / cancel。
    private func handle(frame: HarnessRemoteEventFrame) {
        switch frame {
        case .ready(let clientId, let hostHome):
            lock.withLock {
                _clientId = clientId
                _handshakeInfo = HarnessHandshakeInfo(hostHome: hostHome)
                _streamState = .connected
            }
        case .emit(let event, let args):
            for event in Self.domainEvents(forEmit: event, args: args) {
                eventsContinuation.yield(event)
            }
        case .waterfall(let event, let eventId, let agentId, _):
            if let domainEvent = Self.domainEvent(fromWaterfall: event, agentId: agentId) {
                eventsContinuation.yield(domainEvent)
            }
            pendingWaterfalls[eventId] = (event, agentId)
            acknowledge(eventId: eventId)
        case .cancelled(let eventId):
            if let pending = pendingWaterfalls.removeValue(forKey: eventId),
               let domainEvent = Self.resolutionEvent(forWaterfall: pending.event, agentId: pending.agentId) {
                eventsContinuation.yield(domainEvent)
            }
        }
    }

    /// 对单个 waterfall 交付应答 `next`（异步子任务，失败不拖垮事件循环）。
    private func acknowledge(eventId: String) {
        let clientId = lock.withLock { _clientId }
        guard let clientId else {
            AppLogger.compatibility.debug("waterfall 到达时还没有 ready 帧，跳过应答")
            return
        }
        let transport = self.transport
        let endpoint = self.endpoint
        Task {
            await transport.sendEventResult(endpoint: endpoint, clientId: clientId, eventId: eventId)
        }
    }

    private func markStreamClosed() {
        lock.withLock {
            _clientId = nil
            pendingWaterfalls.removeAll()
            _streamState = .disconnected
        }
    }
}
