import Foundation

// MARK: - 可注入基础能力（规格 §34：所有新逻辑协议化、可注入，禁止在单测里真正起 Node / npm）

/// 可注入的 HTTP data fetch（测试用 mock）。
protocol HTTPDataFetching: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPDataFetching {}

/// 可注入时钟（缓存节流测试用）。
protocol RuntimeClock: Sendable {
    func now() -> Date
}

/// 系统时钟。
struct SystemClock: RuntimeClock {
    func now() -> Date { Date() }
}

/// 版本查询协议（规格 §34）。
protocol HarnessVersionProviding: Sendable {
    func fetchLatestVersion() async throws -> HarnessVersion
}

/// 版本检查缓存与节流存储（UserDefaults 实现见 `SettingsStore`）。
protocol HarnessVersionCacheStoring {
    /// 最近一次成功检查时间（nil = 从未成功检查过）。
    var lastUpdateCheckDate: Date? { get set }
    /// 最近一次已知最新版本（字符串；解析失败视为无缓存）。
    var latestKnownHarnessVersion: String? { get set }
}

// MARK: - 版本查询错误

enum HarnessVersionError: Error, Equatable, Sendable {
    case invalidResponse
    case unexpectedStatus(Int)
    case malformedRegistryData
    case invalidLatestVersion(String)
}

// MARK: - npm registry 查询（规格 §11）

/// npm registry 元数据文档（宽松解码：只解析需要的字段，其余忽略）。
private struct NPMRegistryDocument: Decodable {
    struct DistTags: Decodable {
        let latest: String?
    }

    let distTags: DistTags?

    enum CodingKeys: String, CodingKey {
        case distTags = "dist-tags"
    }
}

/// 通过 `URLSession` 直接查询 npm registry 的 `@deepseek-ai/dsh` 版本元数据。
///
/// 不执行 `npm view ...`（规格 §11：查询版本不需要 shell，更符合 Zero Configuration Mutation）。
struct NPMRegistryVersionProvider: HarnessVersionProviding {
    var fetcher: any HTTPDataFetching
    /// scoped package 名（npm registry 要求把 `/` 编码为 `%2F`）。
    var packageName = "@deepseek-ai/dsh"
    var registryBaseURL = URL(string: "https://registry.npmjs.org")!

    init(fetcher: any HTTPDataFetching = URLSession.shared) {
        self.fetcher = fetcher
    }

    func fetchLatestVersion() async throws -> HarnessVersion {
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
            // registry 数据格式异常：安全失败，不影响现有 Harness（规格 §11 / §33）。
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

// MARK: - 版本服务（缓存 + 节流 + single-flight，规格 §12 / §29）

/// Harness 版本服务：latest 查询、缓存、启动节流、手动强制检查。
///
/// - 启动静默检查：命中 6 小时节流直接返回缓存，网络失败不打扰（最多影响菜单栏状态）；
/// - 手动「检查 Harness 更新…」：`force = true` 忽略节流；
/// - 并发查询 single-flight：多个调用方共享同一个进行中的网络任务。
final class HarnessVersionService: @unchecked Sendable {
    private let provider: any HarnessVersionProviding
    /// var：协议属性是 `{ get set }`，值类型 conformer（SettingsStore）的 setter 是 mutating，
    /// 通过 existential 赋值要求容器可变。
    private var cache: any HarnessVersionCacheStoring
    private let clock: any RuntimeClock
    private let throttleInterval: TimeInterval

    private let lock = NSLock()
    /// single-flight：进行中的网络任务（Task 是 struct，用引用包装做身份比较）。
    private var inFlight: TaskBox?

    /// single-flight 任务引用包装。
    private final class TaskBox: @unchecked Sendable {
        let task: Task<HarnessVersion, Error>
        init(_ task: Task<HarnessVersion, Error>) { self.task = task }
    }

    /// 默认节流：距上次成功检查 < 6 小时 → 使用缓存（规格 §12.1）。
    static let defaultThrottleInterval: TimeInterval = 6 * 60 * 60

    init(provider: any HarnessVersionProviding = NPMRegistryVersionProvider(),
         cache: any HarnessVersionCacheStoring,
         clock: any RuntimeClock = SystemClock(),
         throttleInterval: TimeInterval = HarnessVersionService.defaultThrottleInterval) {
        self.provider = provider
        self.cache = cache
        self.clock = clock
        self.throttleInterval = throttleInterval
    }

    /// 缓存的最近已知最新版本（无缓存或解析失败为 nil）。
    var cachedLatest: HarnessVersion? {
        cache.latestKnownHarnessVersion.flatMap(HarnessVersion.init)
    }

    /// 最近一次成功检查时间。
    var lastCheckDate: Date? {
        cache.lastUpdateCheckDate
    }

    /// 是否命中节流（距上次成功检查 < throttleInterval；从未检查过则 false）。
    func shouldUseCache(now: Date) -> Bool {
        guard let last = cache.lastUpdateCheckDate else { return false }
        return now.timeIntervalSince(last) < throttleInterval
    }

    /// 获取最新版本（带缓存与节流）。
    ///
    /// - `force == false`：启动静默检查路径——缓存新鲜则直接返回缓存，不发网络请求；
    /// - `force == true`：菜单栏手动检查路径——忽略节流，强制重新查询；
    /// - 网络失败返回 nil（有旧缓存时回退旧缓存，不打扰用户）。
    func latestVersion(force: Bool) async -> HarnessVersion? {
        let now = clock.now()
        if !force, shouldUseCache(now: now), let cached = cachedLatest {
            return cached
        }
        do {
            let latest = try await fetchLatestVersion()
            cache.latestKnownHarnessVersion = latest.description
            cache.lastUpdateCheckDate = now
            return latest
        } catch {
            AppLogger.version.error("最新版本查询失败：\(String(describing: error), privacy: .public)")
            return cachedLatest
        }
    }

    /// 网络查询最新版本（single-flight：并发调用共享同一个任务）。
    ///
    /// 检查 + 写入在同一个 `withLock` 内完成，保证并发下只有一个网络任务被创建；
    /// `TaskBox` 引用包装用于 defer 清理时只清理自己创建的 inFlight。
    func fetchLatestVersion() async throws -> HarnessVersion {
        let box = lock.withLock { () -> TaskBox in
            if let existing = inFlight {
                return existing
            }
            let new = TaskBox(Task<HarnessVersion, Error> { [provider] in
                try await provider.fetchLatestVersion()
            })
            inFlight = new
            return new
        }
        defer {
            lock.withLock {
                if inFlight === box {
                    inFlight = nil
                }
            }
        }
        return try await box.task.value
    }
}
