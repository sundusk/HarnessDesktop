import XCTest
@testable import HarnessDesktop

/// 事件帧 → Domain Event 映射测试（规格 30.2：未知事件 / 坏帧不 crash）。
final class HarnessEventMappingTests: XCTestCase {

    private func makeFrame(type: String, extra: [String: Any] = [:]) -> HarnessServerRequestFrame {
        var payload: [String: Any] = ["type": type]
        payload.merge(extra) { _, new in new }
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return HarnessServerRequestFrame(rpcId: "r1", method: "events.mux", payload: data)
    }

    func testHostSessionAdded() {
        let event = HarnessGenericAdapter.mapFrame(makeFrame(type: "host/session-added", extra: ["sessionId": "s1"]))
        XCTAssertEqual(event, .sessionAdded(id: "s1"))
    }

    /// mux 基线帧：session/subscribed 表示已附加的 session → sessionAdded。
    func testSessionSubscribedMapsToSessionAdded() {
        let event = HarnessGenericAdapter.mapFrame(makeFrame(type: "session/subscribed", extra: ["sessionId": "s1", "lastSeq": 3]))
        XCTAssertEqual(event, .sessionAdded(id: "s1"))
    }

    func testHostSessionRemoved() {
        let event = HarnessGenericAdapter.mapFrame(makeFrame(type: "host/session-removed", extra: ["sessionId": "s1"]))
        XCTAssertEqual(event, .sessionRemoved(id: "s1"))
    }

    func testHostSessionStatusRunning() {
        let event = HarnessGenericAdapter.mapFrame(makeFrame(type: "host/session-status", extra: ["sessionId": "s1", "running": true]))
        XCTAssertEqual(event, .sessionRunningChanged(id: "s1", running: true))
    }

    func testHostAgentError() {
        let event = HarnessGenericAdapter.mapFrame(makeFrame(type: "host/agent-error", extra: ["sessionId": "s1", "message": "boom"]))
        XCTAssertEqual(event, .agentError(sessionID: "s1", message: "boom"))
    }

    func testApprovalRequested() {
        let event = HarnessGenericAdapter.mapFrame(makeFrame(type: "approval/requested", extra: ["sessionId": "s1", "approvalId": "a1", "toolName": "bash"]))
        XCTAssertEqual(event, .approvalRequested(sessionID: "s1"))
    }

    func testApprovalResolved() {
        let event = HarnessGenericAdapter.mapFrame(makeFrame(type: "approval/resolved", extra: ["sessionId": "s1", "approvalId": "a1", "outcome": "granted"]))
        XCTAssertEqual(event, .approvalResolved(sessionID: "s1"))
    }

    func testQuestionRequested() {
        let event = HarnessGenericAdapter.mapFrame(makeFrame(type: "question/requested", extra: ["sessionId": "s1"]))
        XCTAssertEqual(event, .questionRequested(sessionID: "s1"))
    }

    func testQuestionResolved() {
        let event = HarnessGenericAdapter.mapFrame(makeFrame(type: "question/resolved", extra: ["sessionId": "s1", "questionRpcId": "q1", "outcome": "answered"]))
        XCTAssertEqual(event, .questionResolved(sessionID: "s1"))
    }

    /// 未知帧类型：忽略（nil），不 crash。
    func testUnknownFrameTypeReturnsNil() {
        XCTAssertNil(HarnessGenericAdapter.mapFrame(makeFrame(type: "host/workspace-changed")))
        XCTAssertNil(HarnessGenericAdapter.mapFrame(makeFrame(type: "session/event")))
        XCTAssertNil(HarnessGenericAdapter.mapFrame(makeFrame(type: "totally/new-frame")))
    }

    /// 坏 payload：忽略（nil），不 crash。
    func testMalformedPayloadReturnsNil() {
        let bad = HarnessServerRequestFrame(rpcId: "r", method: "events.mux", payload: Data("not json".utf8))
        XCTAssertNil(HarnessGenericAdapter.mapFrame(bad))
    }

    /// 必要字段缺失：防御性返回 nil。
    func testMissingSessionIdReturnsNil() {
        XCTAssertNil(HarnessGenericAdapter.mapFrame(makeFrame(type: "approval/requested", extra: ["approvalId": "a1"])))
        XCTAssertNil(HarnessGenericAdapter.mapFrame(makeFrame(type: "host/session-status", extra: ["sessionId": "s1"])))
    }
}
