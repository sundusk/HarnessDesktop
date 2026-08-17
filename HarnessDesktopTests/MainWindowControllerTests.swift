import XCTest
@testable import HarnessDesktop

/// MainWindowController 窗口恢复逻辑测试：恢复的 frame 落在离屏 / 已断开显示器上时，
/// 必须判定为不可用并回退居中（修复：重启后主窗口不可见）。
@MainActor
final class MainWindowControllerTests: XCTestCase {

    private let mainScreen = NSRect(x: 0, y: 0, width: 2560, height: 1410)

    func testFrameFullyOnScreenIsUsable() {
        let frame = NSRect(x: 500, y: 300, width: 1000, height: 700)
        XCTAssertTrue(MainWindowController.isFrameUsable(frame, visibleFrames: [mainScreen]))
    }

    func testFrameEntirelyOffScreenIsNotUsable() {
        let frame = NSRect(x: 5000, y: 300, width: 1000, height: 700)
        XCTAssertFalse(MainWindowController.isFrameUsable(frame, visibleFrames: [mainScreen]))
    }

    func testFrameCenterOffScreenIsNotUsable() {
        // 窗口大部分探出屏幕外、中心点不在任何可见区域内 → 判定不可用
        let frame = NSRect(x: 2400, y: 1400, width: 1000, height: 700)
        XCTAssertFalse(MainWindowController.isFrameUsable(frame, visibleFrames: [mainScreen]))
    }

    func testFrameOnSecondDisplayIsUsable() {
        // 副屏（位于主屏下方）上恢复的窗口应被保留，而不是被拉回主屏
        let secondScreen = NSRect(x: 0, y: -900, width: 1920, height: 900)
        let frame = NSRect(x: 400, y: -700, width: 1000, height: 600)
        XCTAssertTrue(MainWindowController.isFrameUsable(frame, visibleFrames: [mainScreen, secondScreen]))
    }

    func testNoScreensIsNotUsable() {
        let frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertFalse(MainWindowController.isFrameUsable(frame, visibleFrames: []))
    }
}
