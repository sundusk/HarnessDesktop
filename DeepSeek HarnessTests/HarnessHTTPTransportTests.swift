import XCTest
@testable import DeepSeek_Harness

/// HTTP Transport 测试：用 MockURLProtocol 模拟 Harness RPC，不需要真实 Harness。
final class HarnessHTTPTransportTests: XCTestCase {

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    private func makeTransport() -> HarnessHTTPTransport {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        config.timeoutIntervalForRequest = 1
        return HarnessHTTPTransport(session: URLSession(configuration: config))
    }

    /// HarnessEndpoint 为静态合法 loopback 值，force unwrap 是静态保证的。
    private var endpoint: HarnessEndpoint {
        HarnessEndpoint(host: "127.0.0.1", port: 3080)!
    }

    private func response(_ status: Int, url: URL?, json: String) throws -> (HTTPURLResponse, Data) {
        guard let url else { throw URLError(.badURL) }
        let http = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (http, Data(json.utf8))
    }

    /// URLProtocol 内 `httpBody` 常被转为 `httpBodyStream`；统一从流读出请求体。
    private func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }

    // MARK: - authenticate

    func testAuthenticateWithoutTokenIsNoOp() async throws {
        MockURLProtocol.handler = { _ in
            XCTFail("无认证入口时不应发起请求")
            throw URLError(.badURL)
        }
        try await makeTransport().authenticate(endpoint: endpoint)
    }

    func testAuthenticatePerformsGETOnTokenURL() async throws {
        let tokenURL = URL(string: "http://127.0.0.1:3080/?token=launch-secret")!
        let authenticatedEndpoint = HarnessEndpoint(authenticatedURL: tokenURL)!
        var requestURLs: [URL] = []
        MockURLProtocol.handler = { request in
            requestURLs.append(request.url!)
            return try self.response(200, url: request.url!, json: "<html>ok</html>")
        }
        try await makeTransport().authenticate(endpoint: authenticatedEndpoint)
        XCTAssertEqual(requestURLs, [tokenURL])
    }

    func testAuthenticateNon2xxThrows() async {
        let authenticatedEndpoint = HarnessEndpoint(
            authenticatedURL: URL(string: "http://127.0.0.1:3080/?token=bad")!
        )!
        MockURLProtocol.handler = { request in
            try self.response(401, url: request.url!, json: "unauthorized")
        }
        do {
            try await makeTransport().authenticate(endpoint: authenticatedEndpoint)
            XCTFail("应抛出 unexpectedStatus")
        } catch let error as HarnessTransportError {
            XCTAssertEqual(error, .unexpectedStatus(401))
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
    }

    // MARK: - listSessions

    func testListSessionsSuccess() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertTrue(request.url!.path.hasSuffix("/api/session/list"))
            let body = try JSONSerialization.jsonObject(with: self.body(of: request)) as! [String: Any]
            XCTAssertEqual(body["method"] as? String, "session/list")
            let args = ((body["payload"] as! [String: Any])["args"] as! [String: Any])
            XCTAssertNotNil(args["_request"])
            return try self.response(200, url: request.url!, json: """
            {
              "type": "server-response",
              "rpcId": "echo",
              "result": {
                "ok": true,
                "value": {
                  "items": [
                    { "sessionId": "s1", "updatedAt": 1730000000, "running": true, "blank": false }
                  ]
                }
              }
            }
            """)
        }
        let sessions = try await makeTransport().listSessions(endpoint: endpoint)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.sessionId, "s1")
        XCTAssertEqual(sessions.first?.running, true)
    }

    /// Adapter connect 顺序：先认证交换（GET token URL），再 session/list RPC。
    func testAuthenticateThenListSessionsMatchesConnectFlow() async throws {
        let tokenURL = URL(string: "http://127.0.0.1:3080/?token=launch-secret")!
        let authenticatedEndpoint = HarnessEndpoint(authenticatedURL: tokenURL)!
        var requestURLs: [URL] = []
        MockURLProtocol.handler = { request in
            requestURLs.append(request.url!)
            if request.httpMethod == "GET" {
                return try self.response(200, url: request.url!, json: "<html>ok</html>")
            }
            return try self.response(200, url: request.url!, json: """
            {
              "type": "server-response",
              "rpcId": "echo",
              "result": { "ok": true, "value": { "items": [] } }
            }
            """)
        }
        let transport = makeTransport()
        try await transport.authenticate(endpoint: authenticatedEndpoint)
        let sessions = try await transport.listSessions(endpoint: authenticatedEndpoint)

        XCTAssertTrue(sessions.isEmpty)
        XCTAssertEqual(requestURLs.first, tokenURL)
        XCTAssertTrue(requestURLs.last?.path.hasSuffix("/api/session/list") == true)
    }

    func testListSessionsRPCFailureThrows() async {
        MockURLProtocol.handler = { request in
            try self.response(200, url: request.url!, json: """
            {
              "type": "server-response",
              "rpcId": "echo",
              "result": {
                "ok": false,
                "error": { "code": "internal", "message": "boom" }
              }
            }
            """)
        }
        do {
            _ = try await makeTransport().listSessions(endpoint: endpoint)
            XCTFail("应抛出 rpcFailure")
        } catch let error as HarnessTransportError {
            XCTAssertEqual(error, .rpcFailure(message: "boom"))
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
    }

    func testListSessionsNon2xxThrows() async {
        MockURLProtocol.handler = { request in
            try self.response(500, url: request.url!, json: "{}")
        }
        do {
            _ = try await makeTransport().listSessions(endpoint: endpoint)
            XCTFail("应抛出 unexpectedStatus")
        } catch let error as HarnessTransportError {
            XCTAssertEqual(error, .unexpectedStatus(500))
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
    }

    func testListSessionsMalformedBodyThrows() async {
        MockURLProtocol.handler = { request in
            try self.response(200, url: request.url!, json: "<html>oops</html>")
        }
        do {
            _ = try await makeTransport().listSessions(endpoint: endpoint)
            XCTFail("应抛出 invalidResponse")
        } catch let error as HarnessTransportError {
            XCTAssertEqual(error, .invalidResponse)
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
    }

    func testListSessionsConnectionErrorThrows() async {
        MockURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
        do {
            _ = try await makeTransport().listSessions(endpoint: endpoint)
            XCTFail("应抛出 URLError")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cannotConnectToHost)
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
    }

    // MARK: - sendEventResult

    /// waterfall 应答：POST `$events/result`，outcome 固定 next；HTTP 失败只吞掉，不抛出。
    func testSendEventResultSwallowsHTTPFailures() async throws {
        var bodies: [[String: Any]] = []
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertTrue(request.url!.path.hasSuffix("/api/$events/result"))
            bodies.append(try JSONSerialization.jsonObject(with: self.body(of: request)) as! [String: Any])
            return try self.response(500, url: request.url!, json: "unauthorized")
        }
        await makeTransport().sendEventResult(endpoint: endpoint, clientId: "c1", eventId: "e1")
        XCTAssertEqual(bodies.count, 1)
        let args = ((bodies[0]["payload"] as! [String: Any])["args"] as! [String: Any])
        XCTAssertEqual(args["clientId"] as? String, "c1")
        XCTAssertEqual(args["eventId"] as? String, "e1")
        XCTAssertEqual((args["outcome"] as! [String: Any])["kind"] as? String, "next")
    }
}
