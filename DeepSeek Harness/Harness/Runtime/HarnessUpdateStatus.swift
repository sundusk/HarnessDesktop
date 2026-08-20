import Foundation

/// Release freshness is decided by GitHub; executable Managed updates are
/// gated by the independently reported npm installable version.
enum HarnessUpdateStatus: Equatable, Sendable {
    case unknown
    case checking
    case upToDate(current: HarnessVersion)
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
        current: HarnessVersion?,
        latestRelease: HarnessVersion?,
        latestInstallable: HarnessVersion?
    ) -> HarnessUpdateStatus {
        guard let current, let latestRelease else { return .unknown }
        if current == latestRelease { return .upToDate(current: current) }
        if current > latestRelease {
            return .aheadOfLatest(current: current, latestRelease: latestRelease)
        }
        guard let latestInstallable, latestInstallable >= latestRelease else {
            return .releaseAvailableButNotInstallable(
                current: current,
                latestRelease: latestRelease,
                latestInstallable: latestInstallable
            )
        }
        return .updateAvailable(
            current: current,
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
        case .updateAvailable(let current, let latestRelease, _):
            return "有更新可用：\(current) → \(latestRelease)"
        case .releaseAvailableButNotInstallable(_, let latestRelease, _):
            return "新版本 \(latestRelease) 已发布，npm 尚未同步"
        case .aheadOfLatest(let current, let latestRelease):
            return "当前版本高于官方最新：\(current)（最新 \(latestRelease)）"
        }
    }
}
