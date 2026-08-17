import Foundation

/// ActivityReducer（规格 8 / 9）：
///
/// ```text
/// Harness Event
///     ↓
/// ActivityReducer
///     ↓
/// SessionRuntimeState[]
///     ↓
/// HarnessActivityState
/// ```
///
/// 全局状态优先级（规格 8）：
/// `Error > Waiting For Approval > Waiting For Input > Running > Idle`
///
/// Presentation 层（MenuBar / Notification / Dock / Pet）只允许依赖
/// `HarnessActivityState`，禁止自己实现优先级。
struct ActivityReducer: Sendable {
    private(set) var sessions: [String: SessionRuntimeState] = [:]
    private(set) var completions: [HarnessCompletionEvent] = []

    /// 消费一个 Domain Event。
    ///
    /// - Parameter now: 可注入时钟（测试用）；默认当前时间。
    mutating func reduce(_ event: HarnessDomainEvent, now: Date = Date()) {
        switch event {
        case .sessionAdded(let id):
            if sessions[id] == nil {
                sessions[id] = SessionRuntimeState(id: id, now: now)
            }
            // 已存在（重连基线 / 重复事件）→ 幂等忽略。

        case .sessionRemoved(let id):
            sessions[id] = nil

        case .sessionRunningChanged(let id, let running):
            guard var session = sessions[id] else {
                // 未跟踪的 session：宽容建立（事件可能先于 sessionAdded 到达）。
                var created = SessionRuntimeState(id: id, now: now)
                created.isRunning = running
                sessions[id] = created
                return
            }
            if session.isRunning && !running {
                // Agent 从 running → idle 可视为任务完成（transient event）。
                completions.append(HarnessCompletionEvent(sessionID: id, timestamp: now))
            }
            session.isRunning = running
            if running {
                // 新一轮工作开始，视作错误已处理。
                session.lastError = nil
            }
            session.lastUpdatedAt = now
            sessions[id] = session

        case .approvalRequested(let sessionID):
            guard var session = sessions[sessionID] else { return }
            session.pendingApprovalCount += 1
            session.lastUpdatedAt = now
            sessions[sessionID] = session

        case .approvalResolved(let sessionID):
            guard var session = sessions[sessionID] else { return }
            session.pendingApprovalCount = max(0, session.pendingApprovalCount - 1)
            session.lastUpdatedAt = now
            sessions[sessionID] = session

        case .questionRequested(let sessionID):
            guard var session = sessions[sessionID] else { return }
            session.pendingQuestionCount += 1
            session.lastUpdatedAt = now
            sessions[sessionID] = session

        case .questionResolved(let sessionID):
            guard var session = sessions[sessionID] else { return }
            session.pendingQuestionCount = max(0, session.pendingQuestionCount - 1)
            session.lastUpdatedAt = now
            sessions[sessionID] = session

        case .agentError(let sessionID, let message):
            guard var session = sessions[sessionID] else {
                var created = SessionRuntimeState(id: sessionID, now: now)
                created.lastError = message
                sessions[sessionID] = created
                return
            }
            session.lastError = message
            session.lastUpdatedAt = now
            sessions[sessionID] = session

        case .taskCompleted(let sessionID):
            guard var session = sessions[sessionID] else { return }
            if session.isRunning {
                completions.append(HarnessCompletionEvent(sessionID: sessionID, timestamp: now))
            }
            session.isRunning = false
            session.lastUpdatedAt = now
            sessions[sessionID] = session
        }
    }

    /// 全局活动状态（规格 8 优先级）。连接状态不在此判断——
    /// 连接不存在时的 `.disconnected` 由 Integration 层映射。
    func globalState() -> HarnessActivityState {
        for session in sessions.values where session.lastError != nil {
            return .error(message: session.lastError)
        }
        for session in sessions.values where session.pendingApprovalCount > 0 {
            return .waitingForApproval
        }
        for session in sessions.values where session.pendingQuestionCount > 0 {
            return .waitingForInput
        }
        for session in sessions.values where session.isRunning {
            return .running
        }
        return .idle
    }

    /// 取出并清空 transient 完成事件（Phase 6 通知消费点）。
    mutating func drainCompletions() -> [HarnessCompletionEvent] {
        let drained = completions
        completions = []
        return drained
    }
}
