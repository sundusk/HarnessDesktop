import XCTest
@testable import HarnessDesktop

final class HarnessNavigationPolicyTests: XCTestCase {

    private func makePolicy(host: String = "127.0.0.1", port: Int = 3080) -> HarnessNavigationPolicy {
        // host/port 为静态合法 loopback 值，force unwrap 是静态保证的。
        let endpoint = HarnessEndpoint(host: host, port: port)!
        return HarnessNavigationPolicy(endpoint: endpoint)
    }

    private func url(_ string: String) -> URL {
        URL(string: string)!
    }

    func testAllowsSameOrigin() {
        let policy = makePolicy()
        XCTAssertEqual(policy.decision(for: url("http://127.0.0.1:3080/")), .allow)
        XCTAssertEqual(policy.decision(for: url("http://127.0.0.1:3080/api/events.mux")), .allow)
        XCTAssertEqual(policy.decision(for: url("http://127.0.0.1:3080/assets/app.js?x=1")), .allow)
    }

    func testAllowsAboutBlank() {
        let policy = makePolicy()
        XCTAssertEqual(policy.decision(for: url("about:blank")), .allow)
    }

    func testExternalHTTPS() {
        let policy = makePolicy()
        XCTAssertEqual(
            policy.decision(for: url("https://github.com/deepseek-ai/deepseek-harness")),
            .external(url("https://github.com/deepseek-ai/deepseek-harness"))
        )
    }

    func testExternalHTTP() {
        let policy = makePolicy()
        XCTAssertEqual(
            policy.decision(for: url("http://example.com/")),
            .external(url("http://example.com/"))
        )
    }

    func testExternalDifferentPort() {
        let policy = makePolicy()
        XCTAssertEqual(
            policy.decision(for: url("http://127.0.0.1:9999/")),
            .external(url("http://127.0.0.1:9999/"))
        )
    }

    func testExternalDifferentLoopbackHost() {
        // localhost 与 127.0.0.1 属于不同 origin，按策略交给外部浏览器。
        let policy = makePolicy()
        XCTAssertEqual(
            policy.decision(for: url("http://localhost:3080/")),
            .external(url("http://localhost:3080/"))
        )
    }

    func testExternalCustomScheme() {
        let policy = makePolicy()
        XCTAssertEqual(
            policy.decision(for: url("mailto:hi@example.com")),
            .external(url("mailto:hi@example.com"))
        )
        XCTAssertEqual(
            policy.decision(for: url("file:///tmp/a")),
            .external(url("file:///tmp/a"))
        )
    }
}
