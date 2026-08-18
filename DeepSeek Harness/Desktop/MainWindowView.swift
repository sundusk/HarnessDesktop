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
            case .connected, .degraded:
                // degraded（Native 增强不可用）不影响主 Web UI —— 必须继续可用（规格 5.1）。
                connectedContent
            case .unavailable, .reconnecting:
                NotRunningView(
                    host: coordinator.settings.host,
                    port: coordinator.settings.port,
                    versionHint: coordinator.environmentReport.updateStatus.summary,
                    runtimeStatus: coordinator.environmentReport.managedRuntime,
                    isPreparingRuntime: coordinator.isPreparingRuntime,
                    onRediscover: { coordinator.rediscover() },
                    onPrepareRuntime: { coordinator.prepareManagedRuntime() }
                )
            }
        }
        .frame(minWidth: 900, minHeight: 600)
    }

    @ViewBuilder
    private var connectedContent: some View {
        if let model = coordinator.webModel {
            HarnessWebView(model: model)
        } else {
            PlaceholderView(text: "正在连接…", showsSpinner: true)
        }
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
    /// Phase 8：最新版本 / 更新状态一行提示（nil 不显示；规格 §25 / §28）。
    let versionHint: String?
    /// Phase 10：Managed Runtime 状态（未准备 → 显示一键准备）。
    let runtimeStatus: ManagedRuntimeStatus
    /// Phase 10：一键准备是否进行中。
    let isPreparingRuntime: Bool
    let onRediscover: () -> Void
    /// Phase 10：一键准备（只调用 Helper 强类型 API，不执行任意命令）。
    let onPrepareRuntime: () -> Void

    @State private var copied = false

    private static let command = "npx @deepseek-ai/dsh web"

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "network.slash")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("DeepSeek Harness 未运行")
                .font(.title2.weight(.semibold))

            if isPreparingRuntime {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在准备运行环境…")
                        .foregroundStyle(.secondary)
                }
            } else if runtimeStatus == .missing {
                prepareSection
            } else if runtimeStatus == .ready {
                Text("运行环境已就绪（一键启动即将提供）")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

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
            if let versionHint {
                Text(versionHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("检测地址：\(host):\(port)")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
    }

    /// 一键准备区（文档 §25）：说明 + 主按钮。
    @ViewBuilder
    private var prepareSection: some View {
        VStack(spacing: 8) {
            Text("DeepSeek HarnessDesktop 可以为你准备隔离的运行环境。")
                .font(.callout)
            Text("不会修改系统 Node、Homebrew、Shell 配置或已有 Harness 数据。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("一键准备") {
                onPrepareRuntime()
            }
            .controlSize(.large)
        }
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
