import XCTest
@testable import DeepSeek_Harness

final class GitHubHarnessReleaseVersionProviderTests: XCTestCase {
    private let releasesURL = URL(string: "https://api.github.com/repos/deepseek-ai/deepseek-harness/releases?per_page=20")!

    private func response(status: Int, json: String) -> (Data, URLResponse) {
        let response = HTTPURLResponse(
            url: releasesURL,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
        return (Data(json.utf8), response)
    }

    private func fetch(json: String) async throws -> HarnessVersion {
        let fetcher = MockHTTPFetcher(result: .success(response(status: 200, json: json)))
        return try await GitHubHarnessReleaseVersionProvider(fetcher: fetcher)
            .fetchLatestReleaseVersion()
    }

    func testParsesDshVTag() async throws {
        let version = try await fetch(json: #"[{"tag_name":"dsh-v0.1.0-rc.8","draft":false,"prerelease":true}]"#)
        XCTAssertEqual(version, HarnessVersion("0.1.0-rc.8"))
    }

    func testParsesCompatibleVTagAndIncludesPrerelease() async throws {
        let version = try await fetch(json: #"[{"tag_name":"v0.1.0-rc.9","draft":false,"prerelease":true}]"#)
        XCTAssertEqual(version, HarnessVersion("0.1.0-rc.9"))
    }

    func testIgnoresDraftRelease() async throws {
        let version = try await fetch(json: #"""
        [
            {"tag_name":"dsh-v0.1.0-rc.9","draft":true,"prerelease":true},
            {"tag_name":"dsh-v0.1.0-rc.8","draft":false,"prerelease":true}
        ]
        """#)
        XCTAssertEqual(version, HarnessVersion("0.1.0-rc.8"))
    }

    func testSelectsHighestSemVerInsteadOfFirstResponse() async throws {
        let version = try await fetch(json: #"""
        [
            {"tag_name":"dsh-v0.1.0-rc.6","draft":false,"prerelease":true},
            {"tag_name":"dsh-v0.1.0-rc.8","draft":false,"prerelease":true},
            {"tag_name":"dsh-v0.1.0-rc.7","draft":false,"prerelease":true}
        ]
        """#)
        XCTAssertEqual(version, HarnessVersion("0.1.0-rc.8"))
    }

    func testIgnoresInvalidTags() async throws {
        let version = try await fetch(json: #"""
        [
            {"tag_name":"nightly","draft":false,"prerelease":true},
            {"tag_name":"test-build","draft":false,"prerelease":true},
            {"tag_name":"foo","draft":false,"prerelease":false},
            {"tag_name":"dsh-v0.1.0-rc.7","draft":false,"prerelease":true}
        ]
        """#)
        XCTAssertEqual(version, HarnessVersion("0.1.0-rc.7"))
    }

    func testNon200Throws() async {
        let fetcher = MockHTTPFetcher(result: .success(response(status: 403, json: "{}")))
        do {
            _ = try await GitHubHarnessReleaseVersionProvider(fetcher: fetcher).fetchLatestReleaseVersion()
            XCTFail("非 2xx 响应必须失败")
        } catch {
            XCTAssertEqual(error as? HarnessVersionError, .unexpectedStatus(403))
        }
    }

    func testMalformedJSONThrows() async {
        let fetcher = MockHTTPFetcher(result: .success(response(status: 200, json: "{")))
        do {
            _ = try await GitHubHarnessReleaseVersionProvider(fetcher: fetcher).fetchLatestReleaseVersion()
            XCTFail("非法 JSON 必须失败")
        } catch {
            XCTAssertEqual(error as? HarnessVersionError, .malformedReleaseData)
        }
    }

    func testNetworkFailurePropagates() async {
        let fetcher = MockHTTPFetcher(result: .failure(URLError(.notConnectedToInternet)))
        do {
            _ = try await GitHubHarnessReleaseVersionProvider(fetcher: fetcher).fetchLatestReleaseVersion()
            XCTFail("网络错误必须传播")
        } catch {
            XCTAssertTrue(error is URLError)
        }
    }
}
