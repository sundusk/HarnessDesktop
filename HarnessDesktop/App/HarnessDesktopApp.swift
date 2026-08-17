import SwiftUI

/// HarnessDesktop 应用入口。
///
/// 架构原则：Attach First / Zero Mutation / Web Core + Native Enhancement。
@main
struct HarnessDesktopApp: App {
    @State private var coordinator = AppCoordinator()

    var body: some Scene {
        WindowGroup("HarnessDesktop") {
            MainWindowView(coordinator: coordinator)
                .task {
                    coordinator.start()
                }
        }
        .commands {
            CommandMenu("Harness") {
                Button("Reload") {
                    coordinator.reload()
                }
                .keyboardShortcut("r")
                Button("Open in Browser") {
                    coordinator.openInBrowser()
                }
                Divider()
                Button("Check Again") {
                    coordinator.rediscover()
                }
            }
        }
    }
}
