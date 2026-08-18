import XCTest
@testable import DeepSeek_Harness

/// 可注入的 URLProtocol 模拟，用于测试 Discovery 而不需要真实 Harness。
final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class LocalHarnessDiscoveryTests: XCTestCase {

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        config.timeoutIntervalForRequest = 1
        return URLSession(configuration: config)
    }

    private func makeDiscovery() -> LocalHarnessDiscovery {
        LocalHarnessDiscovery(host: "127.0.0.1", port: 3080, timeout: 0.5, session: makeSession())
    }

    private func response(_ status: Int, url: URL?) throws -> (HTTPURLResponse, Data) {
        guard let url else { throw URLError(.badURL) }
        let http = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (http, Data())
    }

    func testDiscoverReturnsEndpointOn2xx() async {
        MockURLProtocol.handler = { request in
            try self.response(200, url: request.url)
        }
        let endpoint = await makeDiscovery().discover()
        XCTAssertEqual(endpoint?.baseURL.host, "127.0.0.1")
        XCTAssertEqual(endpoint?.baseURL.port, 3080)
    }

    func testDiscoverReturnsEndpointOn3xx() async {
        MockURLProtocol.handler = { request in
            try self.response(302, url: request.url)
        }
        let endpoint = await makeDiscovery().discover()
        XCTAssertNotNil(endpoint)
    }

    func testDiscoverReturnsNilOn4xx() async {
        MockURLProtocol.handler = { request in
            try self.response(404, url: request.url)
        }
        let endpoint = await makeDiscovery().discover()
        XCTAssertNil(endpoint)
    }

    func testDiscoverReturnsNilOn5xx() async {
        MockURLProtocol.handler = { request in
            try self.response(503, url: request.url)
        }
        let endpoint = await makeDiscovery().discover()
        XCTAssertNil(endpoint)
    }

    func testDiscoverReturnsNilOnConnectionError() async {
        MockURLProtocol.handler = { _ in
            throw URLError(.cannotConnectToHost)
        }
        let endpoint = await makeDiscovery().discover()
        XCTAssertNil(endpoint)
    }

    func testDiscoverReturnsNilForNonLoopbackHost() async {
        let discovery = LocalHarnessDiscovery(host: "8.8.8.8", port: 3080, timeout: 0.5, session: makeSession())
        MockURLProtocol.handler = { request in
            try self.response(200, url: request.url)
        }
        let endpoint = await discovery.discover()
        XCTAssertNil(endpoint)
    }
}
