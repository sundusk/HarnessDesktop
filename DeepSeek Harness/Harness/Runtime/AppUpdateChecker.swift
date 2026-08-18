import Foundation

// MARK: - GitHub 最新 release 查询（沙箱安全：URLSession 直查，不执行 shell）

/// GitHub API 响应（宽松解码：只取需要的字段，其余忽略）。
private struct GitHubLatestReleaseDocument: Decodable {
    let tagName: String?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
    }
}

/// GitHub 最新 release 查询协议（规格 §34：可注入，测试用 mock）。
protocol GitHubLatestReleaseProviding: Sendable {
    /// 返回最新 release 的 tag（如 `v0.2.1`）。
    func fetchLatestTag() async throws -> String
}

/// 真实实现：`GET https://api.github.com/repos/<owner>/<repo>/releases/latest`。
///
/// 无鉴权限流 60 次/小时，手动检查完全够用；失败由调用方降级，不影响其他功能。
struct GitHubLatestReleaseProvider: GitHubLatestReleaseProviding {
    var fetcher: any HTTPDataFetching
    var repository = "sundusk/HarnessDesktop"
    var apiBaseURL = URL(string: "https://api.github.com")!

    init(fetcher: any HTTPDataFetching = URLSession.shared) {
        self.fetcher = fetcher
    }

    func fetchLatestTag() async throws -> String {
        // owner/repo 用真实路径分隔（appendingPathComponent 会把 "/" 编码成 %2F，
        // GitHub API 不认），与 NPMRegistryVersionProvider 同样的字符串拼接方式。
        guard let url = URL(string: "\(apiBaseURL.absoluteString)/repos/\(repository)/releases/latest") else {
            throw AppUpdateError.malformedData
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        let (data, response) = try await fetcher.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw AppUpdateError.unexpectedStatus(status)
        }
        do {
            let document = try JSONDecoder().decode(GitHubLatestReleaseDocument.self, from: data)
            guard let tag = document.tagName else { throw AppUpdateError.malformedData }
            return tag
        } catch {
            throw AppUpdateError.malformedData
        }
    }
}

enum AppUpdateError: Error, Equatable {
    /// 非 2xx 响应（含限流 / 仓库不存在 / 未授权）。
    case unexpectedStatus(Int)
    /// 响应体缺少 `tag_name` 或无法解码。
    case malformedData
}

// MARK: - App 更新状态（纯函数，测试友好）

/// DeepSeek Harness（macOS App 自身）的更新状态。
enum AppUpdateStatus: Equatable, Sendable, CustomStringConvertible {
    case unknown
    case upToDate(current: String)
    case updateAvailable(current: String, latest: String)
    /// 本地版本高于 GitHub 最新（开发版 / 预发布场景），提示不可回退到更旧版本。
    case aheadOfLatest(current: String, latest: String)

    var description: String {
        switch self {
        case .unknown:
            return "unknown"
        case .upToDate(let current):
            return "upToDate(\(current))"
        case .updateAvailable(let current, let latest):
            return "updateAvailable(\(current) → \(latest))"
        case .aheadOfLatest(let current, let latest):
            return "aheadOfLatest(\(current) > \(latest))"
        }
    }

    /// current / latest 无法解析为版本 → `.unknown`；相等 → `.upToDate`；
    /// current < latest → `.updateAvailable`；current > latest → `.aheadOfLatest`。
    ///
    /// 复用 `HarnessVersion` 做语义化比较（支持 tag 的 `v` 前缀，如 `v0.2.1`；
    /// `0.2.10 > 0.2.9` 等按 SemVer 正确比较，而非字符串顺序）。
    static func status(current: String?, latest: String?) -> AppUpdateStatus {
        guard let current, let latest,
              let currentVersion = HarnessVersion(current),
              let latestVersion = HarnessVersion(latest) else {
            return .unknown
        }
        if currentVersion == latestVersion { return .upToDate(current: current) }
        if currentVersion < latestVersion { return .updateAvailable(current: current, latest: latest) }
        return .aheadOfLatest(current: current, latest: latest)
    }
}

/// App 更新检查的常量与当前版本读取。
enum AppUpdateChecker {
    /// GitHub 发布页（「打开下载页」跳转目标）。
    static let releasePageURL = URL(string: "https://github.com/sundusk/HarnessDesktop/releases/latest")!

    /// 当前 App 版本（`CFBundleShortVersionString`，如 `0.2.1`）。
    static var currentVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }
}
