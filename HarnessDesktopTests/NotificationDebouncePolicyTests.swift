import XCTest
@testable import HarnessDesktop

/// 通知防抖策略测试（规格 22：同一 Session 同类事件不刷屏 / 不重复通知）。
final class NotificationDebouncePolicyTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 0)

    func testFirstSendAllowed() {
        var policy = NotificationDebouncePolicy(minInterval: 30)
        XCTAssertTrue(policy.shouldSend(key: "session-1|completion", now: t0))
    }

    func testSecondWithinIntervalDenied() {
        var policy = NotificationDebouncePolicy(minInterval: 30)
        _ = policy.shouldSend(key: "s1|completion", now: t0)
        XCTAssertFalse(policy.shouldSend(key: "s1|completion", now: t0.addingTimeInterval(10)))
        XCTAssertFalse(policy.shouldSend(key: "s1|completion", now: t0.addingTimeInterval(29)))
    }

    func testAfterIntervalAllowed() {
        var policy = NotificationDebouncePolicy(minInterval: 30)
        _ = policy.shouldSend(key: "s1|completion", now: t0)
        XCTAssertTrue(policy.shouldSend(key: "s1|completion", now: t0.addingTimeInterval(30)))
        XCTAssertTrue(policy.shouldSend(key: "s1|completion", now: t0.addingTimeInterval(60)))
    }

    /// 不同 key 互不影响。
    func testKeysAreIndependent() {
        var policy = NotificationDebouncePolicy(minInterval: 30)
        _ = policy.shouldSend(key: "s1|completion", now: t0)
        XCTAssertTrue(policy.shouldSend(key: "s2|completion", now: t0))
        XCTAssertTrue(policy.shouldSend(key: "s1|error", now: t0))
    }

    /// 同一 session 不同事件类型独立防抖。
    func testDifferentEventTypesIndependent() {
        var policy = NotificationDebouncePolicy(minInterval: 30)
        _ = policy.shouldSend(key: "s1|completion", now: t0)
        XCTAssertTrue(policy.shouldSend(key: "s1|approval", now: t0))
    }

    func testZeroIntervalAlwaysAllows() {
        var policy = NotificationDebouncePolicy(minInterval: 0)
        XCTAssertTrue(policy.shouldSend(key: "s1", now: t0))
        XCTAssertTrue(policy.shouldSend(key: "s1", now: t0.addingTimeInterval(0.001)))
    }
}
