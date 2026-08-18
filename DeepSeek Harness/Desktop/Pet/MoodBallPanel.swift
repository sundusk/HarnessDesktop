import AppKit

/// 置顶悬浮窗：透明、无边框、不抢焦点、点击穿透。
///
/// 鼠标移入球体范围时恢复响应（可拖拽），移出后再次穿透（由
/// `MoodBallCoordinator` 的悬停检测驱动）。拖拽由 SwiftUI 手势驱动
/// （见 `MoodBallView`），位置持久化到 `MoodBallSettings`。
final class MoodBallPanel: NSPanel {
    /// 供 SwiftUI 拖拽手势引用当前悬浮窗
    static weak var current: MoodBallPanel?

    /// 拖拽进行中（悬停检测据此保持响应，避免拖到一半变成点击穿透）
    var isDragging = false

    private let settings: MoodBallSettings

    init(contentRect: NSRect, settings: MoodBallSettings) {
        self.settings = settings
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    /// 尝试恢复上次拖拽保存的位置；仅当设置允许且窗口中心仍在某个屏幕可视区内才生效
    @discardableResult
    func restoreSavedPosition() -> Bool {
        guard settings.rememberPosition, let saved = settings.savedBallPosition else { return false }
        // 用「窗口中心」判断而非整窗相交：避免显示器变化后只留一截在屏边、球心在屏外
        let center = NSPoint(x: saved.x + frame.width / 2, y: saved.y + frame.height / 2)
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        guard visibleFrames.contains(where: { $0.contains(center) }) else { return false }
        setFrameOrigin(saved)
        return true
    }

    /// 拖拽结束时保存当前位置（受「记住位置」设置控制）
    func persistPosition() {
        guard settings.rememberPosition else { return }
        settings.savedBallPosition = frame.origin
    }
}
