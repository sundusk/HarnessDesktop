import Foundation

/// Harness 事件流 WebSocket 传输（当前实例真实协议，对照 `dsh-client-connection` 服务器源码确认）。
///
/// 协议要点：
/// - 直接 upgrade 到 `ws://<host>:<port>/api/events.<mux|host>`，**由路径决定流**；
/// - 客户端**只收不发**——发送任何数据消息都会被服务器以 1008 "downlink only" 关闭；
/// - 每帧为 JSON 文本：`server-request` 信封，`payload` 为事件帧；
/// - 流是持久的；断开后由上层退避重连（规格 20）。
///
/// 注：上游 npm 客户端包（`dsh-host-apiproxy`）使用 SSE streaming fetch 变体，
/// 运行中的 Harness 使用 WebSocket 变体——本传输按运行实例实现，差异隔离在传输层。
struct HarnessWebSocketTransport: Sendable {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// 打开一个事件流，产出 `server-request` 信封帧。
    ///
    /// - Parameters:
    ///   - path: `/api/events.mux` 或 `/api/events.host`。
    ///   - onOpen: 连接尝试已发起时回调。
    func openStream(
        path: String,
        endpoint: HarnessEndpoint,
        onOpen: @escaping @Sendable () -> Void
    ) -> AsyncThrowingStream<HarnessServerRequestFrame, Error> {
        AsyncThrowingStream { continuation in
            guard let url = Self.webSocketURL(path: path, endpoint: endpoint) else {
                continuation.finish(throwing: HarnessTransportError.invalidResponse)
                return
            }
            let socket = session.webSocketTask(with: url)
            socket.resume()
            onOpen()

            let readTask = Task {
                do {
                    while !Task.isCancelled {
                        try Task.checkCancellation()
                        let message = try await socket.receive()
                        switch message {
                        case .string(let text):
                            if let frame = Self.parseFrame(text) {
                                continuation.yield(frame)
                            } else {
                                // 坏帧：记录并跳过，绝不拖垮整个流（规格 19）。
                                AppLogger.compatibility.debug("WebSocket 帧无法解析：\(text.prefix(120), privacy: .public)")
                            }
                        case .data(let data):
                            if let text = String(data: data, encoding: .utf8),
                               let frame = Self.parseFrame(text) {
                                continuation.yield(frame)
                            }
                        @unknown default:
                            break
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                readTask.cancel()
                socket.cancel(with: .goingAway, reason: nil)
            }
        }
    }

    /// 构造 WebSocket URL（`http(s)` → `ws(s)`）。
    static func webSocketURL(path: String, endpoint: HarnessEndpoint) -> URL? {
        guard var components = URLComponents(url: endpoint.baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = path
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// 解析一帧：`server-request` 信封 → 帧模型。解析失败返回 nil。
    static func parseFrame(_ text: String) -> HarnessServerRequestFrame? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String, type == "server-request",
              let rpcId = json["rpcId"] as? String,
              let method = json["method"] as? String,
              let payload = json["payload"],
              let payloadData = try? JSONSerialization.data(withJSONObject: payload) else {
            return nil
        }
        return HarnessServerRequestFrame(rpcId: rpcId, method: method, payload: payloadData)
    }
}
