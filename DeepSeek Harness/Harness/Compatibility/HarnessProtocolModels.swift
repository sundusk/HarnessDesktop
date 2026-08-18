import Foundation

/// Harness 协议路径（规格 16：集中管理，防止散落代码）。
///
/// ⚠️ 路径与 schema 都属于可能变化的上游协议；协议版本化时只修改本层。
enum HarnessProtocolPath {
    static let api = "/api"
    static let hostDescribe = "/api/host.describe"
    static let muxEvents = "/api/events.mux"
    static let hostEvents = "/api/events.host"
}

/// `host.describe` 响应值（wire contract 已对照上游源码与真实实例确认）。
///
/// 解码原则（规格 19）：Parse what we need, ignore what we do not need。
/// 只声明必需字段；可选字段用 Optional；上游新增字段自动忽略。
struct HarnessDescribeInfo: Decodable, Equatable, Sendable {
    let version: String
    let cwd: String
    let provider: String?
    let model: String?
    let attachedSessions: Int
    let canOpenPath: Bool
}

/// RPC 信封（envelope）。请求与响应形态见上游 `rpc.d.ts`：
/// - ClientRequest:  `{"type":"client-request","rpcId","method","payload"}`
/// - ServerResponse: `{"type":"server-response","rpcId","result":{"ok","value"|"error"}}`
enum HarnessRPCEnvelope {
    struct Request: Encodable {
        let type = "client-request"
        let rpcId: String
        let method: String
        let payload: [String: String]
    }

    struct Response: Decodable {
        let type: String
        let rpcId: String
        let result: Result

        struct Result: Decodable {
            let ok: Bool
            /// 失败分支可能不含 value / error 字段——Optional 宽容处理。
            let value: HarnessDescribeInfo?
            let error: RPCError?
        }

        struct RPCError: Decodable {
            let code: String?
            let message: String?
        }
    }
}
