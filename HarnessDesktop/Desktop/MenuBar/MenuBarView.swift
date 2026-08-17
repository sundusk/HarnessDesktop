import SwiftUI

/// 菜单栏（Menu Bar）内容。
///
/// 属于 SwiftUI「基础菜单内容」职责；只消费连接状态（Phase 2 尚无活动状态数据，
/// Sessions / Version 等展示项待 Phase 3/5 接入后补充）。
struct MenuBarView: View {
    let coordinator: AppCoordinator
    let onOpenWindow: () -> Void

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("HarnessDesktop")
                .font(.headline)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Button("Open Harness") {
                onOpenWindow()
            }
            Button("Reload") {
                coordinator.reload()
            }
            .keyboardShortcut("r")
            Button("Open in Browser") {
                coordinator.openInBrowser()
            }
            Button("Check Again") {
                coordinator.rediscover()
            }

            Divider()

            Button("Settings…") {
                openSettings()
            }
            Button("Quit HarnessDesktop") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }

    private var statusText: String {
        switch coordinator.connectionState {
        case .unknown, .discovering, .connecting:
            return "Status: Detecting…"
        case .connected:
            return "Status: Connected"
        case .unavailable:
            return "Status: Harness Not Running"
        case .reconnecting:
            return "Status: Reconnecting…"
        case .degraded(let reason):
            return "Status: Degraded (\(reason))"
        }
    }
}

/// 菜单栏状态图标。颜色只是 Presentation。
struct MenuBarStatusIcon: View {
    let state: HarnessConnectionState

    var body: some View {
        switch state {
        case .connected:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .unavailable:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.gray)
        case .degraded:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .unknown, .discovering, .connecting, .reconnecting:
            Image(systemName: "circle.dotted")
        }
    }
}
