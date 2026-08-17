import Foundation

/// 全局活动状态（规格 7.3）。
///
/// `completed` 不作为长期全局状态 —— 任务完成是 transient event
/// （`HarnessCompletionEvent`），UI 短暂播放完成动画后回到 `idle`。
enum HarnessActivityState: Equatable, Sendable {
    case disconnected
    case idle
    case running
    case waitingForInput
    case waitingForApproval
    case error(message: String?)
}

/// 任务完成的 transient event（规格 7.3）。
struct HarnessCompletionEvent: Equatable, Sendable {
    let sessionID: String
    let timestamp: Date
}
