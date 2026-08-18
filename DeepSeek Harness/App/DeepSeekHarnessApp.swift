import SwiftUI

/// DeepSeek Harness 应用入口。
///
/// 架构原则：Attach First / Zero Mutation / Web Core + Native Enhancement。
///
/// Scene 结构（规格 24 分工）：
/// - 主窗口由 AppKit `MainWindowController` 管理（NSWindow / 位置恢复）；
/// - 菜单栏用 AppKit `NSStatusItem`（`MenuBarCoordinator`，菜单锚定在图标正下方；
///   不用 SwiftUI `MenuBarExtra`——macOS 26 下其菜单会错误右对齐到屏幕边缘）；
/// - 设置页用 SwiftUI `Settings` scene。
@main
struct DeepSeekHarnessApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(
                coordinator: appDelegate.coordinator,
                settings: appDelegate.coordinator.settings,
                petSettings: appDelegate.coordinator.petSettings,
                onResetBallPosition: { appDelegate.resetBallPosition() },
                onSettingsChanged: { appDelegate.coordinator.settingsDidChange() }
            )
        }
    }
}
