import XCTest
import SwiftUI
@testable import DeepSeek_Harness

/// MoodBallSettings 持久化 / 默认值 / 钳制测试。
@MainActor
final class MoodBallSettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "MoodBallSettingsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testDefaults() {
        let settings = MoodBallSettings(defaults: defaults)
        XCTAssertEqual(settings.ballSize, 120)
        XCTAssertEqual(settings.breathingSpeed, 2.0)
        XCTAssertEqual(settings.showEyes, true)
        XCTAssertEqual(settings.eyeColor, .black)
        XCTAssertEqual(settings.showStatusBubble, true)
        XCTAssertEqual(settings.glowEnabled, true)
        XCTAssertEqual(settings.lockPosition, false)
        XCTAssertEqual(settings.clickThroughMode, .hover)
        XCTAssertEqual(settings.rememberPosition, true)
        XCTAssertEqual(settings.isBallVisible, true)
        XCTAssertNil(settings.savedBallPosition)
        // 契约默认色
        XCTAssertEqual(colorToHex(settings.moodColors["idle"]!), 0x60a5fa)
        XCTAssertEqual(colorToHex(settings.moodColors["waiting"]!), 0x34d399)
        XCTAssertEqual(colorToHex(settings.moodColors["authorizing"]!), 0xfacc15)
        XCTAssertEqual(colorToHex(settings.moodColors["questioning"]!), 0xec4899)
        XCTAssertEqual(colorToHex(settings.moodColors["done"]!), 0x22d3ee)
        XCTAssertEqual(colorToHex(settings.moodColors["failed"]!), 0xf87171)
        XCTAssertEqual(colorToHex(settings.disconnectedColor), 0x9ca3af)
    }

    func testPersistenceRoundTrip() {
        let settings = MoodBallSettings(defaults: defaults)
        settings.ballSize = 160
        settings.breathingSpeed = 3.2
        settings.showEyes = false
        settings.eyeColor = .white
        settings.showStatusBubble = false
        settings.glowEnabled = false
        settings.lockPosition = true
        settings.clickThroughMode = .always
        settings.rememberPosition = false
        settings.isBallVisible = false
        settings.setMoodColor("waiting", Color(hex: 0x123456))
        settings.disconnectedColor = Color(hex: 0x654321)
        settings.savedBallPosition = CGPoint(x: 100, y: 200)

        let reloaded = MoodBallSettings(defaults: defaults)
        XCTAssertEqual(reloaded.ballSize, 160)
        XCTAssertEqual(reloaded.breathingSpeed, 3.2)
        XCTAssertEqual(reloaded.showEyes, false)
        XCTAssertEqual(reloaded.eyeColor, .white)
        XCTAssertEqual(reloaded.showStatusBubble, false)
        XCTAssertEqual(reloaded.glowEnabled, false)
        XCTAssertEqual(reloaded.lockPosition, true)
        XCTAssertEqual(reloaded.clickThroughMode, .always)
        XCTAssertEqual(reloaded.rememberPosition, false)
        XCTAssertEqual(reloaded.isBallVisible, false)
        XCTAssertEqual(colorToHex(reloaded.moodColors["waiting"]!), 0x123456)
        XCTAssertEqual(colorToHex(reloaded.disconnectedColor), 0x654321)
        XCTAssertEqual(reloaded.savedBallPosition, CGPoint(x: 100, y: 200))
    }

    func testOutOfRangeValuesAreClampedOnReload() {
        // 直接写入越界值（UI 的 Slider 不会产生越界值，这里模拟损坏 / 手改 defaults）
        let first = MoodBallSettings(defaults: defaults)
        first.ballSize = 500
        first.breathingSpeed = 0.1

        let reloaded = MoodBallSettings(defaults: defaults)
        XCTAssertEqual(reloaded.ballSize, 200)
        XCTAssertEqual(reloaded.breathingSpeed, 0.5)
    }

    func testResetMoodColors() {
        let settings = MoodBallSettings(defaults: defaults)
        settings.setMoodColor("idle", Color(hex: 0x000000))
        settings.disconnectedColor = Color(hex: 0x000000)

        settings.resetMoodColors()
        XCTAssertEqual(colorToHex(settings.moodColors["idle"]!), 0x60a5fa)
        XCTAssertEqual(colorToHex(settings.disconnectedColor), 0x9ca3af)

        // 重置后新建实例仍是默认色（残留值已被清除）
        let reloaded = MoodBallSettings(defaults: defaults)
        XCTAssertEqual(colorToHex(reloaded.moodColors["idle"]!), 0x60a5fa)
        XCTAssertEqual(colorToHex(reloaded.disconnectedColor), 0x9ca3af)
    }

    func testSavedBallPositionClear() {
        let settings = MoodBallSettings(defaults: defaults)
        settings.savedBallPosition = CGPoint(x: 10, y: 20)
        XCTAssertNotNil(settings.savedBallPosition)

        settings.savedBallPosition = nil
        XCTAssertNil(settings.savedBallPosition)
    }

    func testClickThroughModeLabels() {
        XCTAssertEqual(ClickThroughMode.hover.label, "悬停时恢复响应")
        XCTAssertEqual(ClickThroughMode.always.label, "永远点击穿透")
        XCTAssertEqual(ClickThroughMode.never.label, "永不穿透")
    }
}
