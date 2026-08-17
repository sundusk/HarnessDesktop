import XCTest
@testable import HarnessDesktop

/// WebSocket 传输测试：帧解析（纯函数）+ URL 构造。
/// （实际 socket 收发由真实 Harness 冒烟覆盖，URLSessionWebSocketTask 无法用 URLProtocol mock。）
final class HarnessWebSocketTransportTests: XCTestCase {

    /// HarnessEndpoint 为静态合法 loopback 值，force unwrap 是静态保证的。
    private var endpoint: HarnessEndpoint {
        HarnessEndpoint(host: "127.0.0.1", port: 3080)!
    }

    // MARK: - parseFrame

    func testParseFrameValid() {
        let frame = HarnessWebSocketTransport.parseFrame("""
        {"type":"server-request","rpcId":"r1","method":"session/subscribed","payload":{"type":"session/subscribed","sessionId":"s1","lastSeq":0}}
        """)
        XCTAssertEqual(frame?.rpcId, "r1")
        XCTAssertEqual(frame?.method, "session/subscribed")
        let payload = try? JSONDecoder().decode(HarnessEventFrame.self, from: frame!.payload)
        XCTAssertEqual(payload?.type, "session/subscribed")
        XCTAssertEqual(payload?.sessionId, "s1")
    }

    func testParseFrameWrongEnvelopeType() {
        XCTAssertNil(HarnessWebSocketTransport.parseFrame(
            "{\"type\":\"server-response\",\"rpcId\":\"r1\",\"result\":{}}"
        ))
    }

    func testParseFrameMalformedJSON() {
        XCTAssertNil(HarnessWebSocketTransport.parseFrame("not-json"))
        XCTAssertNil(HarnessWebSocketTransport.parseFrame(""))
    }

    /// 未知帧类型：信封可解析，payload 交给映射层（返回 nil 是映射层的事）。
    func testParseFrameUnknownFrameType() {
        let frame = HarnessWebSocketTransport.parseFrame("""
        {"type":"server-request","rpcId":"r1","method":"weird/new","payload":{"type":"weird/new","x":1}}
        """)
        XCTAssertNotNil(frame)
    }

    // MARK: - webSocketURL

    func testWebSocketURLMux() {
        let url = HarnessWebSocketTransport.webSocketURL(path: HarnessProtocolPath.muxEvents, endpoint: endpoint)
        XCTAssertEqual(url?.absoluteString, "ws://127.0.0.1:3080/api/events.mux")
    }

    func testWebSocketURLHost() {
        let url = HarnessWebSocketTransport.webSocketURL(path: HarnessProtocolPath.hostEvents, endpoint: endpoint)
        XCTAssertEqual(url?.absoluteString, "ws://127.0.0.1:3080/api/events.host")
    }

    func testWebSocketURLHTTPSBecomesWSS() {
        // URL 为静态合法 loopback 值，force unwrap 是静态保证的。
        let httpsEndpoint = HarnessEndpoint(validating: URL(string: "https://localhost:8443/")!)!
        let url = HarnessWebSocketTransport.webSocketURL(path: "/api/events.mux", endpoint: httpsEndpoint)
        XCTAssertEqual(url?.absoluteString, "wss://localhost:8443/api/events.mux")
    }
}
