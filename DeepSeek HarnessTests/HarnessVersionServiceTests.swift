import XCTest
@testable import DeepSeek_Harness

// MARK: - Mocks

/// 可注入 HTTP fetch（记录请求次数）。
final class MockHTTPFetcher: HTTPDataFetching, @unchecked Sendable {
    var result: Result<(Data, URLResponse), Error>
    private(set) var requestCount = 0

    init(result: Result<(Data, URLResponse), Error>) {
        self.result = result
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requestCount += 1
        return try result.get()
    }
}

/// 内存版本缓存。
final class MockVersionCache: HarnessVersionCacheStoring, @unchecked Sendable {
    var lastUpdateCheckDate: Date?
    var latestKnownHarnessVersion: String?
}

/// 固定时钟。
struct MockClock: RuntimeClock {
    let date: Date
    func now() -> Date { date }
}

/// Phase 8：版本服务（规格 §11 / §12 / §35 Version / §29 single-flight）。
final class HarnessVersionServiceTests: XCTestCase {

    private let registryURL = URL(string: "https://registry.npmjs.org/@deepseek-ai%2Fdsh")!

    private func makeResponse(status: Int, json: String) -> (Data, URLResponse) {
        let response = HTTPURLResponse(url: registryURL, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(json.utf8), response)
    }

    private func makeRegistryJSON(latest: String) -> String {
        #"{"name":"@deepseek-ai/dsh","dist-tags":{"latest":"\#(latest)"},"versions":{}}"#
    }

    private func makeService(fetcher: MockHTTPFetcher,
                             cache: MockVersionCache = MockVersionCache(),
                             now: Date = Date()) -> HarnessVersionService {
        HarnessVersionService(
            provider: NPMRegistryVersionProvider(fetcher: fetcher),
            cache: cache,
            clock: MockClock(date: now)
        )
    }

    // MARK: - registry 解析

    func testFetchLatestVersionDecodesDistTagsLatest() async throws {
        let fetcher = MockHTTPFetcher(result: .success(makeResponse(status: 200, json: makeRegistryJSON(latest: "0.1.0-rc.7"))))
        let service = makeService(fetcher: fetcher)
        let version = try await service.fetchLatestVersion()
        XCTAssertEqual(version, HarnessVersion("0.1.0-rc.7"))
    }

    func testFetchLatestVersionPrerelease() async throws {
        let fetcher = MockHTTPFetcher(result: .success(makeResponse(status: 200, json: makeRegistryJSON(latest: "0.1.0-rc.8"))))
        let service = makeService(fetcher: fetcher)
        let version = try await service.fetchLatestVersion()
        XCTAssertEqual(version, HarnessVersion("0.1.0-rc.8"))
    }

    func testMalformedRegistryDataThrows() async {
        let fetcher = MockHTTPFetcher(result: .success(makeResponse(status: 200, json: #"{"not":"the right shape"}"#)))
        let service = makeService(fetcher: fetcher)
        do {
            _ = try await service.fetchLatestVersion()
            XCTFail("应抛出 malformedRegistryData")
        } catch {
            XCTAssertEqual(error as? HarnessVersionError, .malformedRegistryData)
        }
    }

    func testNon200StatusThrows() async {
        let fetcher = MockHTTPFetcher(result: .success(makeResponse(status: 503, json: "{}")))
        let service = makeService(fetcher: fetcher)
        do {
            _ = try await service.fetchLatestVersion()
            XCTFail("应抛出 unexpectedStatus")
        } catch {
            XCTAssertEqual(error as? HarnessVersionError, .unexpectedStatus(503))
        }
    }

    func testInvalidLatestVersionStringThrows() async {
        let fetcher = MockHTTPFetcher(result: .success(makeResponse(status: 200, json: makeRegistryJSON(latest: "not-a-version"))))
        let service = makeService(fetcher: fetcher)
        do {
            _ = try await service.fetchLatestVersion()
            XCTFail("应抛出 invalidLatestVersion")
        } catch {
            XCTAssertEqual(error as? HarnessVersionError, .invalidLatestVersion("not-a-version"))
        }
    }

    func testNetworkFailureThrows() async {
        let fetcher = MockHTTPFetcher(result: .failure(URLError(.notConnectedToInternet)))
        let service = makeService(fetcher: fetcher)
        do {
            _ = try await service.fetchLatestVersion()
            XCTFail("应抛出 URLError")
        } catch {
            XCTAssertTrue(error is URLError)
        }
    }

    // MARK: - 缓存与节流（规格 §12.1：6h）

    func testFreshCacheSkipsNetwork() async {
        let now = Date()
        let cache = MockVersionCache()
        cache.lastUpdateCheckDate = now.addingTimeInterval(-60) // 1 分钟前
        cache.latestKnownHarnessVersion = "0.1.0-rc.8"
        let fetcher = MockHTTPFetcher(result: .success(makeResponse(status: 200, json: makeRegistryJSON(latest: "0.1.0-rc.8"))))
        let service = makeService(fetcher: fetcher, cache: cache, now: now)

        let latest = await service.latestVersion(force: false)
        XCTAssertEqual(latest, HarnessVersion("0.1.0-rc.8"))
        XCTAssertEqual(fetcher.requestCount, 0, "缓存新鲜时不应发起网络请求")
    }

    func testStaleCacheTriggersNetwork() async {
        let now = Date()
        let cache = MockVersionCache()
        cache.lastUpdateCheckDate = now.addingTimeInterval(-7 * 60 * 60) // 7 小时前
        cache.latestKnownHarnessVersion = "0.1.0-rc.7"
        let fetcher = MockHTTPFetcher(result: .success(makeResponse(status: 200, json: makeRegistryJSON(latest: "0.1.0-rc.8"))))
        let service = makeService(fetcher: fetcher, cache: cache, now: now)

        let latest = await service.latestVersion(force: false)
        XCTAssertEqual(latest, HarnessVersion("0.1.0-rc.8"))
        XCTAssertEqual(fetcher.requestCount, 1)
    }

    func testNeverCheckedTriggersNetwork() async {
        let fetcher = MockHTTPFetcher(result: .success(makeResponse(status: 200, json: makeRegistryJSON(latest: "0.1.0-rc.7"))))
        let service = makeService(fetcher: fetcher)
        let latest = await service.latestVersion(force: false)
        XCTAssertEqual(latest, HarnessVersion("0.1.0-rc.7"))
        XCTAssertEqual(fetcher.requestCount, 1)
    }

    /// 手动检查（force = true）忽略节流（规格 §12.2）。
    func testManualCheckBypassesThrottle() async {
        let now = Date()
        let cache = MockVersionCache()
        cache.lastUpdateCheckDate = now.addingTimeInterval(-60)
        cache.latestKnownHarnessVersion = "0.1.0-rc.7"
        let fetcher = MockHTTPFetcher(result: .success(makeResponse(status: 200, json: makeRegistryJSON(latest: "0.1.0-rc.8"))))
        let service = makeService(fetcher: fetcher, cache: cache, now: now)

        let latest = await service.latestVersion(force: true)
        XCTAssertEqual(latest, HarnessVersion("0.1.0-rc.8"))
        XCTAssertEqual(fetcher.requestCount, 1, "手动检查必须绕过缓存")
        // 缓存被更新
        XCTAssertEqual(cache.latestKnownHarnessVersion, "0.1.0-rc.8")
        XCTAssertEqual(cache.lastUpdateCheckDate, now)
    }

    // MARK: - 网络失败语义（启动静默检查失败不打扰）

    func testNetworkFailureReturnsCachedFallback() async {
        let cache = MockVersionCache()
        cache.lastUpdateCheckDate = Date().addingTimeInterval(-7 * 60 * 60)
        cache.latestKnownHarnessVersion = "0.1.0-rc.7"
        let fetcher = MockHTTPFetcher(result: .failure(URLError(.notConnectedToInternet)))
        let service = makeService(fetcher: fetcher, cache: cache)

        let latest = await service.latestVersion(force: false)
        XCTAssertEqual(latest, HarnessVersion("0.1.0-rc.7"), "网络失败应回退旧缓存，不打扰用户")
    }

    func testNetworkFailureWithoutCacheReturnsNil() async {
        let fetcher = MockHTTPFetcher(result: .failure(URLError(.notConnectedToInternet)))
        let service = makeService(fetcher: fetcher)
        let latest = await service.latestVersion(force: false)
        XCTAssertNil(latest)
    }

    // MARK: - single-flight（规格 §29：version check single-flight）

    func testSingleFlightSharesConcurrentFetches() async throws {
        let fetcher = MockHTTPFetcher(result: .success(makeResponse(status: 200, json: makeRegistryJSON(latest: "0.1.0-rc.8"))))
        let service = makeService(fetcher: fetcher)

        async let first = service.fetchLatestVersion()
        async let second = service.fetchLatestVersion()
        _ = try await (first, second)

        XCTAssertEqual(fetcher.requestCount, 1, "并发查询应共享同一个网络任务")
    }

    // MARK: - shouldUseCache 纯逻辑

    func testShouldUseCache() {
        let now = Date()
        let cache = MockVersionCache()
        let service = makeService(fetcher: MockHTTPFetcher(result: .success(makeResponse(status: 200, json: "{}"))),
                                  cache: cache, now: now)
        XCTAssertFalse(service.shouldUseCache(now: now), "从未检查过 → 不命中缓存")

        cache.lastUpdateCheckDate = now.addingTimeInterval(-60)
        XCTAssertTrue(service.shouldUseCache(now: now), "1 分钟前检查 → 命中缓存")

        cache.lastUpdateCheckDate = now.addingTimeInterval(-7 * 60 * 60)
        XCTAssertFalse(service.shouldUseCache(now: now), "7 小时前检查 → 过期")

        cache.lastUpdateCheckDate = now.addingTimeInterval(-6 * 60 * 60 + 1)
        XCTAssertTrue(service.shouldUseCache(now: now), "恰在节流窗口内 → 命中缓存")
    }
}
