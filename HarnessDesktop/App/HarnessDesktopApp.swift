import SwiftUI

/// HarnessDesktop 应用入口。
///
/// 架构原则：Attach First / Zero Mutation / Web Core + Native Enhancement。
///
/// Scene 结构（规格 24 分工）：
/// - 主窗口由 AppKit `MainWindowController` 管理（NSWindow / 位置恢复）；
/// - 菜单栏用 SwiftUI `MenuBarExtra`（基础菜单内容）；
/// - 设置页用 SwiftUI `Settings` scene。
@main
struct HarnessDesktopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                coordinator: appDelegate.coordinator,
                onOpenWindow: { appDelegate.showMainWindow() }
            )
        } label: {
            MenuBarAppIcon()
        }

        Settings {
            SettingsView(
                settings: appDelegate.coordinator.settings,
                onSettingsChanged: { appDelegate.coordinator.settingsDidChange() }
            )
        }
    }
}
