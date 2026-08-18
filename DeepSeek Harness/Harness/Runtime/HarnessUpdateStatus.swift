import Foundation

/// Harness 更新状态（2.0 规格 §11）。
///
/// 状态由纯函数 `status(current:latest:)` 计算，UI 不自行判断版本大小。
enum HarnessUpdateStatus: Equatable, Sendable {
    case unknown
    case checking
    case upToDate(current: HarnessVersion)
    case updateAvailable(current: HarnessVersion, latest: HarnessVersion)
    case aheadOfLatest(current: HarnessVersion, latest: HarnessVersion)
    case failed

    /// 依据 current / latest 计算更新状态（SemVer 优先级比较，规格 §11）。
    ///
    /// - current 或 latest 缺失 → `.unknown`；
    /// - current < latest → `.updateAvailable`；
    /// - current == latest → `.upToDate`；
    /// - current > latest → `.aheadOfLatest`（例如本地用了 rc 而 registry latest 更旧）。
    static func status(current: HarnessVersion?, latest: HarnessVersion?) -> HarnessUpdateStatus {
        guard let current, let latest else { return .unknown }
        if current == latest { return .upToDate(current: current) }
        if current < latest { return .updateAvailable(current: current, latest: latest) }
        return .aheadOfLatest(current: current, latest: latest)
    }
}

extension HarnessUpdateStatus {
    /// 是否有新版本可更新（菜单栏 / 设置页高亮用）。
    var hasUpdate: Bool {
        if case .updateAvailable = self { return true }
        return false
    }

    /// 面向用户的中文一行摘要（不包含任何敏感信息）。
    var summary: String? {
        switch self {
        case .unknown, .checking, .failed:
            return nil
        case .upToDate(let current):
            return "已是最新：\(current)"
        case .updateAvailable(let current, let latest):
            return "有更新可用：\(current) → \(latest)"
        case .aheadOfLatest(let current, let latest):
            return "当前版本高于最新：\(current)（最新 \(latest)）"
        }
    }
}
