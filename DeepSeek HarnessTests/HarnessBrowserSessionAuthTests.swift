import XCTest
@testable import DeepSeek_Harness

/// 校验 `HarnessBrowserSessionAuth` 与上游 `packages/client/connection/src/browser-auth.ts`
/// 算法完全一致。黄金值由该上游算法用同一输入生成（见测试内注释）。
final class HarnessBrowserSessionAuthTests: XCTestCase {

    // 与上游 golden 生成脚本一致的输入：32 字节 secret（0x41 开头，其余 0x01）。
    private let authority = "127.0.0.1:3080"
    private let secretBytes: [UInt8] = [0x41] + Array(repeating: 0x01, count: 31)
    private let issuedAtMs: Int64 = 1_700_000_000_000
    private let maxAgeDays = 30

    private var secretData: Data { Data(secretBytes) }

    func testCookieNameMatchesUpstream() {
        // 上游：name = 'dsh-auth-' + base64url(sha256(authority))
        let cookie = try! HarnessBrowserSessionAuth.encodeCookie(
            authority: authority, secret: secretData,
            issuedAtMs: issuedAtMs, maxAgeDays: maxAgeDays)
        XCTAssertEqual(cookie.name, "dsh-auth-VPhEEcLKeqRDBoBalzN2Nm7CnfxKhLE00pKIDWxt1sw")
    }

    func testCookieValueMatchesUpstream() {
        // 上游：value = 'v1.<base64url(JSON payload)>.<base64url(HMAC-SHA256(secret, body))>'
        // 固定输入生成的所有黄金值：
        //   body = eyJ2ZXJzaW9uIjoxLCJhdXRob3JpdHkiOiIxMjcuMC4wLjE6MzA4MCIsImlzc3VlZEF0IjoxNzAwMDAwMDAwMDAwLCJleHBpcmVzQXQiOjE3MDI1OTIwMDAwMDB9
        //   value = v1.<body>.uWsycIzuzsJ2fvQtvFgK7m5SnXeXnNkmoq7i_l1xSgA
        let cookie = try! HarnessBrowserSessionAuth.encodeCookie(
            authority: authority, secret: secretData,
            issuedAtMs: issuedAtMs, maxAgeDays: maxAgeDays)
        let expectedValue = "v1.eyJ2ZXJzaW9uIjoxLCJhdXRob3JpdHkiOiIxMjcuMC4wLjE6MzA4MCIsImlzc3VlZEF0IjoxNzAwMDAwMDAwMDAwLCJleHBpcmVzQXQiOjE3MDI1OTIwMDAwMDB9.uWsycIzuzsJ2fvQtvFgK7m5SnXeXnNkmoq7i_l1xSgA"
        XCTAssertEqual(cookie.value, expectedValue)
        XCTAssertEqual(cookie.authority, authority)
        XCTAssertEqual(cookie.issuedAt, issuedAtMs)
        XCTAssertEqual(cookie.expiresAt, issuedAtMs + Int64(maxAgeDays) * 24 * 60 * 60 * 1000)
    }

    func testSecretBase64URLDecodeRoundTrip() throws {
        let encoded = "QQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE"
        let decoded = try XCTUnwrap(HarnessBrowserSessionAuth.base64URLDecode(encoded))
        XCTAssertEqual(decoded.count, 32)
        XCTAssertEqual(decoded.first, 0x41)
    }

    func testSecretFromSampleCredentials() throws {
        // 复刻 `~/.dsh/.credentials.yaml` 的 browser-session 记录片段。
        let yaml = """
        version: 1
        refs:
          DEEPSEEK_API_KEY: sk-test
        records:
          client-connection/browser-session:
            kind: grant
            payload:
              version: 1
              secret: QQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE
        """
        let data = Data(yaml.utf8)
        let secret = try HarnessBrowserSessionAuth.requireSecret(
            from: data,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        XCTAssertEqual(secret.first, 0x41)
        XCTAssertEqual(secret.count, 32)
    }

    func testMissingSecretThrows() {
        let yaml = "version: 1\nrecords:\n  client-connection/browser-session:\n    kind: grant\n    payload:\n      version: 1\n"
        let data = Data(yaml.utf8)
        XCTAssertThrowsError(try HarnessBrowserSessionAuth.requireSecret(
            from: data,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser))
    }

    func testAuthorityUsesHostAndPort() throws {
        let endpoint = try XCTUnwrap(HarnessEndpoint(host: "127.0.0.1", port: 3080))
        let authority = try HarnessBrowserSessionAuth.requireAuthority(endpoint: endpoint)
        XCTAssertEqual(authority, "127.0.0.1:3080")
    }

    func testMakeCookieFromRealCredentials() throws {
        // 若本机存在 ~/.dsh/.credentials.yaml 则能构造 cookie；否则跳过（不脆断 CI）。
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = home.appendingPathComponent(".dsh/.credentials.yaml")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("本机无 ~/.dsh/.credentials.yaml，跳过真实凭证路径测试")
        }
        let endpoint = try XCTUnwrap(HarnessEndpoint(host: "127.0.0.1", port: 3080))
        let cookie = try HarnessBrowserSessionAuth.makeCookie(endpoint: endpoint)
        XCTAssertTrue(cookie.name.hasPrefix("dsh-auth-"))
        XCTAssertTrue(cookie.value.hasPrefix("v1."))
        XCTAssertFalse(cookie.value.isEmpty)
        XCTAssertNotNil(cookie.makeHTTPCookie(endpoint: endpoint))
    }
}
