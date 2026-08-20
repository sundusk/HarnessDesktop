import Foundation

/// Release freshness is decided by GitHub; executable Managed updates are
/// gated by the independently reported npm installable version.
enum HarnessUpdateStatus: Equatable, Sendable {
    case unknown
    case checking
    case upToDate(current: HarnessVersion)
    case runningLatestButNpmBehind(
        running: HarnessVersion,
        latestRelease: HarnessVersion,
        latestInstallable: HarnessVersion
    )
    case updateAvailable(
        current: HarnessVersion,
        latestRelease: HarnessVersion,
        latestInstallable: HarnessVersion
    )
    case releaseAvailableButNotInstallable(
        current: HarnessVersion,
        latestRelease: HarnessVersion,
        latestInstallable: HarnessVersion?
    )
    case aheadOfLatest(current: HarnessVersion, latestRelease: HarnessVersion)
    case failed

    static func status(
        runningVersion: HarnessVersion?,
        latestRelease: HarnessVersion?,
        latestInstallable: HarnessVersion?
    ) -> HarnessUpdateStatus {
        guard let runningVersion, let latestRelease else { return .unknown }
        if runningVersion == latestRelease {
            if let latestInstallable, latestInstallable < latestRelease {
                return .runningLatestButNpmBehind(
                    running: runningVersion,
                    latestRelease: latestRelease,
                    latestInstallable: latestInstallable
                )
            }
            return .upToDate(current: runningVersion)
        }
        if runningVersion > latestRelease {
            return .aheadOfLatest(current: runningVersion, latestRelease: latestRelease)
        }
        guard let latestInstallable, latestInstallable >= latestRelease else {
            return .releaseAvailableButNotInstallable(
                current: runningVersion,
                latestRelease: latestRelease,
                latestInstallable: latestInstallable
            )
        }
        return .updateAvailable(
            current: runningVersion,
            latestRelease: latestRelease,
            latestInstallable: latestInstallable
        )
    }
}

extension HarnessUpdateStatus {
    /// True only when npm can actually supply a Managed Runtime candidate.
    var hasUpdate: Bool {
        if case .updateAvailable = self { return true }
        return false
    }

    var summary: String? {
        switch self {
        case .unknown, .checking, .failed:
            return nil
        case .upToDate(let current):
            return "已是最新：\(current)"
        case .runningLatestButNpmBehind(let running, _, let latestInstallable):
            return "当前运行已是最新：\(running)（npm 可安装：\(latestInstallable)）"
        case .updateAvailable(let current, let latestRelease, _):
            return "有更新可用：\(current) → \(latestRelease)"
        case .releaseAvailableButNotInstallable(_, let latestRelease, _):
            return "新版本 \(latestRelease) 已发布，npm 尚未同步"
        case .aheadOfLatest(let current, let latestRelease):
            return "当前版本高于官方最新：\(current)（最新 \(latestRelease)）"
        }
    }
}
