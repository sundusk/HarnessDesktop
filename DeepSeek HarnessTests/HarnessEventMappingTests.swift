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

    // MARK: - 子会话（subagent）过滤

    /// 基线上的子会话（parentSessionId 非空）不产生领域事件，id 交给调用方登记。
    func testSummaryChildSessionIgnoredAndRecorded() {
        let summary = HarnessSessionSummary(
            sessionId: "child-1", running: true, updatedAt: 1, parentSessionId: "s1"
        )
        let mapping = HarnessGenericAdapter.mappedEvents(forSummary: summary, knownChildIDs: [])
        XCTAssertTrue(mapping.events.isEmpty)
        XCTAssertEqual(mapping.childIDs, ["child-1"])
    }

    /// 已登记为子会话的 id 即使再出现在基线中也不补发。
    func testSummaryKnownChildIgnored() {
        let summary = HarnessSessionSummary(
            sessionId: "child-1", running: true, updatedAt: 1, parentSessionId: "s1"
        )
        let mapping = HarnessGenericAdapter.mappedEvents(forSummary: summary, knownChildIDs: ["child-1"])
        XCTAssertTrue(mapping.events.isEmpty)
        XCTAssertTrue(mapping.childIDs.isEmpty)
    }

    /// `api-session/added` 携带 parentSessionId → 不产生事件、id 交调用方登记。
    func testChildSessionAddedIgnoredAndRecorded() {
        let mapping = HarnessGenericAdapter.mappedEvents(
            forEmit: "api-session/added",
            args: [.object([
                "sessionId": .string("child-1"),
                "running": .bool(true),
                "parentSessionId": .string("s1"),
            ])],
            knownChildIDs: []
        )
        XCTAssertTrue(mapping.events.isEmpty)
        XCTAssertEqual(mapping.childIDs, ["child-1"])
    }

    /// 子会话的 status / error / removed 一律忽略（一次性 agent，错误永不自行清除）。
    func testChildSessionStatusErrorRemovedIgnored() {
        let known: Set<String> = ["child-1"]
        XCTAssertTrue(HarnessGenericAdapter.mappedEvents(
            forEmit: "api-session/status", args: [.string("child-1"), .bool(true)], knownChildIDs: known
        ).events.isEmpty)
        XCTAssertTrue(HarnessGenericAdapter.mappedEvents(
            forEmit: "api-session/status", args: [.string("child-1"), .bool(false)], knownChildIDs: known
        ).events.isEmpty)
        XCTAssertTrue(HarnessGenericAdapter.mappedEvents(
            forEmit: "api-session/error", args: [.string("child-1"), .string("boom")], knownChildIDs: known
        ).events.isEmpty)
        XCTAssertTrue(HarnessGenericAdapter.mappedEvents(
            forEmit: "api-session/removed", args: [.string("child-1")], knownChildIDs: known
        ).events.isEmpty)
    }

    /// 子会话的审批 / 提问 waterfall 不进入全局状态。
    func testChildSessionWaterfallIgnored() {
        // 调用方在 handle() 中先查 childSessionIDs；这里验证判断函数。
        XCTAssertTrue(HarnessGenericAdapter.isChildSessionSummary(.object([
            "sessionId": .string("child-1"),
            "parentSessionId": .string("s1"),
        ])))
        XCTAssertFalse(HarnessGenericAdapter.isChildSessionSummary(.object([
            "sessionId": .string("s1"),
        ])))
    }

    /// 普通会话（无 parentSessionId）不受子会话过滤影响。
    func testTopLevelSessionUnaffectedByChildFilter() {
        let mapping = HarnessGenericAdapter.mappedEvents(
            forEmit: "api-session/added",
            args: [.object(["sessionId": .string("s1"), "running": .bool(true)])],
            knownChildIDs: ["child-1"]
        )
        XCTAssertEqual(mapping.events, [
            .sessionAdded(id: "s1"),
            .sessionRunningChanged(id: "s1", running: true),
        ])
        XCTAssertTrue(mapping.childIDs.isEmpty)
    }
}
