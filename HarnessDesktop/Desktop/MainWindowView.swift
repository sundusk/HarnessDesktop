import SwiftUI

/// 主窗口内容。
///
/// 只消费 `HarnessConnectionState`，不自行推断网络状态。
struct MainWindowView: View {
    @Bindable var coordinator: AppCoordinator

    var body: some View {
        Group {
            switch coordinator.connectionState {
            case .unknown, .discovering, .connecting:
                PlaceholderView(text: "正在检测 DeepSeek Harness…", showsSpinner: true)
            case .connected:
                PlaceholderView(text: "Phase 1 将在此处显示 Harness Web UI", showsSpinner: false)
            case .unavailable, .reconnecting, .degraded:
                NotRunningView(
                    host: coordinator.settings.host,
                    port: coordinator.settings.port,
                    onRediscover: { coordinator.rediscover() }
                )
            }
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}

/// 检测 / 占位视图。
private struct PlaceholderView: View {
    let text: String
    let showsSpinner: Bool

    var body: some View {
        VStack(spacing: 12) {
            if showsSpinner {
                ProgressView()
            }
            Text(text)
                .foregroundStyle(.secondary)
        }
    }
}

/// DeepSeek Harness 未运行状态页。
///
/// - 「复制命令」只复制文本，不自动执行、不自动安装任何东西；
/// - 「重新检测」只重新请求 localhost。
private struct NotRunningView: View {
    let host: String
    let port: Int
    let onRediscover: () -> Void

    @State private var copied = false

    private static let command = "npx @deepseek-ai/dsh web"

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "network.slash")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("DeepSeek Harness 未运行")
                .font(.title2.weight(.semibold))
            Text("请先在终端运行：")
                .foregroundStyle(.secondary)
            Text(Self.command)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 12) {
                Button(copied ? "已复制" : "复制命令") {
                    copyCommand()
                }
                Button("重新检测") {
                    onRediscover()
                }
                .keyboardShortcut(.defaultAction)
            }
            Text("检测地址：\(host):\(port)")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
    }

    private func copyCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.command, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}
