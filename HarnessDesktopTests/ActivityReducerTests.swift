import XCTest
@testable import HarnessDesktop

/// ActivityReducer 测试（规格 30.1）：单 Session 各状态 + 多 Session 优先级 + transient completion。
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
        XCTAssertEqual(ActivityReducer().globalState(), .idle)
    }

    func testRunning() {
        let reducer = reduced([.sessionAdded(id: "a"), .sessionRunningChanged(id: "a", running: true)])
        XCTAssertEqual(reducer.globalState(), .running)
        XCTAssertEqual(reducer.sessions["a"]?.isRunning, true)
    }

    func testWaitingForInput() {
        let reducer = reduced([.sessionAdded(id: "a"), .questionRequested(sessionID: "a")])
        XCTAssertEqual(reducer.globalState(), .waitingForInput)
        XCTAssertEqual(reducer.sessions["a"]?.pendingQuestionCount, 1)
    }

    func testWaitingForApproval() {
        let reducer = reduced([.sessionAdded(id: "a"), .approvalRequested(sessionID: "a")])
        XCTAssertEqual(reducer.globalState(), .waitingForApproval)
        XCTAssertEqual(reducer.sessions["a"]?.pendingApprovalCount, 1)
    }

    func testError() {
        let reducer = reduced([.sessionAdded(id: "a"), .agentError(sessionID: "a", message: "boom")])
        XCTAssertEqual(reducer.globalState(), .error(message: "boom"))
        XCTAssertEqual(reducer.sessions["a"]?.lastError, "boom")
    }

    // MARK: - 多 Session 优先级（规格 8）

    func testMultiSessionApprovalOverRunning() {
        let reducer = reduced([
            .sessionAdded(id: "a"), .sessionRunningChanged(id: "a", running: true),
            .sessionAdded(id: "b"), .approvalRequested(sessionID: "b"),
        ])
        XCTAssertEqual(reducer.globalState(), .waitingForApproval)
    }

    func testMultiSessionInputOverRunning() {
        let reducer = reduced([
            .sessionAdded(id: "a"), .sessionRunningChanged(id: "a", running: true),
            .sessionAdded(id: "b"), .questionRequested(sessionID: "b"),
        ])
        XCTAssertEqual(reducer.globalState(), .waitingForInput)
    }

    func testErrorOverApproval() {
        let reducer = reduced([
            .sessionAdded(id: "a"), .agentError(sessionID: "a", message: "boom"),
            .sessionAdded(id: "b"), .approvalRequested(sessionID: "b"),
        ])
        XCTAssertEqual(reducer.globalState(), .error(message: "boom"))
    }

    func testApprovalOverInput() {
        let reducer = reduced([
            .sessionAdded(id: "a"), .questionRequested(sessionID: "a"),
            .sessionAdded(id: "b"), .approvalRequested(sessionID: "b"),
        ])
        XCTAssertEqual(reducer.globalState(), .waitingForApproval)
    }

    func testMultipleSessionsRunning() {
        let reducer = reduced([
            .sessionAdded(id: "a"), .sessionRunningChanged(id: "a", running: true),
            .sessionAdded(id: "b"), .sessionRunningChanged(id: "b", running: true),
        ])
        XCTAssertEqual(reducer.globalState(), .running)
    }

    // MARK: - 解析 / 移除

    func testApprovalResolvedClears() {
        var reducer = reduced([.sessionAdded(id: "a"), .approvalRequested(sessionID: "a")])
        XCTAssertEqual(reducer.globalState(), .waitingForApproval)
        reducer.reduce(.approvalResolved(sessionID: "a"), now: now)
        XCTAssertEqual(reducer.globalState(), .idle)
    }

    func testQuestionResolvedClears() {
        var reducer = reduced([.sessionAdded(id: "a"), .questionRequested(sessionID: "a")])
        XCTAssertEqual(reducer.globalState(), .waitingForInput)
        reducer.reduce(.questionResolved(sessionID: "a"), now: now)
        XCTAssertEqual(reducer.globalState(), .idle)
    }

    func testSessionRemoved() {
        var reducer = reduced([.sessionAdded(id: "a"), .sessionRunningChanged(id: "a", running: true)])
        reducer.reduce(.sessionRemoved(id: "a"), now: now)
        XCTAssertEqual(reducer.globalState(), .idle)
        XCTAssertNil(reducer.sessions["a"])
    }

    func testErrorClearsOnNewWork() {
        var reducer = reduced([.sessionAdded(id: "a"), .agentError(sessionID: "a", message: "boom")])
        XCTAssertEqual(reducer.globalState(), .error(message: "boom"))
        reducer.reduce(.sessionRunningChanged(id: "a", running: true), now: now)
        XCTAssertEqual(reducer.globalState(), .running)
        XCTAssertNil(reducer.sessions["a"]?.lastError)
    }

    // MARK: - transient completion（规格 7.3）

    func testRunningToIdleEmitsCompletion() {
        var reducer = reduced([.sessionAdded(id: "a"), .sessionRunningChanged(id: "a", running: true)])
        XCTAssertTrue(reducer.completions.isEmpty)
        reducer.reduce(.sessionRunningChanged(id: "a", running: false), now: now)
        XCTAssertEqual(reducer.completions, [HarnessCompletionEvent(sessionID: "a", timestamp: now)])
        XCTAssertEqual(reducer.globalState(), .idle)
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
        XCTAssertEqual(reducer.globalState(), .idle)
        reducer.reduce(.sessionRunningChanged(id: "unknown", running: true), now: now)
        XCTAssertEqual(reducer.globalState(), .running)
        reducer.reduce(.agentError(sessionID: "unknown", message: "x"), now: now)
        XCTAssertEqual(reducer.globalState(), .error(message: "x"))
    }

    func testSessionAddedIsIdempotent() {
        var reducer = reduced([.sessionAdded(id: "a"), .sessionRunningChanged(id: "a", running: true)])
        reducer.reduce(.sessionAdded(id: "a"), now: now)
        XCTAssertEqual(reducer.globalState(), .running)
        XCTAssertEqual(reducer.sessions.count, 1)
    }
}
