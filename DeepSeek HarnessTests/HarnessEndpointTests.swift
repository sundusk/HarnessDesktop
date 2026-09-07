import XCTest
@testable import DeepSeek_Harness

final class HarnessEndpointTests: XCTestCase {

    func testDefaultEndpointIsLoopback3080() {
        let endpoint = HarnessEndpoint.default
        XCTAssertEqual(endpoint.baseURL.scheme, "http")
        XCTAssertEqual(endpoint.baseURL.host, "127.0.0.1")
        XCTAssertEqual(endpoint.baseURL.port, 3080)
    }

    func testAllowsLoopbackHosts() {
        for host in ["127.0.0.1", "localhost", "::1"] {
            XCTAssertNotNil(HarnessEndpoint(host: host, port: 3080), "\(host) 应被允许")
        }
    }

    func testAllowsCaseInsensitiveLocalhost() {
        XCTAssertNotNil(HarnessEndpoint(host: "LOCALHOST", port: 3080))
    }

    func testRejectsPublicHosts() {
        for host in ["8.8.8.8", "example.com", "192.168.1.100", "github.com", "", " "] {
            XCTAssertNil(HarnessEndpoint(host: host, port: 3080), "\(host) 不应被允许")
        }
    }

    func testRejectsInvalidPorts() {
        XCTAssertNil(HarnessEndpoint(host: "127.0.0.1", port: 0))
        XCTAssertNil(HarnessEndpoint(host: "127.0.0.1", port: -1))
        XCTAssertNil(HarnessEndpoint(host: "127.0.0.1", port: 70_000))
    }

    func testValidatesURL() {
        XCTAssertNotNil(HarnessEndpoint(validating: URL(string: "http://127.0.0.1:3080/")!))
        XCTAssertNotNil(HarnessEndpoint(validating: URL(string: "http://localhost:3080/api")!))
        XCTAssertNotNil(HarnessEndpoint(validating: URL(string: "http://[::1]:3080/")!))
        XCTAssertNil(HarnessEndpoint(validating: URL(string: "https://github.com/deepseek-ai/deepseek-harness")!))
        XCTAssertNil(HarnessEndpoint(validating: URL(string: "http://8.8.8.8/")!))
        XCTAssertNil(HarnessEndpoint(validating: URL(string: "file:///tmp/x")!))
    }

    func testAuthenticatedURLKeepsTokenOnlyForBrowserEntry() throws {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:3080/?token=launch-secret"))
        let endpoint = try XCTUnwrap(HarnessEndpoint(authenticatedURL: url))

        XCTAssertEqual(endpoint.baseURL.absoluteString, "http://127.0.0.1:3080/")
        XCTAssertEqual(endpoint.browserURL, url)
    }

    func testAuthenticatedURLRejectsMissingOrNonLoopbackToken() {
        XCTAssertNil(HarnessEndpoint(authenticatedURL: URL(string: "http://127.0.0.1:3080/")!))
        XCTAssertNil(HarnessEndpoint(authenticatedURL: URL(string: "http://example.com:3080/?token=secret")!))
    }

    func testLaunchURLParserAcceptsOfficialOutputAndRejectsUntrustedText() {
        let line = "info dsh web: http://127.0.0.1:3080/?token=launch-secret"
        XCTAssertEqual(
            HarnessLaunchURLParser.authenticatedURL(from: line)?.absoluteString,
            "http://127.0.0.1:3080/?token=launch-secret"
        )
        XCTAssertNil(HarnessLaunchURLParser.authenticatedURL(from: "dsh web: http://example.com:3080/?token=secret"))
        XCTAssertNil(HarnessLaunchURLParser.authenticatedURL(from: "http://127.0.0.1:3080/?token=secret"))
    }

    func testLaunchContextKeepsAuthenticatedURLSeparateFromBaseEndpoint() throws {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:3080/?token=launch-secret"))
        let context = try XCTUnwrap(HarnessLaunchContext(authenticatedURL: url))

        XCTAssertEqual(context.browserURL, url)
        XCTAssertEqual(context.endpoint.baseURL.absoluteString, "http://127.0.0.1:3080/")
    }

    func testEquality() {
        let a = HarnessEndpoint(host: "127.0.0.1", port: 3080)
        let b = HarnessEndpoint(host: "127.0.0.1", port: 3080)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, HarnessEndpoint(host: "127.0.0.1", port: 9999))
    }
}
