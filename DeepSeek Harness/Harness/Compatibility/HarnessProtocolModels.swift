import Foundation

/// Harness 协议端点（规格 16：集中管理，防止散落代码）。
///
/// Wire contract 已对照上游 `dsh-v0.1.2-alpha.1` 源码确认：
/// - `packages/api/gateway/src/stream-protocol.ts`（remote.mux / $events / 结果 RPC）；
/// - `packages/client/connection/src/client/rpc.ts`（`POST /api/<endpoint>` 信封）；
/// - `packages/api/session-controller/src`（`session/list` 与事件名）。
///
/// ⚠️ 上游处于快速迭代阶段（旧版 `host.describe` / `events.mux` / `events.host`
/// 已在 dsh-v0.1.2-alpha.1 移除）；协议版本化时只修改本层。
enum HarnessProtocolPath {
    /// RPC 频道前缀：每个调用是 `POST /api/<namespace>/<method>`。
    static let api = "/api"
    /// 事件流 WebSocket 升级路径（Typert Remote 流复用器）。
    static let remoteMux = "/api/remote.mux"
    /// Gateway 内部事件流逻辑端点（open 消息的 `endpoint` 字段值）。
    static let remoteEventStreamEndpoint = "$events"
    /// Client Remote Event 结果 RPC 的 endpoint（`POST /api/$events/result`）。
    static let remoteEventResultEndpoint = "$events/result"
    /// Session 基线 RPC 的 endpoint（`POST /api/session/list`）。
    static let sessionListEndpoint = "session/list"
}

/// 握手信息。
///
/// 新协议没有 `host.describe`：**运行版本无法从协议读取**，按仓库 AGENTS.md
/// 约束必须降级为 unknown，绝不以 npm / npx / 路径推断回填。
/// `hostHome` 来自 `$events` 流 ready 帧（上游仅用于缩短路径显示，同样不作版本用途）。
struct HarnessHandshakeInfo: Equatable, Sendable {
    let hostHome: String?
}

/// `session/list` 返回的单条 session 概要。
///
/// 解码原则（规格 19）：Parse what we need, ignore what we do not need。
/// 上游 `SessionSummary` 为必填 `running`；宽容起见仍按 Optional 处理。
struct HarnessSessionSummary: Decodable, Equatable, Sendable {
    let sessionId: String
    let running: Bool?
    let updatedAt: Double?
}

/// `session/list` 响应值。
struct HarnessSessionListValue: Decodable, Equatable, Sendable {
    let items: [HarnessSessionSummary]
}

/// `$events/result` RPC 的响应值（上游返回 `value: undefined`）。
struct HarnessRPCEmptyValue: Decodable, Sendable {}

/// RPC 信封（envelope）。请求与响应形态见上游 `client/connection/src/rpc.ts`：
/// - ClientRequest:  `{"type":"client-request","rpcId","method","payload":{"args":{...}}}`
/// - ServerResponse: `{"type":"server-response","rpcId","result":{"ok","value"|"error"}}`
///
/// `value` 按调用点类型化（session/list → 列表值；$events/result → 空值）。
enum HarnessRPCEnvelope {
    struct Response<Value: Decodable>: Decodable {
        let type: String
        let rpcId: String
        let result: Result

        struct Result: Decodable {
            let ok: Bool
            /// 失败分支可能不含 value / error 字段——Optional 宽容处理。
            let value: Value?
            let error: RPCError?
        }

        struct RPCError: Decodable {
            let code: String?
            let message: String?
        }
    }
}

/// RPC 请求体（泛型 args，全部走 JSONEncoder，避免 Any 序列化）。
struct HarnessRPCRequest<Args: Encodable & Sendable>: Encodable {
    let type: String
    let rpcId: String
    let method: String
    let payload: Payload

    init(method: String, args: Args) {
        self.type = "client-request"
        self.rpcId = UUID().uuidString.lowercased()
        self.method = method
        self.payload = Payload(args: args)
    }

    struct Payload: Encodable {
        let args: Args
    }
}

/// 空 args 对象（编码为 `{}`）。
struct HarnessRPCArgsEmpty: Encodable, Sendable {}

/// `session/list` 的 args：上游按参数名 `_request` 绑定（cursor 可选，留空）。
struct HarnessRPCSessionListArgs: Encodable, Sendable {
    let _request: HarnessRPCArgsEmpty

    init() {
        self._request = HarnessRPCArgsEmpty()
    }
}

/// `$events/result` 的 args：观察者对每个 waterfall 交付固定应答 `next`
/// （放行给 Host 瀑布链的下一个监听者——审批 UI 等——绝不代替用户做决定）。
struct HarnessRPCEventResultArgs: Encodable, Sendable {
    let clientId: String
    let eventId: String
    let outcome: Outcome

    init(clientId: String, eventId: String) {
        self.clientId = clientId
        self.eventId = eventId
        self.outcome = Outcome()
    }

    struct Outcome: Encodable, Sendable {
        let kind: String

        init() {
            self.kind = "next"
        }
    }
}
