import XCTest
import JavaScriptCore
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

    private func makeNativeSession() -> HarnessNativeSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        config.timeoutIntervalForRequest = 1
        return HarnessNativeSession(configuration: config)
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

    func testNativeSessionMaps401ToAuthenticationRequired() async throws {
        let tokenURL = URL(string: "http://127.0.0.1:3080/?token=expired")!
        MockURLProtocol.handler = { request in
            try self.response(401, url: request.url!, json: "unauthorized")
        }

        do {
            try await makeNativeSession().authenticate(authenticatedURL: tokenURL)
            XCTFail("401 应进入 authenticationRequired")
        } catch let error as HarnessAuthenticationError {
            XCTAssertEqual(error, .authenticationRequired)
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
    }

    func testNativeSessionWithoutLaunchURLDoesNotRequest() async throws {
        MockURLProtocol.handler = { _ in
            XCTFail("无启动地址时不应发起认证请求")
            throw URLError(.badURL)
        }

        try await makeNativeSession().authenticate(authenticatedURL: nil)
    }

    func testNativeSessionCookieBridgeRoundTripsEndpointCookie() throws {
        let session = makeNativeSession()
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "127.0.0.1",
            .path: "/",
            .name: "dsh-auth-test",
            .value: "session",
            .expires: Date(timeIntervalSinceNow: 60),
        ]))

        session.setCookies([cookie])

        XCTAssertTrue(session.cookies(for: endpoint).contains { $0.name == "dsh-auth-test" })
    }

    @MainActor
    func testWebViewStoredCookieCanSeedNativeSession() async throws {
        let model = HarnessWebViewModel(endpoint: endpoint)
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "127.0.0.1",
            .path: "/",
            .name: "dsh-auth-webview",
            .value: "session",
            .expires: Date(timeIntervalSinceNow: 60),
        ]))
        let cookieStore = model.webView.configuration.websiteDataStore.httpCookieStore

        await withCheckedContinuation { continuation in
            cookieStore.setCookie(cookie) {
                continuation.resume()
            }
        }

        let session = makeNativeSession()
        await model.transferStoredCookies(to: session)

        XCTAssertTrue(session.cookies(for: endpoint).contains { $0.name == "dsh-auth-webview" })
    }

    @MainActor
    func testWebKitCompatibilityScriptNormalizesNativeFunctionWhitespace() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        (() => {
            const originalToString = Function.prototype.toString
            Function.prototype.toString = function () {
                const rendered = originalToString.call(this)
                return rendered.includes('[native code]')
                    ? 'function Object() {\\n    [native code]\\n}'
                    : rendered
            }
        })()
        """)
        context.evaluateScript(HarnessWebKitCompatibility.nativeFunctionToStringNormalizationScript)

        let rendered = context.evaluateScript("Function.prototype.toString.call(Object)")?.toString()
        XCTAssertEqual(rendered, "function Object() { [native code] }")
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

    func testListSessionsUnauthorizedRequiresAuthentication() async {
        MockURLProtocol.handler = { request in
            try self.response(401, url: request.url!, json: "unauthorized")
        }
        do {
            _ = try await makeTransport().listSessions(endpoint: endpoint)
            XCTFail("401 应进入 authenticationRequired")
        } catch let error as HarnessTransportError {
            XCTAssertEqual(error, .authenticationRequired)
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
}
