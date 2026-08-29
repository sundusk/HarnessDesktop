import XCTest
@testable import DeepSeek_Harness

/// WebSocket 传输测试：下行消息解码（纯模型）+ URL 构造 + open 消息编码。
/// （实际 socket 收发由真实 Harness 冒烟覆盖，URLSessionWebSocketTask 无法用 URLProtocol mock。）
final class HarnessWebSocketTransportTests: XCTestCase {

    /// HarnessEndpoint 为静态合法 loopback 值，force unwrap 是静态保证的。
    private var endpoint: HarnessEndpoint {
        HarnessEndpoint(host: "127.0.0.1", port: 3080)!
    }

    private func decodeMessage(_ json: String) -> HarnessRemoteStreamMessage? {
        try? JSONDecoder().decode(HarnessRemoteStreamMessage.self, from: Data(json.utf8))
    }

    // MARK: - 下行消息解码

    func testReadyFrame() {
        let message = decodeMessage("""
        {"type":"item","streamId":"st1","value":{"type":"ready","clientId":"c1","host":{"home":"/Users/x"}}}
        """)
        XCTAssertEqual(message?.type, "item")
        XCTAssertEqual(message?.streamId, "st1")
        XCTAssertEqual(message?.frame, .ready(clientId: "c1", hostHome: "/Users/x"))
    }

    func testEmitFrame() {
        let message = decodeMessage("""
        {"type":"item","streamId":"st1","value":{"type":"emit","event":"api-session/status","args":["s1",true]}}
        """)
        XCTAssertEqual(message?.frame, .emit(event: "api-session/status", args: [.string("s1"), .bool(true)]))
    }

    func testWaterfallFrame() {
        let message = decodeMessage("""
        {"type":"item","streamId":"st1","value":{"type":"waterfall","event":"approval/request",
         "eventId":"e1","agentId":"a1","request":{"toolName":"bash","reason":"install"}}}
        """)
        XCTAssertEqual(message?.frame, .waterfall(
            event: "approval/request",
            eventId: "e1",
            agentId: "a1",
            request: .object(["toolName": .string("bash"), "reason": .string("install")])
        ))
    }

    func testCancelFrame() {
        let message = decodeMessage("""
        {"type":"item","streamId":"st1","value":{"type":"cancel","eventId":"e1"}}
        """)
        XCTAssertEqual(message?.frame, .cancelled(eventId: "e1"))
    }

    /// 未知 value 帧类型：消息存活、frame 为 nil（上层跳过，规格 19）。
    func testUnknownValueFrameIsTolerated() {
        let message = decodeMessage("""
        {"type":"item","streamId":"st1","value":{"type":"brand-new-frame","x":1}}
        """)
        XCTAssertNotNil(message)
        XCTAssertEqual(message?.type, "item")
        XCTAssertNil(message?.frame)
    }

    /// 完全无法解析的文本：返回 nil，不 crash。
    func testMalformedMessageReturnsNil() {
        XCTAssertNil(decodeMessage("not-json"))
        XCTAssertNil(decodeMessage(""))
        XCTAssertNil(decodeMessage("[1,2,3]"))
    }

    // MARK: - open 消息编码

    /// open 消息必须恰为 `{"type":"open","streamId","endpoint":"$events","payload":{"args":{}}}`。
    func testOpenMessageEncoding() throws {
        let message = HarnessRemoteStreamOpenMessage(endpoint: HarnessProtocolPath.remoteEventStreamEndpoint)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as! [String: Any]
        XCTAssertEqual(json["type"] as? String, "open")
        XCTAssertEqual(json["endpoint"] as? String, "$events")
        XCTAssertNotEqual((json["streamId"] as? String)?.isEmpty, true)
        let payload = json["payload"] as! [String: Any]
        XCTAssertEqual((payload["args"] as! [String: Any]).count, 0)
    }

    // MARK: - webSocketURL

    func testWebSocketURLRemoteMux() {
        let url = HarnessWebSocketTransport.webSocketURL(path: HarnessProtocolPath.remoteMux, endpoint: endpoint)
        XCTAssertEqual(url?.absoluteString, "ws://127.0.0.1:3080/api/remote.mux")
    }

    func testWebSocketURLHTTPSBecomesWSS() {
        // URL 为静态合法 loopback 值，force unwrap 是静态保证的。
        let httpsEndpoint = HarnessEndpoint(validating: URL(string: "https://localhost:8443/")!)!
        let url = HarnessWebSocketTransport.webSocketURL(path: "/api/remote.mux", endpoint: httpsEndpoint)
        XCTAssertEqual(url?.absoluteString, "wss://localhost:8443/api/remote.mux")
    }
}
