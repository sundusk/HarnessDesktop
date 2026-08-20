import XCTest
@testable import DeepSeek_Harness

final class MockHTTPFetcher: HTTPDataFetching, @unchecked Sendable {
    var result: Result<(Data, URLResponse), Error>
    private(set) var requestCount = 0

    init(result: Result<(Data, URLResponse), Error>) { self.result = result }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requestCount += 1
        return try result.get()
    }
}

final class MockVersionCache: HarnessVersionCacheStoring, @unchecked Sendable {
    var lastReleaseCheckDate: Date?
    var latestKnownHarnessReleaseVersion: String?
    var lastInstallableCheckDate: Date?
    var latestKnownHarnessInstallableVersion: String?
}

struct MockClock: RuntimeClock {
    let date: Date
    func now() -> Date { date }
}

final class MockDualVersionProvider: HarnessReleaseVersionProviding, HarnessInstallableVersionProviding, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var releaseRequestCount = 0
    private(set) var installableRequestCount = 0
    var releaseResult: Result<HarnessVersion, Error>
    var installableResult: Result<HarnessVersion, Error>
    var delay: Duration = .zero

    init(release: Result<HarnessVersion, Error>, installable: Result<HarnessVersion, Error>) {
        releaseResult = release
        installableResult = installable
    }

    func fetchLatestReleaseVersion() async throws -> HarnessVersion {
        lock.withLock { releaseRequestCount += 1 }
        if delay != .zero { try await Task.sleep(for: delay) }
        return try releaseResult.get()
    }

    func fetchLatestInstallableVersion() async throws -> HarnessVersion {
        lock.withLock { installableRequestCount += 1 }
        if delay != .zero { try await Task.sleep(for: delay) }
        return try installableResult.get()
    }
}

final class HarnessVersionServiceTests: XCTestCase {
    private let registryURL = URL(string: "https://registry.npmjs.org/@deepseek-ai%2Fdsh")!

    private func response(status: Int, json: String) -> (Data, URLResponse) {
        let response = HTTPURLResponse(url: registryURL, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(json.utf8), response)
    }

    private func registryJSON(latest: String) -> String {
        #"{"name":"@deepseek-ai/dsh","dist-tags":{"latest":"\#(latest)"},"versions":{}}"#
    }

    private func makeProvider(
        release: Result<HarnessVersion, Error> = .success(HarnessVersion("0.1.0-rc.8")!),
        installable: Result<HarnessVersion, Error> = .success(HarnessVersion("0.1.0-rc.7")!)
    ) -> MockDualVersionProvider {
        MockDualVersionProvider(release: release, installable: installable)
    }

    private func makeService(
        provider: MockDualVersionProvider,
        cache: MockVersionCache = MockVersionCache(),
        now: Date = Date()
    ) -> HarnessVersionService {
        HarnessVersionService(
            releaseProvider: provider,
            installableProvider: provider,
            cache: cache,
            clock: MockClock(date: now)
        )
    }

    func testNPMProviderDecodesInstallableDistTagIncludingPrerelease() async throws {
        let fetcher = MockHTTPFetcher(result: .success(response(status: 200, json: registryJSON(latest: "0.1.0-rc.8"))))
        let version = try await NPMRegistryVersionProvider(fetcher: fetcher).fetchLatestInstallableVersion()
        XCTAssertEqual(version, HarnessVersion("0.1.0-rc.8"))
    }

    func testNPMProviderRejectsMalformedRegistryData() async {
        let fetcher = MockHTTPFetcher(result: .success(response(status: 200, json: #"{"not":"the right shape"}"#)))
        do {
            _ = try await NPMRegistryVersionProvider(fetcher: fetcher).fetchLatestInstallableVersion()
            XCTFail("缺少 dist-tags.latest 必须失败")
        } catch {
            XCTAssertEqual(error as? HarnessVersionError, .malformedRegistryData)
        }
    }

    func testNPMProviderRejectsNon200AndInvalidVersion() async {
        let non200 = MockHTTPFetcher(result: .success(response(status: 503, json: "{}")))
        do {
            _ = try await NPMRegistryVersionProvider(fetcher: non200).fetchLatestInstallableVersion()
            XCTFail("非 2xx 必须失败")
        } catch {
            XCTAssertEqual(error as? HarnessVersionError, .unexpectedStatus(503))
        }

        let invalid = MockHTTPFetcher(result: .success(response(status: 200, json: registryJSON(latest: "not-a-version"))))
        do {
            _ = try await NPMRegistryVersionProvider(fetcher: invalid).fetchLatestInstallableVersion()
            XCTFail("非法版本必须失败")
        } catch {
            XCTAssertEqual(error as? HarnessVersionError, .invalidLatestVersion("not-a-version"))
        }
    }

    func testReleaseAndInstallableFreshCachesSkipOnlyTheirOwnNetworks() async {
        let now = Date()
        let cache = MockVersionCache()
        cache.lastReleaseCheckDate = now.addingTimeInterval(-60)
        cache.latestKnownHarnessReleaseVersion = "0.1.0-rc.8"
        cache.lastInstallableCheckDate = now.addingTimeInterval(-7 * 60 * 60)
        cache.latestKnownHarnessInstallableVersion = "0.1.0-rc.6"
        let provider = makeProvider()
        let service = makeService(provider: provider, cache: cache, now: now)

        async let release = service.latestReleaseVersion(force: false)
        async let installable = service.latestInstallableVersion(force: false)
        let values = await (release, installable)

        XCTAssertEqual(values.0, HarnessVersion("0.1.0-rc.8"))
        XCTAssertEqual(values.1, HarnessVersion("0.1.0-rc.7"))
        XCTAssertEqual(provider.releaseRequestCount, 0)
        XCTAssertEqual(provider.installableRequestCount, 1)
    }

    func testForceReleaseRefreshDoesNotRefreshInstallableCache() async {
        let now = Date()
        let cache = MockVersionCache()
        cache.lastReleaseCheckDate = now.addingTimeInterval(-60)
        cache.latestKnownHarnessReleaseVersion = "0.1.0-rc.7"
        cache.lastInstallableCheckDate = now.addingTimeInterval(-60)
        cache.latestKnownHarnessInstallableVersion = "0.1.0-rc.7"
        let provider = makeProvider()
        let service = makeService(provider: provider, cache: cache, now: now)

        let latest = await service.latestReleaseVersion(force: true)
        XCTAssertEqual(latest, HarnessVersion("0.1.0-rc.8"))
        XCTAssertEqual(provider.releaseRequestCount, 1)
        XCTAssertEqual(provider.installableRequestCount, 0)
        XCTAssertEqual(cache.latestKnownHarnessInstallableVersion, "0.1.0-rc.7")
        XCTAssertEqual(cache.lastInstallableCheckDate, now.addingTimeInterval(-60))
    }

    func testForceInstallableRefreshDoesNotRefreshReleaseCache() async {
        let now = Date()
        let cache = MockVersionCache()
        cache.lastReleaseCheckDate = now.addingTimeInterval(-60)
        cache.latestKnownHarnessReleaseVersion = "0.1.0-rc.8"
        cache.lastInstallableCheckDate = now.addingTimeInterval(-60)
        cache.latestKnownHarnessInstallableVersion = "0.1.0-rc.6"
        let provider = makeProvider()
        let service = makeService(provider: provider, cache: cache, now: now)

        let latest = await service.latestInstallableVersion(force: true)
        XCTAssertEqual(latest, HarnessVersion("0.1.0-rc.7"))
        XCTAssertEqual(provider.releaseRequestCount, 0)
        XCTAssertEqual(provider.installableRequestCount, 1)
        XCTAssertEqual(cache.latestKnownHarnessReleaseVersion, "0.1.0-rc.8")
        XCTAssertEqual(cache.lastReleaseCheckDate, now.addingTimeInterval(-60))
    }

    func testFailuresFallBackToEachIndependentCache() async {
        let cache = MockVersionCache()
        cache.latestKnownHarnessReleaseVersion = "0.1.0-rc.8"
        cache.latestKnownHarnessInstallableVersion = "0.1.0-rc.7"
        let failure = URLError(.notConnectedToInternet)
        let provider = makeProvider(release: .failure(failure), installable: .failure(failure))
        let service = makeService(provider: provider, cache: cache)

        async let release = service.latestReleaseVersion(force: true)
        async let installable = service.latestInstallableVersion(force: true)
        let values = await (release, installable)
        XCTAssertEqual(values.0, HarnessVersion("0.1.0-rc.8"))
        XCTAssertEqual(values.1, HarnessVersion("0.1.0-rc.7"))
    }

    func testReleaseAndInstallableUseIndependentSingleFlights() async throws {
        let provider = makeProvider()
        provider.delay = .milliseconds(30)
        let service = makeService(provider: provider)

        async let release1 = service.fetchLatestReleaseVersion()
        async let release2 = service.fetchLatestReleaseVersion()
        async let installable1 = service.fetchLatestInstallableVersion()
        async let installable2 = service.fetchLatestInstallableVersion()
        _ = try await (release1, release2, installable1, installable2)

        XCTAssertEqual(provider.releaseRequestCount, 1)
        XCTAssertEqual(provider.installableRequestCount, 1)
    }

    func testLegacyNPMCacheMigratesToInstallableCacheWithoutPopulatingRelease() {
        let suite = "HarnessVersionCacheMigration-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("0.1.0-rc.7", forKey: "runtime.version.latestKnown")
        defaults.set(Date(timeIntervalSince1970: 123), forKey: "runtime.version.lastUpdateCheckDate")

        let settings = AppSettings(store: SettingsStore(defaults: defaults))

        XCTAssertEqual(settings.latestKnownHarnessInstallableVersion, "0.1.0-rc.7")
        XCTAssertEqual(settings.lastInstallableCheckDate, Date(timeIntervalSince1970: 123))
        XCTAssertNil(settings.latestKnownHarnessReleaseVersion)
        XCTAssertNil(settings.lastReleaseCheckDate)
        XCTAssertEqual(defaults.string(forKey: "runtime.version.installable.latestKnown"), "0.1.0-rc.7")
    }
}
