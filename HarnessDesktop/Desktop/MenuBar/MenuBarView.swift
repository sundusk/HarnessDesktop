import AppKit
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
                Text("会话数：\(coordinator.sessionCount)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if let version = coordinator.harnessInfo?.version {
                Text("版本：\(version)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Divider()

            Button("打开 Harness") {
                onOpenWindow()
            }
            Button("重新加载") {
                coordinator.reload()
            }
            .keyboardShortcut("r")
            Button("在浏览器中打开") {
                coordinator.openInBrowser()
            }
            Button("重新检测") {
                coordinator.rediscover()
            }

            Divider()

            Button("设置…") {
                openSettings()
            }
            Button("退出 HarnessDesktop") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }

    private var statusText: String {
        switch coordinator.connectionState {
        case .unknown, .discovering, .connecting:
            return "状态：正在检测…"
        case .unavailable:
            return "状态：Harness 未运行"
        case .reconnecting:
            return "状态：正在重连…"
        case .connected, .degraded:
            return activityStatusText
        }
    }

    /// 已连接时的活动状态文案（规格 21：Status: Working 等，中文文案）。
    private var activityStatusText: String {
        switch coordinator.activityState {
        case .disconnected:
            return "状态：已断开"
        case .idle:
            return "状态：空闲"
        case .running:
            return "状态：工作中"
        case .waitingForInput:
            return "状态：等待输入"
        case .waitingForApproval:
            return "状态：等待批准"
        case .error(let message):
            if let message, !message.isEmpty {
                return "状态：错误 — \(message)"
            }
            return "状态：错误"
        }
    }
}

/// 菜单栏状态图标：使用 Assets 里专用的 `MenuBarIcon` 模板图。
///
/// 该图标是 22×22 / 44×44(@2x) 的单色模板图（`template-rendering-intent`），
/// 由 App 图标（鲸鱼）生成并四周留了边距；系统会按菜单栏深浅色自动着色，
/// 且尺寸固定为菜单栏标准图标大小，不会出现裁剪或放大。
struct MenuBarAppIcon: View {
    var body: some View {
        Image("MenuBarIcon")
            .accessibilityLabel("HarnessDesktop")
    }
}
