import Foundation

/// 单个 Session 的运行时状态（规格 7.4）。
///
/// 禁止用单一 `isRunning` 代表整个 Harness —— 多 Session 从第一天考虑。
struct SessionRuntimeState: Equatable, Sendable {
    let id: String

    var isRunning: Bool
    var pendingApprovalCount: Int
    var pendingQuestionCount: Int
    var lastError: String?
    /// 最近一次错误的时间；与 `lastError` 成对出现，用于错误「新鲜度」判定
    /// （过期错误不进入全局状态，避免旧错误永远压制新工作）。
    var lastErrorAt: Date?
    var lastUpdatedAt: Date

    init(id: String, now: Date = Date()) {
        self.id = id
        self.isRunning = false
        self.pendingApprovalCount = 0
        self.pendingQuestionCount = 0
        self.lastError = nil
        self.lastErrorAt = nil
        self.lastUpdatedAt = now
    }
}
