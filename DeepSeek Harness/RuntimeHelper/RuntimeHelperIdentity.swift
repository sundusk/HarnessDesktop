import Foundation

// MARK: - 身份验证与所有权校验（Phase 9 骨架；文档 §32 安全要求）
//
// 本文件同时编译进 App target 与 RuntimeHelper target，全部为纯逻辑，可单测。

/// 调用方身份验证策略（Helper 侧）。
///
/// XPC 连接建立时，Helper 必须验证调用方是签名主 App：
/// - 只接受与 Helper 相同 team（Team ID）的调用方；
/// - ad-hoc / 无签名 / team 不匹配 → 拒绝连接（返回 `callerNotAuthorized`）。
enum RuntimeHelperCallerValidator {
    /// 是否接受该调用方。
    ///
    /// - Parameters:
    ///   - callerTeamID: 调用方的 Team ID（通过 SecCode 审计信息取得；无签名 / 失败为 nil）。
    ///   - expectedTeamID: Helper 自己的 Team ID（ad-hoc 构建为 nil）。
    /// - Returns: team 都存在且相等才接受；任一缺失（ad-hoc 开发构建）→ 拒绝，
    ///   即开发构建下 Helper 不可用（优雅降级为 helperUnavailable），不影响 Web Core。
    static func accepts(callerTeamID: String?, expectedTeamID: String?) -> Bool {
        guard let callerTeamID, let expectedTeamID else { return false }
        return callerTeamID == expectedTeamID
    }
}

/// Managed 进程所有权校验（App / Helper 共用；文档 §17 / §32）。
///
/// 规则（规格 §35 Ownership）：
/// - `registered`：当前活跃 generation 的注册记录（generationID + pid）；
/// - 只有 generationID **且** pid 都与注册一致才算 owned；
/// - PID 相同但 generation 不匹配（PID reuse）→ 不是 owned，禁止 Stop。
enum ManagedProcessOwnership {
    struct Registration: Equatable, Sendable {
        let generationID: UUID
        let pid: Int32
    }

    /// 判断给定的 (generationID, pid) 是否属于当前活跃 generation。
    static func isOwned(generationID: UUID, pid: Int32, registered: Registration?) -> Bool {
        guard let registered else { return false }
        return registered.generationID == generationID && registered.pid == pid
    }
}
