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
/// - `emit` 帧 → Domain Event；其中 `parentSessionId` 非空的 **子会话（subagent）**
///   及其 status / error 事件被过滤掉，不进入全局宠物状态（子会话是一次性的，
///   其错误/完成会永久污染全局优先级，见 ActivityReducer 的容忍设计）；
/// - `waterfall` 帧 → requested 事件。**本 App 是纯观察者，绝不代替用户审批/答题，
///   也绝不主动应答 `next`**：web UI 客户端（内嵌 WKWebView）会持有瀑布并等待用户，
///   用户作答后以 result 终结，或 agent 中止 / 作用域释放时撤销——上述每条终结路径
///   都会给仍在投递列表中的本客户端补发 `cancel` 帧。主动应答 `next` 反而会把本
///   客户端移出投递列表，从此观察不到解决（宠物会永远卡在「做出你的抉择」）；
/// - `cancel` 帧 → 对应 resolved 事件（被认领 / 全员放行 / 撤销都终结为 cancel）；
/// - 流断开后按退避策略自动重连：500ms / 1s / 2s / 4s / 8s / 10s / 10s…（+少量 jitter），
///   每次（重）连补拉一次 session 基线（emit 不回放）；断开时未决 waterfall 视为
///   已终结（补发 resolved），避免门跨连接悬置；
/// - 单条坏帧跳过，绝不拖垮整个流（规格 19）。
///
/// `@unchecked Sendable` 理由：可变状态（`_handshakeInfo`、`_clientId`、
/// `_streamState`、`_pendingWaterfalls`、`_childSessionIDs`）中仅心跳在锁外，
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
    /// 待决 waterfall：eventId → (事件名, agentId)。全部访问由 `lock` 保护。
    private var pendingWaterfalls: [String: (event: String, agentId: String?)] = [:]
    /// 已知子会话（subagent）id：从基线 / `api-session/added` 的 parentSessionId 学习。
    /// 子会话的 status / error / 审批 / 提问一律不进入全局状态。
    private var childSessionIDs: Set<String> = []

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
        // 未决 waterfall 视为已终结：补发 resolved，门不跨连接悬置。
        resolvePendingWaterfalls()
        lock.withLock {
            _clientId = nil
            pendingWaterfalls.removeAll()
            childSessionIDs.removeAll()
            _streamState = .disconnected
        }
        eventsContinuation.finish()
    }

    var events: AsyncStream<HarnessDomainEvent> { eventsStream }

    // MARK: - Mapping（纯函数，供单测）

    /// 一帧 emit 的映射结果：领域事件 + 本帧新发现的子会话 id。
    ///
    /// `childIDs` 供调用方登记（子会话不产生领域事件，但必须被记住，
    /// 以便后续 status / error / 审批 / 提问帧按 id 过滤）。
    struct HarnessEmitMapping: Equatable, Sendable {
        let events: [HarnessDomainEvent]
        let childIDs: Set<String>

        init(events: [HarnessDomainEvent], childIDs: Set<String> = []) {
            self.events = events
            self.childIDs = childIDs
        }
    }

    /// session 基线 → Domain Events（added + 可选 running 同步）。
    ///
    /// 子会话（`parentSessionId` 非空）不产生领域事件，id 交给调用方登记。
    static func mappedEvents(forSummary summary: HarnessSessionSummary,
                             knownChildIDs: Set<String>) -> HarnessEmitMapping {
        if knownChildIDs.contains(summary.sessionId) {
            // 已登记的子会话（重连基线重复出现）：不补发、不重复登记。
            return HarnessEmitMapping(events: [])
        }
        if summary.parentSessionId != nil {
            return HarnessEmitMapping(events: [], childIDs: [summary.sessionId])
        }
        var events: [HarnessDomainEvent] = [.sessionAdded(id: summary.sessionId)]
        if summary.running == true {
            events.append(.sessionRunningChanged(id: summary.sessionId, running: true))
        }
        return HarnessEmitMapping(events: events)
    }

    /// session 基线 → Domain Events（不含子会话过滤的纯映射，兼容单测）。
    static func domainEvents(forSummary summary: HarnessSessionSummary) -> [HarnessDomainEvent] {
        mappedEvents(forSummary: summary, knownChildIDs: []).events
    }

    /// `emit` 帧 → Domain Events。未知事件返回空数组（规格 19：忽略，不得关流）。
    ///
    /// 事件名与 args 形状对照上游 `packages/api/session-controller/src/index.ts`：
    /// - `api-session/added`   `[summary{sessionId,running,parentSessionId,...}]`
    /// - `api-session/removed` `[sessionId]`
    /// - `api-session/status`  `[sessionId, Bool]`（Bool = status === 'running'）
    /// - `api-session/error`   `[sessionId, message]`
    /// - `api-session/activity`（无领域对应，忽略）
    ///
    /// 子会话过滤：`added` 中 `parentSessionId` 非空 → 不产生事件、id 交调用方登记；
    /// 已登记子会话 id 的 status / error / removed → 忽略（子会话是一次性 agent，
    /// 其错误 / 完成进入 reducer 会永久污染全局状态——该 id 不会再 running=true 来清除）。
    static func mappedEvents(forEmit event: String,
                             args: [HarnessJSONValue],
                             knownChildIDs: Set<String>) -> HarnessEmitMapping {
        switch event {
        case "api-session/added":
            guard let summary = args.first else { return HarnessEmitMapping(events: []) }
            guard let id = summary["sessionId"]?.stringValue else { return HarnessEmitMapping(events: []) }
            if knownChildIDs.contains(id) {
                // 已登记的子会话：不补发、不重复登记。
                return HarnessEmitMapping(events: [])
            }
            if summary["parentSessionId"]?.stringValue != nil {
                return HarnessEmitMapping(events: [], childIDs: [id])
            }
            var events: [HarnessDomainEvent] = [.sessionAdded(id: id)]
            if summary["running"]?.boolValue == true {
                events.append(.sessionRunningChanged(id: id, running: true))
            }
            return HarnessEmitMapping(events: events)
        case "api-session/removed":
            guard let id = args.first?.stringValue else { return HarnessEmitMapping(events: []) }
            if knownChildIDs.contains(id) { return HarnessEmitMapping(events: []) }
            return HarnessEmitMapping(events: [.sessionRemoved(id: id)])
        case "api-session/status":
            guard let id = args.first?.stringValue else { return HarnessEmitMapping(events: []) }
            if knownChildIDs.contains(id) { return HarnessEmitMapping(events: []) }
            guard let running = args.dropFirst().first?.boolValue else { return HarnessEmitMapping(events: []) }
            return HarnessEmitMapping(events: [.sessionRunningChanged(id: id, running: running)])
        case "api-session/error":
            guard let id = args.first?.stringValue else { return HarnessEmitMapping(events: []) }
            if knownChildIDs.contains(id) { return HarnessEmitMapping(events: []) }
            let message = args.dropFirst().first?.stringValue ?? "unknown"
            return HarnessEmitMapping(events: [.agentError(sessionID: id, message: message)])
        default:
            // 未知事件：忽略 + debug log（规格 19），不得关闭流。
            AppLogger.compatibility.debug("未知 emit 事件：\(event, privacy: .public)")
            return HarnessEmitMapping(events: [])
        }
    }

    /// `emit` 帧 → Domain Events（不含子会话过滤的纯映射，兼容单测）。
    static func domainEvents(forEmit event: String, args: [HarnessJSONValue]) -> [HarnessDomainEvent] {
        mappedEvents(forEmit: event, args: args, knownChildIDs: []).events
    }

    /// 判断一帧 `api-session/added` 的 summary 是否子会话（subagent）。
    static func isChildSessionSummary(_ summary: HarnessJSONValue) -> Bool {
        summary["parentSessionId"]?.stringValue != nil
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
            emitBaseline(summary)
        }
        streamsTask = Task { [weak self] in
            await self?.consumeEventStream()
        }
    }

    /// 补发一条基线 summary（子会话只登记 id，不产生领域事件）。
    private func emitBaseline(_ summary: HarnessSessionSummary) {
        let known = lock.withLock { childSessionIDs }
        let mapping = Self.mappedEvents(forSummary: summary, knownChildIDs: known)
        if !mapping.childIDs.isEmpty {
            lock.withLock { childSessionIDs.formUnion(mapping.childIDs) }
            AppLogger.compatibility.debug(
                "基线跳过子会话：\(summary.sessionId, privacy: .public)"
            )
        }
        for event in mapping.events {
            eventsContinuation.yield(event)
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
                    emitBaseline(summary)
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
            let known = lock.withLock { childSessionIDs }
            let mapping = Self.mappedEvents(forEmit: event, args: args, knownChildIDs: known)
            if !mapping.childIDs.isEmpty {
                lock.withLock { childSessionIDs.formUnion(mapping.childIDs) }
                AppLogger.compatibility.debug("跳过子会话事件：\(event, privacy: .public)")
            }
            for domainEvent in mapping.events {
                eventsContinuation.yield(domainEvent)
            }
        case .waterfall(let event, let eventId, let agentId, _):
            // 子会话（subagent）的审批 / 提问不进入全局宠物状态；
            // web UI 客户端仍会独立收到该 waterfall 并向用户展示。
            if let agentId, lock.withLock({ childSessionIDs.contains(agentId) }) {
                break
            }
            if let domainEvent = Self.domainEvent(fromWaterfall: event, agentId: agentId) {
                eventsContinuation.yield(domainEvent)
            }
            // 纯观察者：不应答 next，保持留在 Gateway 投递列表中——
            // 用户作答 / 撤销 / agent 中止 / 作用域释放时都会收到 cancel 帧，
            // 那就是唯一可靠的「已解决」信号。
            lock.withLock { pendingWaterfalls[eventId] = (event, agentId) }
        case .cancelled(let eventId):
            let pending = lock.withLock { pendingWaterfalls.removeValue(forKey: eventId) }
            if let pending,
               let domainEvent = Self.resolutionEvent(forWaterfall: pending.event, agentId: pending.agentId) {
                eventsContinuation.yield(domainEvent)
            }
        }
    }

    /// 未决 waterfall 全部补发 resolved（流断开 / 主动断开时调用），
    /// 使 reducer 的审批 / 提问门不跨连接悬置。
    private func resolvePendingWaterfalls() {
        let pending = lock.withLock {
            let values = pendingWaterfalls
            pendingWaterfalls.removeAll()
            return values
        }
        for (_, waterfall) in pending {
            if let domainEvent = Self.resolutionEvent(forWaterfall: waterfall.event, agentId: waterfall.agentId) {
                eventsContinuation.yield(domainEvent)
            }
        }
    }

    private func markStreamClosed() {
        resolvePendingWaterfalls()
        lock.withLock {
            _clientId = nil
            pendingWaterfalls.removeAll()
            _streamState = .disconnected
        }
    }
}
