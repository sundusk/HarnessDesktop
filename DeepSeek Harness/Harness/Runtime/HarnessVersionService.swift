import Foundation

protocol HTTPDataFetching: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPDataFetching {}

protocol RuntimeClock: Sendable {
    func now() -> Date
}

struct SystemClock: RuntimeClock {
    func now() -> Date { Date() }
}

protocol HarnessInstallableVersionProviding: Sendable {
    func fetchLatestInstallableVersion() async throws -> HarnessVersion
}

protocol HarnessVersionCacheStoring {
    var lastReleaseCheckDate: Date? { get set }
    var latestKnownHarnessReleaseVersion: String? { get set }
    var lastInstallableCheckDate: Date? { get set }
    var latestKnownHarnessInstallableVersion: String? { get set }
}

enum HarnessVersionError: Error, Equatable, Sendable {
    case invalidResponse
    case unexpectedStatus(Int)
    case malformedRegistryData
    case malformedReleaseData
    case noValidReleaseVersions
    case invalidLatestVersion(String)
}

private struct NPMRegistryDocument: Decodable {
    struct DistTags: Decodable {
        let latest: String?
    }

    let distTags: DistTags?

    enum CodingKeys: String, CodingKey {
        case distTags = "dist-tags"
    }
}

/// npm remains the source of truth for versions Managed Runtime can install.
struct NPMRegistryVersionProvider: HarnessInstallableVersionProviding {
    var fetcher: any HTTPDataFetching
    var packageName = "@deepseek-ai/dsh"
    var registryBaseURL = URL(string: "https://registry.npmjs.org")!

    init(fetcher: any HTTPDataFetching = URLSession.shared) {
        self.fetcher = fetcher
    }

    func fetchLatestInstallableVersion() async throws -> HarnessVersion {
        let encodedName = packageName.replacingOccurrences(of: "/", with: "%2F")
        guard let url = URL(string: "\(registryBaseURL.absoluteString)/\(encodedName)") else {
            throw HarnessVersionError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        let (data, response) = try await fetcher.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HarnessVersionError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw HarnessVersionError.unexpectedStatus(http.statusCode)
        }

        let document: NPMRegistryDocument
        do {
            document = try JSONDecoder().decode(NPMRegistryDocument.self, from: data)
        } catch {
            throw HarnessVersionError.malformedRegistryData
        }
        guard let latest = document.distTags?.latest else {
            throw HarnessVersionError.malformedRegistryData
        }
        guard let version = HarnessVersion(latest) else {
            throw HarnessVersionError.invalidLatestVersion(latest)
        }
        return version
    }
}

/// Owns independent GitHub-release and npm-installable caches, throttles, and
/// single-flight tasks. A failure in either source falls back only to its cache.
final class HarnessVersionService: @unchecked Sendable {
    private let releaseProvider: any HarnessReleaseVersionProviding
    private let installableProvider: any HarnessInstallableVersionProviding
    private var cache: any HarnessVersionCacheStoring
    private let clock: any RuntimeClock
    private let throttleInterval: TimeInterval

    private let stateLock = NSLock()
    private var releaseInFlight: TaskBox?
    private var installableInFlight: TaskBox?

    private final class TaskBox: @unchecked Sendable {
        let task: Task<HarnessVersion, Error>
        init(_ task: Task<HarnessVersion, Error>) { self.task = task }
    }

    static let defaultThrottleInterval: TimeInterval = 6 * 60 * 60

    init(
        releaseProvider: any HarnessReleaseVersionProviding = GitHubHarnessReleaseVersionProvider(),
        installableProvider: any HarnessInstallableVersionProviding = NPMRegistryVersionProvider(),
        cache: any HarnessVersionCacheStoring,
        clock: any RuntimeClock = SystemClock(),
        throttleInterval: TimeInterval = HarnessVersionService.defaultThrottleInterval
    ) {
        self.releaseProvider = releaseProvider
        self.installableProvider = installableProvider
        self.cache = cache
        self.clock = clock
        self.throttleInterval = throttleInterval
    }

    var cachedLatestRelease: HarnessVersion? {
        stateLock.withLock {
            cache.latestKnownHarnessReleaseVersion.flatMap(HarnessVersion.init)
        }
    }

    var cachedLatestInstallable: HarnessVersion? {
        stateLock.withLock {
            cache.latestKnownHarnessInstallableVersion.flatMap(HarnessVersion.init)
        }
    }

    var lastReleaseCheckDate: Date? {
        stateLock.withLock { cache.lastReleaseCheckDate }
    }

    var lastInstallableCheckDate: Date? {
        stateLock.withLock { cache.lastInstallableCheckDate }
    }

    func shouldUseReleaseCache(now: Date) -> Bool {
        shouldUseCache(lastCheckDate: lastReleaseCheckDate, now: now)
    }

    func shouldUseInstallableCache(now: Date) -> Bool {
        shouldUseCache(lastCheckDate: lastInstallableCheckDate, now: now)
    }

    func latestReleaseVersion(force: Bool) async -> HarnessVersion? {
        let now = clock.now()
        if !force, shouldUseReleaseCache(now: now), let cachedLatestRelease {
            return cachedLatestRelease
        }
        do {
            let latest = try await fetchLatestReleaseVersion()
            stateLock.withLock {
                cache.latestKnownHarnessReleaseVersion = latest.description
                cache.lastReleaseCheckDate = now
            }
            return latest
        } catch {
            AppLogger.version.error("官方 Release 版本查询失败：\(String(describing: error), privacy: .public)")
            return cachedLatestRelease
        }
    }

    func latestInstallableVersion(force: Bool) async -> HarnessVersion? {
        let now = clock.now()
        if !force, shouldUseInstallableCache(now: now), let cachedLatestInstallable {
            return cachedLatestInstallable
        }
        do {
            let latest = try await fetchLatestInstallableVersion()
            stateLock.withLock {
                cache.latestKnownHarnessInstallableVersion = latest.description
                cache.lastInstallableCheckDate = now
            }
            return latest
        } catch {
            AppLogger.version.error("npm 可安装版本查询失败：\(String(describing: error), privacy: .public)")
            return cachedLatestInstallable
        }
    }

    func fetchLatestReleaseVersion() async throws -> HarnessVersion {
        let box = stateLock.withLock { () -> TaskBox in
            if let releaseInFlight { return releaseInFlight }
            let new = TaskBox(Task { [releaseProvider] in
                try await releaseProvider.fetchLatestReleaseVersion()
            })
            releaseInFlight = new
            return new
        }
        defer {
            stateLock.withLock {
                if releaseInFlight === box { releaseInFlight = nil }
            }
        }
        return try await box.task.value
    }

    func fetchLatestInstallableVersion() async throws -> HarnessVersion {
        let box = stateLock.withLock { () -> TaskBox in
            if let installableInFlight { return installableInFlight }
            let new = TaskBox(Task { [installableProvider] in
                try await installableProvider.fetchLatestInstallableVersion()
            })
            installableInFlight = new
            return new
        }
        defer {
            stateLock.withLock {
                if installableInFlight === box { installableInFlight = nil }
            }
        }
        return try await box.task.value
    }

    private func shouldUseCache(lastCheckDate: Date?, now: Date) -> Bool {
        guard let lastCheckDate else { return false }
        return now.timeIntervalSince(lastCheckDate) < throttleInterval
    }
}
