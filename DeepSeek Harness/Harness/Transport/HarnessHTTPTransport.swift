import Foundation

/// Harness HTTP 传输错误。不携带任何敏感信息。
enum HarnessTransportError: Error, Equatable, Sendable {
    case unexpectedStatus(Int)
    case invalidResponse
    case rpcFailure(message: String?)
}

/// HTTP 传输层：承载 Harness RPC（`POST /api/<method>`）。
///
/// 使用 URLSession，不引入 JS。所有协议细节只存在于本层与 Adapter 层。
struct HarnessHTTPTransport: Sendable {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// `host.describe`：Compatibility Handshake。
    ///
    /// 读取 Harness version / cwd / provider / model / attachedSessions / 能力标志。
    func describe(endpoint: HarnessEndpoint) async throws -> HarnessDescribeInfo {
        let rpcId = UUID().uuidString.lowercased()
        let body = HarnessRPCEnvelope.Request(rpcId: rpcId, method: "host.describe", payload: [:])
        let url = endpoint.baseURL.appendingPathComponent("api/host.describe")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HarnessTransportError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw HarnessTransportError.unexpectedStatus(http.statusCode)
        }

        let envelope: HarnessRPCEnvelope.Response
        do {
            envelope = try JSONDecoder().decode(HarnessRPCEnvelope.Response.self, from: data)
        } catch {
            throw HarnessTransportError.invalidResponse
        }

        guard envelope.result.ok, let value = envelope.result.value else {
            throw HarnessTransportError.rpcFailure(message: envelope.result.error?.message)
        }
        return value
    }
}
