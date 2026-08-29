import Foundation

/// Harness 事件流 WebSocket 传输（wire contract 对照上游 `dsh-v0.1.2-alpha.1`
/// `packages/api/gateway/src/stream-protocol.ts` / `stream-server.ts` 确认）。
///
/// 协议要点：
/// - upgrade 到 `ws://<host>:<port>/api/remote.mux`（单一复用器；旧版
///   `events.<mux|host>` 双下行的 downlink-only 协议已在 dsh-v0.1.2-alpha.1 移除）；
/// - 客户端首条消息必须 `{"type":"open","streamId","endpoint":"$events","payload":{"args":{}}}`；
/// - 服务端每条消息为 JSON 文本：`item`（携带 `$events` 下行帧）/ `end` / `error`；
/// - 断开后由上层退避重连（规格 20）；
/// - 认证依赖共享 Cookie 会话（与 HTTP 认证交换同一 `URLSession`）。
struct HarnessWebSocketTransport: Sendable {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// 打开 `$events` 事件流，产出下行事件帧。
    ///
    /// - Parameters:
    ///   - endpoint: Harness 端点（决定 ws URL 与认证上下文）。
    ///   - onOpen: 连接尝试已发起时回调（可省略）。
    func openEventStream(
        endpoint: HarnessEndpoint,
        onOpen: @escaping @Sendable () -> Void = {}
    ) -> AsyncThrowingStream<HarnessRemoteEventFrame, Error> {
        AsyncThrowingStream { continuation in
            guard let url = Self.webSocketURL(path: HarnessProtocolPath.remoteMux, endpoint: endpoint) else {
                continuation.finish(throwing: HarnessTransportError.invalidResponse)
                return
            }
            let socket = session.webSocketTask(with: url)
            socket.resume()
            onOpen()
            Self.sendOpenMessage(socket: socket)

            let readTask = Task {
                do {
                    while !Task.isCancelled {
                        try Task.checkCancellation()
                        let message = try await socket.receive()
                        switch message {
                        case .string(let text):
                            try Self.consume(text: text, continuation: continuation)
                        case .data(let data):
                            try Self.consume(
                                text: String(data: data, encoding: .utf8) ?? "",
                                continuation: continuation
                            )
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

    // MARK: - Private

    private static func consume(
        text: String,
        continuation: AsyncThrowingStream<HarnessRemoteEventFrame, Error>.Continuation
    ) throws {
        guard let data = text.data(using: .utf8) else { return }
        guard let message = try? JSONDecoder().decode(HarnessRemoteStreamMessage.self, from: data) else {
            // 坏帧：记录并跳过，绝不拖垮整个流（规格 19）。
            AppLogger.compatibility.debug("remote.mux 消息无法解析：\(text.prefix(120), privacy: .public)")
            return
        }
        switch message.type {
        case "item":
            if let frame = message.frame {
                continuation.yield(frame)
            } else {
                // 未知 value 帧类型：跳过（消息本身可解析）。
                AppLogger.compatibility.debug("remote.mux 未知 item 帧，已跳过")
            }
        case "end":
            // 服务端正常关闭 → 流结束，由上层进入重连。
            continuation.finish()
        case "error":
            throw HarnessTransportError.rpcFailure(
                message: message.failureMessage ?? "remote.mux stream error"
            )
        default:
            break
        }
    }

    /// 发送 open 消息（`endpoint` 固定 `$events`，payload 恰为 `{"args":{}}`）。
    private static func sendOpenMessage(socket: URLSessionWebSocketTask) {
        let message = HarnessRemoteStreamOpenMessage(endpoint: HarnessProtocolPath.remoteEventStreamEndpoint)
        guard let data = try? JSONEncoder().encode(message),
              let text = String(data: data, encoding: .utf8) else {
            AppLogger.compatibility.error("remote.mux open 消息编码失败")
            return
        }
        socket.send(.string(text)) { error in
            if let error {
                AppLogger.compatibility.error("remote.mux open 发送失败：\(String(describing: error), privacy: .public)")
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
}
