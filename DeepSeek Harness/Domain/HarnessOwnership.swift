import Foundation

/// Harness 进程所有权（2.0 规格 §3）。
///
/// 区分两种所有权是 Runtime Manager 的安全基石：
/// - `external`：用户 Terminal / 其他工具 / LaunchAgent 启动的 Harness；
///   Desktop 只能 Attach / 读取版本 / 检查更新，**禁止 Stop / Restart / Update / Rollback**
///   （Never kill what you do not own）；
/// - `managed`：由 HarnessDesktop 自己的 Runtime Supervisor 创建、且进程身份与
///   generation token 被 App 记录的 Harness；允许 Start / Stop / Restart / Update / Rollback。
enum HarnessOwnership: Equatable, Sendable {
    case external
    case managed
}

extension HarnessOwnership {
    /// 是否允许停止（只允许 managed；external 一律 false）。
    var canStop: Bool { self == .managed }

    /// 是否允许更新（只允许 managed；external 一律 false）。
    var canUpdate: Bool { self == .managed }

    /// 是否允许回退（只允许 managed；external 一律 false）。
    var canRollback: Bool { self == .managed }

    /// 是否允许由 Desktop 启动（只允许 managed）。
    var canStart: Bool { self == .managed }

    /// 面向用户的中文来源名。
    var displayName: String {
        switch self {
        case .external: return "外部"
        case .managed: return "HarnessDesktop"
        }
    }

    /// 判断所有权：只有“进程身份与 App 记录的 generation 匹配”才可能是 managed；
    /// 其余情况（未知 / 身份不匹配 / PID 复用）一律视为 external（2.0 规格 §35 Ownership）。
    static func resolve(generationMatchesManaged: Bool) -> HarnessOwnership {
        generationMatchesManaged ? .managed : .external
    }
}
