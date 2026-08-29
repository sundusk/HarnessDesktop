import XCTest
@testable import DeepSeek_Harness

/// ActivityReducer 测试（规格 30.1）：单 Session 各状态 + 多 Session 优先级
/// + transient completion + 错误新鲜度（过期错误不压制新工作）。
final class ActivityReducerTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func reduced(_ events: [HarnessDomainEvent]) -> ActivityReducer {
        var reducer = ActivityReducer()
        for event in events {
            reducer.reduce(event, now: now)
        }
        return reducer
    }

    // MARK: - 单 Session 状态

    func testInitialStateIsIdle() {
        XCTAssertEqual(ActivityReducer().globalState(now: now), .idle)
    }

    func testRunning() {
        let reducer = reduced([.sessionAdded(id: "a"), .sessionRunningChanged(id: "a", running: true)])
        XCTAssertEqual(reducer.globalState(now: now), .running)
        XCTAssertEqual(reducer.sessions["a"]?.isRunning, true)
    }

    func testWaitingForInput() {
        let reducer = reduced([.sessionAdded(id: "a"), .questionRequested(sessionID: "a")])
        XCTAssertEqual(reducer.globalState(now: now), .waitingForInput)
        XCTAssertEqual(reducer.sessions["a"]?.pendingQuestionCount, 1)
    }

    func testWaitingForApproval() {
        let reducer = reduced([.sessionAdded(id: "a"), .approvalRequested(sessionID: "a")])
        XCTAssertEqual(reducer.globalState(now: now), .waitingForApproval)
        XCTAssertEqual(reducer.sessions["a"]?.pendingApprovalCount, 1)
    }

    func testError() {
        let reducer = reduced([.sessionAdded(id: "a"), .agentError(sessionID: "a", message: "boom")])
        XCTAssertEqual(reducer.globalState(now: now), .error(message: "boom"))
        XCTAssertEqual(reducer.sessions["a"]?.lastError, "boom")
    }

    // MARK: - 多 Session 优先级（规格 8）

    func testMultiSessionApprovalOverRunning() {
        let reducer = reduced([
            .sessionAdded(id: "a"), .sessionRunningChanged(id: "a", running: true),
            .sessionAdded(id: "b"), .approvalRequested(sessionID: "b"),
        ])
        XCTAssertEqual(reducer.globalState(now: now), .waitingForApproval)
    }

    func testMultiSessionInputOverRunning() {
        let reducer = reduced([
            .sessionAdded(id: "a"), .sessionRunningChanged(id: "a", running: true),
            .sessionAdded(id: "b"), .questionRequested(sessionID: "b"),
        ])
        XCTAssertEqual(reducer.globalState(now: now), .waitingForInput)
    }

    func testErrorOverApproval() {
        let reducer = reduced([
            .sessionAdded(id: "a"), .agentError(sessionID: "a", message: "boom"),
            .sessionAdded(id: "b"), .approvalRequested(sessionID: "b"),
        ])
        XCTAssertEqual(reducer.globalState(now: now), .error(message: "boom"))
    }

    func testApprovalOverInput() {
        let reducer = reduced([
            .sessionAdded(id: "a"), .questionRequested(sessionID: "a"),
            .sessionAdded(id: "b"), .approvalRequested(sessionID: "b"),
        ])
        XCTAssertEqual(reducer.globalState(now: now), .waitingForApproval)
    }

    func testMultipleSessionsRunning() {
        let reducer = reduced([
            .sessionAdded(id: "a"), .sessionRunningChanged(id: "a", running: true),
            .sessionAdded(id: "b"), .sessionRunningChanged(id: "b", running: true),
        ])
        XCTAssertEqual(reducer.globalState(now: now), .running)
    }

    // MARK: - 解析 / 移除

    func testApprovalResolvedClears() {
        var reducer = reduced([.sessionAdded(id: "a"), .approvalRequested(sessionID: "a")])
        XCTAssertEqual(reducer.globalState(now: now), .waitingForApproval)
        reducer.reduce(.approvalResolved(sessionID: "a"), now: now)
        XCTAssertEqual(reducer.globalState(now: now), .idle)
    }

    func testQuestionResolvedClears() {
        var reducer = reduced([.sessionAdded(id: "a"), .questionRequested(sessionID: "a")])
        XCTAssertEqual(reducer.globalState(now: now), .waitingForInput)
        reducer.reduce(.questionResolved(sessionID: "a"), now: now)
        XCTAssertEqual(reducer.globalState(now: now), .idle)
    }

    // MARK: - turn 边界清除门（新协议 waterfall 无 resolved 推送的兜底）

    /// 提问门跨 turn 不存活：turn 结束（running=false）清除提问门。
    /// 复现：GUI 回答 ask_user_question 后观察者收不到任何 resolved 信号，
    /// 宠物曾永远卡在「做出你的抉择」。
    func testTurnEndClearsPendingQuestion() {
        var reducer = reduced([
            .sessionAdded(id: "a"),
            .sessionRunningChanged(id: "a", running: true),
            .questionRequested(sessionID: "a"),
        ])
        XCTAssertEqual(reducer.globalState(now: now), .waitingForInput)
        reducer.reduce(.sessionRunningChanged(id: "a", running: false), now: now)
        XCTAssertEqual(reducer.globalState(now: now), .idle)
        XCTAssertEqual(reducer.sessions["a"]?.pendingQuestionCount, 0)
    }

    /// 审批门同理：turn 结束清除审批门。
    func testTurnEndClearsPendingApproval() {
        var reducer = reduced([
            .sessionAdded(id: "a"),
            .sessionRunningChanged(id: "a", running: true),
            .approvalRequested(sessionID: "a"),
        ])
        XCTAssertEqual(reducer.globalState(now: now), .waitingForApproval)
        reducer.reduce(.sessionRunningChanged(id: "a", running: false), now: now)
        XCTAssertEqual(reducer.globalState(now: now), .idle)
        XCTAssertEqual(reducer.sessions["a"]?.pendingApprovalCount, 0)
    }

    /// 门挂起期间（agent 冻结在工具调用上）running 仍为 true：状态保持等待，
    /// 不能被运行中的其它信号清除。
    func testGateSurvivesWhileStillRunning() {
        var reducer = reduced([
            .sessionAdded(id: "a"),
            .sessionRunningChanged(id: "a", running: true),
            .questionRequested(sessionID: "a"),
            .sessionRunningChanged(id: "a", running: true),
        ])
        XCTAssertEqual(reducer.globalState(now: now), .waitingForInput)
    }

    /// turn 结束清除门时，完成 transient 仍然产生（宠物先庆祝再回 idle）。
    func testTurnEndGateClearStillEmitsCompletion() {
        var reducer = reduced([
            .sessionAdded(id: "a"),
            .sessionRunningChanged(id: "a", running: true),
            .questionRequested(sessionID: "a"),
        ])
        reducer.reduce(.sessionRunningChanged(id: "a", running: false), now: now)
        XCTAssertEqual(reducer.drainCompletions().count, 1)
        XCTAssertEqual(reducer.globalState(now: now), .idle)
    }

    func testSessionRemoved() {
        var reducer = reduced([.sessionAdded(id: "a"), .sessionRunningChanged(id: "a", running: true)])
        reducer.reduce(.sessionRemoved(id: "a"), now: now)
        XCTAssertEqual(reducer.globalState(now: now), .idle)
        XCTAssertNil(reducer.sessions["a"])
    }

    func testErrorClearsOnNewWork() {
        var reducer = reduced([.sessionAdded(id: "a"), .agentError(sessionID: "a", message: "boom")])
        XCTAssertEqual(reducer.globalState(now: now), .error(message: "boom"))
        reducer.reduce(.sessionRunningChanged(id: "a", running: true), now: now)
        XCTAssertEqual(reducer.globalState(now: now), .running)
        XCTAssertNil(reducer.sessions["a"]?.lastError)
    }

    // MARK: - 错误新鲜度（过期错误自愈）

    /// 错误在新鲜度窗口内仍显示；窗口过后不再压制其它 session 的运行。
    func testErrorExpiresAfterHoldDuration() {
        var reducer = reduced([.sessionAdded(id: "a"), .agentError(sessionID: "a", message: "boom")])
        // 错误发生时刻 + 窗口内：仍然显示「出错了」。
        XCTAssertEqual(reducer.globalState(now: now), .error(message: "boom"))
        XCTAssertEqual(
            reducer.globalState(now: now.addingTimeInterval(ActivityReducer.errorHoldDuration)),
            .error(message: "boom")
        )
        // 超过窗口：过期错误不再进入全局状态。
        XCTAssertEqual(
            reducer.globalState(now: now.addingTimeInterval(ActivityReducer.errorHoldDuration + 1)),
            .idle
        )
        // 错误内容本身保留（窗口内的查询仍可读到，只是不再压制）。
        XCTAssertEqual(reducer.sessions["a"]?.lastError, "boom")
    }

    /// 仍处于 running 的 session 上的错误不受窗口限制（turn 内错误持续可见）。
    func testErrorWhileRunningDoesNotExpire() {
        var reducer = reduced([
            .sessionAdded(id: "a"),
            .sessionRunningChanged(id: "a", running: true),
            .agentError(sessionID: "a", message: "boom"),
        ])
        XCTAssertEqual(
            reducer.globalState(now: now.addingTimeInterval(ActivityReducer.errorHoldDuration * 4)),
            .error(message: "boom")
        )
    }

    /// 核心回归：线程 A 出错（turn 已结束），用户在线程 B 重启任务——
    /// 思考中必须替换「出错了」，不能被 A 的过期错误压制。
    func testStaleErrorDoesNotBlockRunningFromOtherSession() {
        var reducer = reduced([
            .sessionAdded(id: "a"),
            .sessionRunningChanged(id: "a", running: true),
            .agentError(sessionID: "a", message: "boom"),
            .sessionRunningChanged(id: "a", running: false),  // A 的 turn 结束
        ])
        let later = now.addingTimeInterval(ActivityReducer.errorHoldDuration + 1)
        // B 开始新工作：思考中。
        reducer.reduce(.sessionAdded(id: "b"), now: later)
        reducer.reduce(.sessionRunningChanged(id: "b", running: true), now: later)
        XCTAssertEqual(reducer.globalState(now: later), .running)
    }

    /// 新鲜错误仍按规格 8 优先于其它 session 的运行（错误刚发生，用户应当看到）。
    func testFreshErrorStillDominatesRunning() {
        var reducer = reduced([
            .sessionAdded(id: "a"),
            .agentError(sessionID: "a", message: "boom"),
            .sessionRunningChanged(id: "a", running: false),
        ])
        reducer.reduce(.sessionAdded(id: "b"), now: now)
        reducer.reduce(.sessionRunningChanged(id: "b", running: true), now: now)
        XCTAssertEqual(reducer.globalState(now: now), .error(message: "boom"))
    }

    // MARK: - transient completion（规格 7.3）

    func testRunningToIdleEmitsCompletion() {
        var reducer = reduced([.sessionAdded(id: "a"), .sessionRunningChanged(id: "a", running: true)])
        XCTAssertTrue(reducer.completions.isEmpty)
        reducer.reduce(.sessionRunningChanged(id: "a", running: false), now: now)
        XCTAssertEqual(reducer.completions, [HarnessCompletionEvent(sessionID: "a", timestamp: now)])
        XCTAssertEqual(reducer.globalState(now: now), .idle)
    }

    func testTaskCompletedEventEmitsCompletion() {
        var reducer = reduced([.sessionAdded(id: "a"), .sessionRunningChanged(id: "a", running: true)])
        reducer.reduce(.taskCompleted(sessionID: "a"), now: now)
        XCTAssertEqual(reducer.drainCompletions().count, 1)
        XCTAssertTrue(reducer.completions.isEmpty)
    }

    func testNoCompletionOnIdleRunningChange() {
        var reducer = reduced([.sessionAdded(id: "a")])
        reducer.reduce(.sessionRunningChanged(id: "a", running: false), now: now)
        XCTAssertTrue(reducer.completions.isEmpty)
    }

    // MARK: - 容错

    func testUnknownSessionEventsAreTolerated() {
        var reducer = ActivityReducer()
        reducer.reduce(.approvalRequested(sessionID: "unknown"), now: now)
        XCTAssertEqual(reducer.globalState(now: now), .idle)
        reducer.reduce(.sessionRunningChanged(id: "unknown", running: true), now: now)
        XCTAssertEqual(reducer.globalState(now: now), .running)
        reducer.reduce(.agentError(sessionID: "unknown", message: "x"), now: now)
        XCTAssertEqual(reducer.globalState(now: now), .error(message: "x"))
    }

    func testSessionAddedIsIdempotent() {
        var reducer = reduced([.sessionAdded(id: "a"), .sessionRunningChanged(id: "a", running: true)])
        reducer.reduce(.sessionAdded(id: "a"), now: now)
        XCTAssertEqual(reducer.globalState(now: now), .running)
        XCTAssertEqual(reducer.sessions.count, 1)
    }
}
