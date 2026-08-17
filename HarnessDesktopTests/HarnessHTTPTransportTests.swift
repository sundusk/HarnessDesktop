import XCTest
@testable import HarnessDesktop

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

    func testDescribeSuccess() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertTrue(request.url!.path.hasSuffix("/api/host.describe"))
            return try self.response(200, url: request.url!, json: """
            {
              "type": "server-response",
              "rpcId": "echo",
              "result": {
                "ok": true,
                "value": {
                  "version": "0.0.1",
                  "cwd": "/Users/x",
                  "provider": "deepseek-official",
                  "model": "deepseek-v4-flash",
                  "attachedSessions": 6,
                  "canOpenPath": true
                }
              }
            }
            """)
        }
        let info = try await makeTransport().describe(endpoint: endpoint)
        XCTAssertEqual(info.version, "0.0.1")
        XCTAssertEqual(info.attachedSessions, 6)
        XCTAssertEqual(info.provider, "deepseek-official")
    }

    func testDescribeRPCFailureThrows() async {
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
            _ = try await makeTransport().describe(endpoint: endpoint)
            XCTFail("应抛出 rpcFailure")
        } catch let error as HarnessTransportError {
            XCTAssertEqual(error, .rpcFailure(message: "boom"))
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
    }

    func testDescribeNon2xxThrows() async {
        MockURLProtocol.handler = { request in
            try self.response(500, url: request.url!, json: "{}")
        }
        do {
            _ = try await makeTransport().describe(endpoint: endpoint)
            XCTFail("应抛出 unexpectedStatus")
        } catch let error as HarnessTransportError {
            XCTAssertEqual(error, .unexpectedStatus(500))
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
    }

    func testDescribeMalformedBodyThrows() async {
        MockURLProtocol.handler = { request in
            try self.response(200, url: request.url!, json: "<html>oops</html>")
        }
        do {
            _ = try await makeTransport().describe(endpoint: endpoint)
            XCTFail("应抛出 invalidResponse")
        } catch let error as HarnessTransportError {
            XCTAssertEqual(error, .invalidResponse)
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
    }

    func testDescribeConnectionErrorThrows() async {
        MockURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
        do {
            _ = try await makeTransport().describe(endpoint: endpoint)
            XCTFail("应抛出 URLError")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cannotConnectToHost)
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
    }
}
