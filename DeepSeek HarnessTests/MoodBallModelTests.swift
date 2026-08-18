import XCTest
import SwiftUI
@testable import DeepSeek_Harness

/// 心情球状态映射（HarnessActivityState → mood）与 transient 行为测试。
@MainActor
final class MoodBallModelTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "MoodBallModelTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - 状态映射（纯函数）

    func testMoodMappingFromActivityState() {
        XCTAssertEqual(MoodBallMood.mood(for: .disconnected), "disconnected")
        XCTAssertEqual(MoodBallMood.mood(for: .idle), "idle")
        XCTAssertEqual(MoodBallMood.mood(for: .running), "waiting")
        XCTAssertEqual(MoodBallMood.mood(for: .waitingForInput), "questioning")
        XCTAssertEqual(MoodBallMood.mood(for: .waitingForApproval), "authorizing")
        XCTAssertEqual(MoodBallMood.mood(for: .error(message: "boom")), "failed")
    }

    func testMoodLabels() {
        XCTAssertEqual(MoodBallMood.label(for: "idle"), "空闲")
        XCTAssertEqual(MoodBallMood.label(for: "waiting"), "正在思考中")
        XCTAssertEqual(MoodBallMood.label(for: "authorizing"), "等待你的授权")
        XCTAssertEqual(MoodBallMood.label(for: "questioning"), "做出你的抉择")
        XCTAssertEqual(MoodBallMood.label(for: "done"), "搞定啦")
        XCTAssertEqual(MoodBallMood.label(for: "failed"), "出错了")
        XCTAssertEqual(MoodBallMood.label(for: "disconnected"), "未连接")
        XCTAssertEqual(MoodBallMood.label(for: "unknown-mood"), "未知")
    }

    func testBubbleText() {
        // 空闲 / 未连接不显示气泡
        XCTAssertNil(MoodBallMood.bubbleText(for: "idle"))
        XCTAssertNil(MoodBallMood.bubbleText(for: "disconnected"))
        // 其余状态显示中文状态名
        XCTAssertEqual(MoodBallMood.bubbleText(for: "waiting"), "正在思考中")
        XCTAssertEqual(MoodBallMood.bubbleText(for: "authorizing"), "等待你的授权")
        XCTAssertEqual(MoodBallMood.bubbleText(for: "questioning"), "做出你的抉择")
        XCTAssertEqual(MoodBallMood.bubbleText(for: "failed"), "出错了")
        XCTAssertEqual(MoodBallMood.bubbleText(for: "done"), "搞定啦")
    }

    // MARK: - 模型行为

    func testNoCoordinatorMeansDisconnected() {
        let model = MoodBallModel(settings: MoodBallSettings(defaults: defaults))
        XCTAssertEqual(model.mood, "disconnected")
        XCTAssertNil(model.bubbleText)
    }

    func testTaskCompletionTransientCelebration() async {
        let model = MoodBallModel(settings: MoodBallSettings(defaults: defaults))
        XCTAssertNil(model.transientMood)

        model.noteTaskCompletion(holdDuration: 0.01)
        XCTAssertEqual(model.transientMood, "done")
        XCTAssertEqual(model.mood, "done")
        XCTAssertEqual(model.bubbleText, "搞定啦")

        // 短暂庆祝后回到真实状态
        try? await Task.sleep(for: .seconds(0.05))
        XCTAssertNil(model.transientMood)
        XCTAssertEqual(model.mood, "disconnected")
    }

    func testColorFollowsCustomizedSettings() {
        let settings = MoodBallSettings(defaults: defaults)
        settings.setMoodColor("done", Color(hex: 0x112233))
        let model = MoodBallModel(settings: settings)

        model.noteTaskCompletion()
        XCTAssertEqual(colorToHex(model.color), 0x112233)
    }

    func testWiggleTrigger() {
        let model = MoodBallModel(settings: MoodBallSettings(defaults: defaults))
        XCTAssertNil(model.wiggleTriggeredAt)
        model.triggerWiggle()
        XCTAssertNotNil(model.wiggleTriggeredAt)
    }

    func testVisibilityPassthrough() {
        let settings = MoodBallSettings(defaults: defaults)
        let model = MoodBallModel(settings: settings)
        XCTAssertEqual(model.isBallVisible, true)

        settings.isBallVisible = false
        XCTAssertEqual(model.isBallVisible, false)
    }
}
