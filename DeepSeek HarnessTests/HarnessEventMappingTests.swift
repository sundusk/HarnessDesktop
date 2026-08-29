import XCTest
@testable import DeepSeek_Harness

/// `$events` 事件帧 → Domain Event 映射测试（规格 30.2：未知事件 / 坏帧不 crash）。
///
/// 事件名与 args 形状对照上游 `dsh-v0.1.2-alpha.1`
/// `packages/api/session-controller/src/index.ts` 的 emit 调用。
final class HarnessEventMappingTests: XCTestCase {

    // MARK: - emit

    private func summary(_ sessionId: String, running: Bool) -> HarnessJSONValue {
        .object(["sessionId": .string(sessionId), "running": .bool(running)])
    }

    func testSessionAddedWithoutRunning() {
        let events = HarnessGenericAdapter.domainEvents(
            forEmit: "api-session/added", args: [summary("s1", running: false)]
        )
        XCTAssertEqual(events, [.sessionAdded(id: "s1")])
    }

    /// added 携带 running=true 时同步派发 running 事件（基线即时生效）。
    func testSessionAddedWithRunning() {
        let events = HarnessGenericAdapter.domainEvents(
            forEmit: "api-session/added", args: [summary("s1", running: true)]
        )
        XCTAssertEqual(events, [
            .sessionAdded(id: "s1"),
            .sessionRunningChanged(id: "s1", running: true),
        ])
    }

    func testSessionRemoved() {
        let events = HarnessGenericAdapter.domainEvents(
            forEmit: "api-session/removed", args: [.string("s1")]
        )
        XCTAssertEqual(events, [.sessionRemoved(id: "s1")])
    }

    func testSessionStatusRunning() {
        let events = HarnessGenericAdapter.domainEvents(
            forEmit: "api-session/status", args: [.string("s1"), .bool(true)]
        )
        XCTAssertEqual(events, [.sessionRunningChanged(id: "s1", running: true)])
    }

    func testSessionStatusIdle() {
        let events = HarnessGenericAdapter.domainEvents(
            forEmit: "api-session/status", args: [.string("s1"), .bool(false)]
        )
        XCTAssertEqual(events, [.sessionRunningChanged(id: "s1", running: false)])
    }

    func testSessionError() {
        let events = HarnessGenericAdapter.domainEvents(
            forEmit: "api-session/error", args: [.string("s1"), .string("boom")]
        )
        XCTAssertEqual(events, [.agentError(sessionID: "s1", message: "boom")])
    }

    func testSessionErrorMissingMessageDefaultsToUnknown() {
        let events = HarnessGenericAdapter.domainEvents(
            forEmit: "api-session/error", args: [.string("s1")]
        )
        XCTAssertEqual(events, [.agentError(sessionID: "s1", message: "unknown")])
    }

    /// activity 无领域对应：忽略。
    func testSessionActivityIgnored() {
        let events = HarnessGenericAdapter.domainEvents(
            forEmit: "api-session/activity", args: [.string("s1"), .number(1_730_000_000)]
        )
        XCTAssertTrue(events.isEmpty)
    }

    /// 未知事件：忽略（空数组），不 crash（规格 19）。
    func testUnknownEmitIgnored() {
        XCTAssertTrue(HarnessGenericAdapter.domainEvents(forEmit: "commands/change", args: []).isEmpty)
        XCTAssertTrue(HarnessGenericAdapter.domainEvents(forEmit: "totally/new-event", args: [.string("x")]).isEmpty)
    }

    /// 必要字段缺失：防御性返回空数组。
    func testMissingFieldsIgnored() {
        XCTAssertTrue(HarnessGenericAdapter.domainEvents(forEmit: "api-session/added", args: []).isEmpty)
        XCTAssertTrue(HarnessGenericAdapter.domainEvents(
            forEmit: "api-session/added", args: [.object(["running": .bool(true)])]
        ).isEmpty)
        XCTAssertTrue(HarnessGenericAdapter.domainEvents(
            forEmit: "api-session/status", args: [.string("s1")]
        ).isEmpty)
        XCTAssertTrue(HarnessGenericAdapter.domainEvents(forEmit: "api-session/removed", args: []).isEmpty)
    }

    // MARK: - waterfall

    func testApprovalRequested() {
        let event = HarnessGenericAdapter.domainEvent(fromWaterfall: "approval/request", agentId: "a1")
        XCTAssertEqual(event, .approvalRequested(sessionID: "a1"))
    }

    func testQuestionRequested() {
        let event = HarnessGenericAdapter.domainEvent(fromWaterfall: "user-questions/request", agentId: "a1")
        XCTAssertEqual(event, .questionRequested(sessionID: "a1"))
    }

    /// 缺 agentId：无法归属 session，忽略事件（但调用方仍应答 next）。
    func testWaterfallWithoutAgentIdIgnored() {
        XCTAssertNil(HarnessGenericAdapter.domainEvent(fromWaterfall: "approval/request", agentId: nil))
        XCTAssertNil(HarnessGenericAdapter.domainEvent(fromWaterfall: "approval/request", agentId: ""))
    }

    /// 未知 waterfall：忽略。
    func testUnknownWaterfallIgnored() {
        XCTAssertNil(HarnessGenericAdapter.domainEvent(fromWaterfall: "cordis/request-run", agentId: "a1"))
    }

    // MARK: - cancel

    func testApprovalResolved() {
        let event = HarnessGenericAdapter.resolutionEvent(forWaterfall: "approval/request", agentId: "a1")
        XCTAssertEqual(event, .approvalResolved(sessionID: "a1"))
    }

    func testQuestionResolved() {
        let event = HarnessGenericAdapter.resolutionEvent(forWaterfall: "user-questions/request", agentId: "a1")
        XCTAssertEqual(event, .questionResolved(sessionID: "a1"))
    }

    func testResolutionWithoutAgentIdIgnored() {
        XCTAssertNil(HarnessGenericAdapter.resolutionEvent(forWaterfall: "approval/request", agentId: nil))
        XCTAssertNil(HarnessGenericAdapter.resolutionEvent(forWaterfall: "user-questions/request", agentId: ""))
    }

    // MARK: - session 基线

    func testSummaryBaselineEvents() {
        let events = HarnessGenericAdapter.domainEvents(
            forSummary: HarnessSessionSummary(sessionId: "s1", running: true, updatedAt: 1)
        )
        XCTAssertEqual(events, [
            .sessionAdded(id: "s1"),
            .sessionRunningChanged(id: "s1", running: true),
        ])
    }

    func testSummaryBaselineIdleSession() {
        let events = HarnessGenericAdapter.domainEvents(
            forSummary: HarnessSessionSummary(sessionId: "s1", running: false, updatedAt: nil)
        )
        XCTAssertEqual(events, [.sessionAdded(id: "s1")])
    }
}
