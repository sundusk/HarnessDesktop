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
    var lastUpdatedAt: Date

    init(id: String, now: Date = Date()) {
        self.id = id
        self.isRunning = false
        self.pendingApprovalCount = 0
        self.pendingQuestionCount = 0
        self.lastError = nil
        self.lastUpdatedAt = now
    }
}
