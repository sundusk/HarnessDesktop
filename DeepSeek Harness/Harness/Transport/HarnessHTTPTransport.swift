import Foundation

/// Harness HTTP 传输错误。不携带任何敏感信息。
enum HarnessTransportError: Error, Equatable, Sendable {
    case unexpectedStatus(Int)
    case invalidResponse
    case rpcFailure(message: String?)
}

/// HTTP 传输层：承载 Harness RPC（`POST /api/<endpoint>`）。
///
/// Wire contract 对照上游 `dsh-v0.1.2-alpha.1`
/// `packages/client/connection/src/client/rpc.ts`（信封）与
/// `packages/api/gateway/src/index.ts`（`$events/result` 分支）确认。
///
/// 使用 URLSession，不引入 JS。所有协议细节只存在于本层与 Adapter 层。
struct HarnessHTTPTransport: Sendable {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// 认证交换：带 token 的入口 GET 一次，使共享 Cookie 会话获得持久认证。
    ///
    /// Harness 侧 `GET /?token=...` 换取持久 browser-session cookie；
    /// 之后所有 `/api/*` RPC 与 `/api/remote.mux` WebSocket 升级都靠该 cookie 通过
    /// 认证栅栏（未认证一律 401 "unauthorized"）。无认证入口时是空操作。
    func authenticate(endpoint: HarnessEndpoint) async throws {
        guard let authenticatedURL = endpoint.authenticatedURL else { return }
        var request = URLRequest(url: authenticatedURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HarnessTransportError.invalidResponse
        }
        guard (200..<400).contains(http.statusCode) else {
            throw HarnessTransportError.unexpectedStatus(http.statusCode)
        }
        // 响应体无业务含义（index HTML）；_data 仅用于驱动请求。
        _ = data
    }

    /// `POST /api/session/list`：session 基线（同时在协议层验证认证与路由可达）。
    ///
    /// 新协议没有 `host.describe`；本调用是握手可达性判定 + 连接/重连时的
    /// session 基线来源（emit 事件不回放，断线期间错过的增删靠它补齐）。
    func listSessions(endpoint: HarnessEndpoint) async throws -> [HarnessSessionSummary] {
        let request = HarnessRPCRequest(
            method: HarnessProtocolPath.sessionListEndpoint,
            args: HarnessRPCSessionListArgs()
        )
        let value: HarnessSessionListValue = try await rpc(
            endpoint: endpoint,
            path: "api/\(HarnessProtocolPath.sessionListEndpoint)",
            body: JSONEncoder().encode(request)
        )
        return value.items
    }

    // MARK: - Private

    /// 通用 RPC 调用：POST 信封 → 校验 2xx → 解码响应 → 校验 ok → 取 value。
    private func rpc<Value: Decodable>(endpoint: HarnessEndpoint,
                                       path: String,
                                       body: Data) async throws -> Value {
        let url = endpoint.baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HarnessTransportError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw HarnessTransportError.unexpectedStatus(http.statusCode)
        }

        let envelope: HarnessRPCEnvelope.Response<Value>
        do {
            envelope = try JSONDecoder().decode(HarnessRPCEnvelope.Response<Value>.self, from: data)
        } catch {
            throw HarnessTransportError.invalidResponse
        }

        guard envelope.result.ok, let value = envelope.result.value else {
            throw HarnessTransportError.rpcFailure(message: envelope.result.error?.message)
        }
        return value
    }
}
