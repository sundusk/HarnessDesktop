import XCTest
@testable import DeepSeek_Harness

/// App 自身更新检查（GitHub releases/latest 查询 + 更新状态比较）。
final class AppUpdateCheckerTests: XCTestCase {

    // MARK: - GitHubLatestReleaseProvider（mock fetcher）

    func testFetchLatestTagSuccess() async throws {
        let json = #"{"tag_name":"v0.2.1","name":"DeepSeek Harness 0.2.1"}"#
        let response = HTTPURLResponse(url: URL(string: "https://api.github.com/repos/x/y/releases/latest")!,
                                       statusCode: 200, httpVersion: nil, headerFields: nil)!
        let provider = GitHubLatestReleaseProvider(fetcher: MockHTTPFetcher(result: .success((Data(json.utf8), response))))
        let tag = try await provider.fetchLatestTag()
        XCTAssertEqual(tag, "v0.2.1")
    }

    func testFetchLatestTagNon200Throws() async {
        let response = HTTPURLResponse(url: URL(string: "https://api.github.com/repos/x/y/releases/latest")!,
                                       statusCode: 404, httpVersion: nil, headerFields: nil)!
        let provider = GitHubLatestReleaseProvider(fetcher: MockHTTPFetcher(result: .success((Data(), response))))
        do {
            _ = try await provider.fetchLatestTag()
            XCTFail("应抛出 unexpectedStatus")
        } catch {
            XCTAssertEqual(error as? AppUpdateError, .unexpectedStatus(404))
        }
    }

    func testFetchLatestTagMalformedThrows() async {
        let response = HTTPURLResponse(url: URL(string: "https://api.github.com/repos/x/y/releases/latest")!,
                                       statusCode: 200, httpVersion: nil, headerFields: nil)!
        let provider = GitHubLatestReleaseProvider(fetcher: MockHTTPFetcher(result: .success((Data("{}".utf8), response))))
        do {
            _ = try await provider.fetchLatestTag()
            XCTFail("应抛出 malformedData")
        } catch {
            XCTAssertEqual(error as? AppUpdateError, .malformedData)
        }
    }

    func testFetchLatestTagNetworkFailurePropagates() async {
        struct Boom: Error {}
        let provider = GitHubLatestReleaseProvider(fetcher: MockHTTPFetcher(result: .failure(Boom())))
        do {
            _ = try await provider.fetchLatestTag()
            XCTFail("应抛出网络错误")
        } catch {
            XCTAssertTrue(error is Boom)
        }
    }

    // MARK: - AppUpdateStatus（纯函数）

    func testStatusUpToDateWhenEqual() {
        XCTAssertEqual(AppUpdateStatus.status(current: "0.2.1", latest: "v0.2.1"),
                       .upToDate(current: "0.2.1"))
    }

    func testStatusUpdateAvailableWhenNewer() {
        XCTAssertEqual(AppUpdateStatus.status(current: "0.2.1", latest: "v0.2.2"),
                       .updateAvailable(current: "0.2.1", latest: "v0.2.2"))
    }

    func testStatusSemverComparisonNotStringOrder() {
        // 0.2.10 > 0.2.9：字符串比较 "0.2.9" > "0.2.10" 会误判方向；
        // SemVer 正确判定 current(0.2.9) < latest(0.2.10) → updateAvailable。
        XCTAssertEqual(AppUpdateStatus.status(current: "0.2.9", latest: "0.2.10"),
                       .updateAvailable(current: "0.2.9", latest: "0.2.10"))
        // current(0.2.10) > latest(0.2.9) → aheadOfLatest（不能回退到更旧版本）。
        XCTAssertEqual(AppUpdateStatus.status(current: "0.2.10", latest: "0.2.9"),
                       .aheadOfLatest(current: "0.2.10", latest: "0.2.9"))
    }

    func testStatusUnknownWhenUnparseable() {
        XCTAssertEqual(AppUpdateStatus.status(current: nil, latest: nil), .unknown)
        XCTAssertEqual(AppUpdateStatus.status(current: "abc", latest: "v0.2.1"), .unknown)
        XCTAssertEqual(AppUpdateStatus.status(current: "0.2.1", latest: "not-a-version"), .unknown)
    }

    func testCurrentVersionReadsFromBundle() {
        // Bundle.main 在测试宿主里是测试包：读不到 CFBundleShortVersionString 属正常，
        // 这里只验证接口不 crash、返回 String?。
        _ = AppUpdateChecker.currentVersion
        XCTAssertNotNil(AppUpdateChecker.releasePageURL)
    }
}
