import AppKit
import SwiftUI

/// 主窗口控制器（AppKit 职责：NSWindow / 窗口位置恢复）。
///
/// - `frameAutosaveName` 自动保存并恢复窗口位置与尺寸；
/// - 关闭主窗口不终止应用（由 AppDelegate 的
///   `applicationShouldTerminateAfterLastWindowClosed` 保证）。
@MainActor
final class MainWindowController: NSWindowController {
    private static let frameAutosaveName = "HarnessDesktopMainWindow"

    init(coordinator: AppCoordinator) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "HarnessDesktop"
        window.minSize = NSSize(width: 700, height: 480)
        window.contentView = NSHostingView(rootView: MainWindowView(coordinator: coordinator))
        // 先恢复上次保存的 frame，再启用自动保存。
        window.setFrameUsingName(Self.frameAutosaveName)
        window.setFrameAutosaveName(Self.frameAutosaveName)
        window.center()

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
