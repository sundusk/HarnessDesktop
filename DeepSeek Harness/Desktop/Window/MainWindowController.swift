import AppKit
import SwiftUI

/// 主窗口控制器（AppKit 职责：NSWindow / 窗口位置恢复）。
///
/// - `frameAutosaveName` 自动保存并恢复窗口位置与尺寸；
/// - 关闭主窗口不终止应用（由 AppDelegate 的
///   `applicationShouldTerminateAfterLastWindowClosed` 保证）。
@MainActor
final class MainWindowController: NSWindowController {
    private static let frameAutosaveName = "DeepSeekHarnessMainWindow"

    init(coordinator: AppCoordinator) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "DeepSeek Harness"
        window.minSize = NSSize(width: 700, height: 480)
        window.contentView = NSHostingView(rootView: MainWindowView(coordinator: coordinator))
        // 先恢复上次保存的 frame。
        let restored = window.setFrameUsingName(Self.frameAutosaveName)
        // 修复：恢复的 frame 可能落在已断开 / 离屏的显示器上，导致窗口不可见
        // （此前无条件 center()，既覆盖了恢复的位置，也兜不住离屏 frame）。
        // 仅当「恢复了且窗口中心仍在某个屏幕可见区域内」时才保留；否则回退到屏幕居中。
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        if !(restored && Self.isFrameUsable(window.frame, visibleFrames: visibleFrames)) {
            window.center()
        }
        window.setFrameAutosaveName(Self.frameAutosaveName)

        super.init(window: window)
    }

    /// 判断恢复的窗口 frame 是否仍然可用：窗口中心必须落在某个屏幕的可见区域内。
    ///
    /// 纯函数（不依赖真实 `NSScreen`），便于单元测试。
    static func isFrameUsable(_ frame: NSRect, visibleFrames: [NSRect]) -> Bool {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        return visibleFrames.contains { $0.contains(center) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
