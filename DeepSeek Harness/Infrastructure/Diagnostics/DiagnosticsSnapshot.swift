import Foundation

/// 诊断快照（文档 §28：非敏感诊断导出）。
///
/// 只包含连接状态 / 版本 / 错误类型 / 路径（无用户名可隐去），
/// **绝不包含**：Credentials、Prompt、用户文件、完整 session 内容。
struct DiagnosticsSnapshot: Equatable, Sendable {
    var appVersion: String
    var macOSVersion: String
    var endpointDescription: String
    var harnessReachable: Bool
    var harnessVersion: String?
    var connectionState: String
    var nativeIntegrationState: String
    var managedRuntime: String
    var managedVersion: String?
    var latestReleaseVersion: String?
    var latestInstallableVersion: String?
    var lastConnectionError: String?

    /// 渲染为可复制的文本。
    var text: String {
        var lines: [String] = []
        lines.append("DeepSeek Harness 诊断信息")
        lines.append("App 版本：\(appVersion)")
        lines.append("macOS：\(macOSVersion)")
        lines.append("Harness 端点：\(endpointDescription)")
        lines.append("Harness 可达：\(harnessReachable ? "是" : "否")")
        lines.append("Harness 版本：\(harnessVersion ?? "unknown")")
        lines.append("连接状态：\(connectionState)")
        lines.append("Native 集成：\(nativeIntegrationState)")
        lines.append("Managed Runtime：\(managedRuntime)")
        lines.append("Managed 版本：\(managedVersion ?? "无")")
        lines.append("官方最新版本：\(latestReleaseVersion ?? "unknown")")
        lines.append("npm 可安装版本：\(latestInstallableVersion ?? "unknown")")
        if let lastConnectionError, !lastConnectionError.isEmpty {
            lines.append("最近连接错误：\(lastConnectionError)")
        }
        return lines.joined(separator: "\n")
    }
}

enum DiagnosticsFactory {
    @MainActor
    static func make(coordinator: any DiagnosticsProviding) -> DiagnosticsSnapshot {
        DiagnosticsSnapshot(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            endpointDescription: "\(coordinator.settingsHost):\(coordinator.settingsPort)",
            harnessReachable: coordinator.connectionState != .unavailable,
            harnessVersion: coordinator.harnessVersion,
            connectionState: coordinator.connectionStateDescription,
            nativeIntegrationState: coordinator.nativeIntegrationDescription,
            managedRuntime: coordinator.managedRuntimeDescription,
            managedVersion: coordinator.managedVersion?.description,
            latestReleaseVersion: coordinator.latestReleaseVersion?.description,
            latestInstallableVersion: coordinator.latestInstallableVersion?.description,
            lastConnectionError: coordinator.lastConnectionError
        )
    }
}

/// 诊断数据提供协议（AppCoordinator 实现；便于测试）。
@MainActor
protocol DiagnosticsProviding {
    var settingsHost: String { get }
    var settingsPort: Int { get }
    var connectionState: HarnessConnectionState { get }
    var harnessVersion: String? { get }
    var connectionStateDescription: String { get }
    var nativeIntegrationDescription: String { get }
    var managedRuntimeDescription: String { get }
    var managedVersion: HarnessVersion? { get }
    var latestReleaseVersion: HarnessVersion? { get }
    var latestInstallableVersion: HarnessVersion? { get }
    var lastConnectionError: String? { get }
}
