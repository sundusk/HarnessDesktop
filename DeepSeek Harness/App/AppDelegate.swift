import AppKit

/// 应用级 AppKit 委托：装配主窗口 / 菜单栏，管理 macOS 生命周期细节。
///
/// 职责（规格 24 AppKit 分工）：
/// - 关闭主窗口不终止应用；
/// - 点击 Dock 图标重新打开主窗口；
/// - 启动时按设置决定是否显示主窗口。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator: AppCoordinator

    private var mainWindowController: MainWindowController?
    private var menuBarCoordinator: MenuBarCoordinator?
    private var petCoordinator: MoodBallCoordinator?

    override init() {
        self.coordinator = AppCoordinator()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator.start()
        coordinator.requestNotificationAuthorization()
        // 菜单栏（NSStatusItem + NSMenu，锚定在鲸鱼图标正下方）
        let menuBar = MenuBarCoordinator(coordinator: coordinator, onOpenWindow: { [weak self] in
            self?.showMainWindow()
        })
        menuBar.start()
        menuBarCoordinator = menuBar
        // 心情球悬浮窗（不依赖 Harness 连接：未连接时显示灰球）
        let pet = MoodBallCoordinator(model: coordinator.petModel, settings: coordinator.petSettings)
        pet.start()
        petCoordinator = pet
        if coordinator.settings.launchMainWindowAtStart {
            showMainWindow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Phase 11：退出策略（文档 §19）——按设置停止 App 自己启动的 Managed Harness。
        // External Harness 永不被动（Never kill what you do not own）。
        coordinator.stopManagedHarnessForQuit()
        menuBarCoordinator?.stop()
        menuBarCoordinator = nil
        petCoordinator?.stop()
        petCoordinator = nil
    }

    /// 关闭最后一个窗口不退出应用（Menu Bar 仍然可用，Harness 不受影响）。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// 点击 Dock 图标时重新打开主窗口。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow()
        }
        return true
    }

    /// 从菜单栏 / Dock 重新打开主窗口。
    func showMainWindow() {
        if mainWindowController == nil {
            mainWindowController = MainWindowController(coordinator: coordinator)
        }
        mainWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 设置页「重置心情球位置到右下角」。
    func resetBallPosition() {
        petCoordinator?.resetPosition()
    }
}
