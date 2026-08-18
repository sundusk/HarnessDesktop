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

    func testEquality() {
        let a = HarnessEndpoint(host: "127.0.0.1", port: 3080)
        let b = HarnessEndpoint(host: "127.0.0.1", port: 3080)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, HarnessEndpoint(host: "127.0.0.1", port: 9999))
    }
}
