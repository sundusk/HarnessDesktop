import AppKit
import SwiftUI
import os

private let petLog = Logger(subsystem: "dev.deepseekharness.DeepSeekHarness", category: "pet")

/// 心情球悬浮窗的生命周期协调器（AppKit 职责：NSPanel / 拖拽 / 位置记忆 /
/// 穿透切换 / 屏幕变化兜底）。
///
/// 状态只来自 `MoodBallModel`（由 `AppCoordinator.activityState` 派生），
/// 不接触 wire 事件 / DOM。面板尺寸（球大小 / 气泡增高）与显隐由
/// Observation 驱动：设置或模型状态变化时立即同步，不轮询。
@MainActor
final class MoodBallCoordinator {
    private let model: MoodBallModel
    private let settings: MoodBallSettings

    private var panel: MoodBallPanel?
    private var hoverMonitors: [Any] = []
    private var observationTask: Task<Void, Never>?
    private var changeContinuation: CheckedContinuation<Void, Never>?
    private var screenObserver: NSObjectProtocol?

    init(model: MoodBallModel, settings: MoodBallSettings) {
        self.model = model
        self.settings = settings
    }

    // MARK: - 生命周期

    func start() {
        guard panel == nil else { return }
        setupPanel()
        startObservations()
        startHoverMonitor()
        observeScreenChanges()
        petLog.info("心情球已启动")
    }

    func stop() {
        observationTask?.cancel()
        observationTask = nil
        // 唤醒挂起的观察任务，让它走取消分支正常退出（防止悬挂任务泄漏）
        resumeChangeWait()
        for monitor in hoverMonitors {
            NSEvent.removeMonitor(monitor)
        }
        hoverMonitors = []
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        screenObserver = nil
        panel?.orderOut(nil)
        panel = nil
        MoodBallPanel.current = nil
        petLog.info("心情球已停止")
    }

    /// 设置面板「重置位置到右下角」
    func resetPosition() {
        guard let panel else { return }
        settings.savedBallPosition = nil
        positionAtBottomRight(panel)
    }

    // MARK: - 悬浮窗

    private func setupPanel() {
        let size = settings.ballSize * 2.0
        let panel = MoodBallPanel(
            contentRect: NSRect(x: 0, y: 0, width: size, height: size),
            settings: settings
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating                       // 置顶（普通窗口之上；不覆盖全屏游戏等更高层级）
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = true               // 默认点击穿透（悬停时由 updateHover 恢复响应）
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.isExcludedFromWindowsMenu = true

        let hosting = NSHostingView(rootView: MoodBallView(model: model, settings: settings))
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hosting

        // 优先恢复上次拖拽位置，否则放屏幕右下角
        if !panel.restoreSavedPosition() {
            positionAtBottomRight(panel)
        }
        MoodBallPanel.current = panel
        // 启动时按设置决定是否显示（避免已隐藏时闪一下）
        if settings.isBallVisible {
            panel.orderFrontRegardless()
        }
        self.panel = panel
        petLog.info("心情球面板已创建")
    }

    private func positionAtBottomRight(_ panel: NSPanel) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
                ?? NSScreen.main
                ?? NSScreen.screens.first else { return }
        let inset: CGFloat = 16
        let origin = NSPoint(
            x: screen.visibleFrame.maxX - panel.frame.width - inset,
            y: screen.visibleFrame.minY + inset
        )
        panel.setFrameOrigin(origin)
        petLog.info("心情球定位到右下角：\(Int(origin.x)),\(Int(origin.y))")
    }

    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.screenParametersChanged()
            }
        }
    }

    /// 显示器增删 / 分辨率变化后，若窗口中心不在任何屏幕的可视区内
    /// （可能只留一截在屏边、球心已甩到无屏幕区域，导致拖不到），
    /// 就把球收回鼠标所在屏的右下角。
    private func screenParametersChanged() {
        guard let panel, panel.isVisible else { return }
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        if !visibleFrames.contains(where: { $0.contains(center) }) {
            positionAtBottomRight(panel)
            petLog.info("屏幕变化：球心已不在可视区，收回右下角")
        }
    }

    // MARK: - 设置 / 状态联动（Observation 驱动，不轮询）

    private func startObservations() {
        observationTask?.cancel()
        observationTask = Task { [weak self] in
            guard let self else { return }
            await self.observationLoop()
        }
    }

    private func observationLoop() async {
        // 先应用一次当前状态，再阻塞等待任何相关状态变化
        applyPanelState()
        await waitForChange()
        guard !Task.isCancelled else { return }
        await observationLoop()
    }

    /// 用 `withObservationTracking` 注册对面板相关状态的监听，变化时唤醒循环。
    /// 所有变更都发生在 MainActor（设置 / 模型均为 MainActor 隔离）。
    private func waitForChange() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            changeContinuation = continuation
            withObservationTracking {
                _ = settings.ballSize
                _ = settings.showStatusBubble
                _ = settings.isBallVisible
                _ = settings.clickThroughMode
                _ = model.mood
            } onChange: { [weak self] in
                // onChange 可能在任意线程触发（保守起见跳回 MainActor），
                // 短暂强持有 self 直到唤醒循环，任务随即结束。
                Task { @MainActor in
                    self?.resumeChangeWait()
                }
            }
        }
        changeContinuation = nil
    }

    private func resumeChangeWait() {
        changeContinuation?.resume()
        changeContinuation = nil
    }

    /// 依据最新设置 / 状态同步面板：尺寸（含气泡增高）、显隐、穿透模式。
    private func applyPanelState() {
        guard let panel else { return }
        let showBubble = model.bubbleText != nil && settings.showStatusBubble
        let frame = panelFrame(ballSize: settings.ballSize, showBubble: showBubble)
        if !frame.equalTo(panel.frame) {
            panel.setFrame(frame, display: true)
            petLog.info("面板尺寸 -> \(Int(frame.width))x\(Int(frame.height)) 气泡=\(showBubble)")
        }
        if settings.isBallVisible {
            if !panel.isVisible {
                panel.orderFrontRegardless() // 恢复显示时回到上次拖拽的位置，不重置
            }
        } else if panel.isVisible {
            panel.orderOut(nil)
        }
        updateHover()
    }

    /// 依据球大小与气泡显隐计算面板 frame：保持球心（水平中心、距底边 = 球径）屏幕位置不变。
    private func panelFrame(ballSize d: CGFloat, showBubble: Bool) -> NSRect {
        let w = d * 2.0
        let h = d * 2.0 + (showBubble ? MoodBallView.bubbleHeight : 0)
        let old = panel?.frame ?? NSRect(x: 0, y: 0, width: w, height: h)
        let ballCenterX = old.midX
        let ballCenterY = old.minY + old.width / 2 // 球心距底边 = 旧球径
        return NSRect(x: ballCenterX - w / 2, y: ballCenterY - d, width: w, height: h)
    }

    // MARK: - 悬停检测（穿透 ↔ 可拖拽）

    private func startHoverMonitor() {
        // 事件驱动：鼠标移动/拖拽时才检测，鼠标不动时零唤醒（取代固定频率轮询定时器）。
        // 本地监视器：本 app 活跃时触发；全局监视器：其它 app 前台时触发
        // （球默认点击穿透，鼠标事件不派发给本 app，只有全局监视器能看到光标移动）。
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        let local = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.updateHover()
            }
            return event
        }
        let global = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateHover()
            }
        }
        hoverMonitors = [local, global].compactMap { $0 }
    }

    private func updateHover() {
        guard let panel, panel.isVisible else { return }
        switch settings.clickThroughMode {
        case .always:
            // 永远穿透：常驻忽略鼠标事件（不可拖拽）
            if !panel.ignoresMouseEvents { panel.ignoresMouseEvents = true }
        case .never:
            // 永不穿透：常驻响应
            if panel.ignoresMouseEvents { panel.ignoresMouseEvents = false }
        case .hover:
            // 悬停恢复：鼠标在球体圆形区域（球心距底边 = 球径）内时响应（可拖拽），否则穿透。
            // 面板在气泡出现时会向上增高，因此命中判定收窄到球体圆形，气泡区域保持点击穿透。
            let mouse = NSEvent.mouseLocation
            let d = settings.ballSize
            let ballCenter = NSPoint(x: panel.frame.midX, y: panel.frame.minY + d)
            let inside = hypot(mouse.x - ballCenter.x, mouse.y - ballCenter.y) <= d
            let shouldIgnore = !panel.isDragging && !inside
            if panel.ignoresMouseEvents != shouldIgnore {
                panel.ignoresMouseEvents = shouldIgnore
            }
        }
    }
}
