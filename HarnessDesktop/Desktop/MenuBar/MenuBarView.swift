import SwiftUI

/// 菜单栏（Menu Bar）内容。
///
/// 属于 SwiftUI「基础菜单内容」职责；只消费 `HarnessActivityState` /
/// 连接状态 / 握手信息（规格 21），不直接依赖 wire 事件。
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
            if coordinator.sessionCount > 0 {
                Text("Sessions: \(coordinator.sessionCount)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if let version = coordinator.harnessInfo?.version {
                Text("Version: \(version)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

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
        case .unavailable:
            return "Status: Harness Not Running"
        case .reconnecting:
            return "Status: Reconnecting…"
        case .connected, .degraded:
            return activityStatusText
        }
    }

    /// 已连接时的活动状态文案（规格 21：Status: Working 等）。
    private var activityStatusText: String {
        switch coordinator.activityState {
        case .disconnected:
            return "Status: Disconnected"
        case .idle:
            return "Status: Idle"
        case .running:
            return "Status: Working"
        case .waitingForInput:
            return "Status: Waiting for Input"
        case .waitingForApproval:
            return "Status: Waiting for Approval"
        case .error(let message):
            if let message, !message.isEmpty {
                return "Status: Error — \(message)"
            }
            return "Status: Error"
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
