import Foundation

/// 环境报告（2.0 规格 §9）：Environment Doctor 的只读输出。
///
/// 报告聚合了运行中的 Harness 信息、Managed Runtime 信息与版本信息；
/// 只允许由 Doctor / 上层协调器填充，UI 不自行推断。
struct HarnessEnvironmentReport: Equatable, Sendable {
    /// 探测到的 loopback 端点（Harness 正在运行时非 nil）。
    var discoveredEndpoint: HarnessEndpoint?
    /// 运行中 Harness 的所有权（external / managed）。
    var ownership: HarnessOwnership?
    /// 运行中 Harness 的版本（来自 `host.describe.version`，统一 Version Model）。
    var runningVersion: HarnessVersion?
    /// `host.describe` 返回已知占位版本时的诊断信息。
    var runningVersionWarning: String?
    /// Managed Runtime 状态（未准备 / 已就绪）。
    var managedRuntime: ManagedRuntimeStatus = .unknown
    /// Managed 模式固定的 exact Harness 版本。
    var managedVersion: HarnessVersion?
    /// GitHub Releases 中的官方最新版本（查询失败为 nil）。
    var latestReleaseVersion: HarnessVersion?
    /// npm Registry 当前可安装的最新版本（查询失败为 nil）。
    var latestInstallableVersion: HarnessVersion?
    /// 更新状态（由 current / release / installable 计算）。
    var updateStatus: HarnessUpdateStatus = .unknown
}

extension HarnessEnvironmentReport {
    /// 连接实例消失后立即清除其瞬态信息，避免 UI 继续显示旧运行版本。
    mutating func clearRunningHarness() {
        discoveredEndpoint = nil
        ownership = nil
        runningVersion = nil
        runningVersionWarning = nil
        refreshUpdateStatus()
    }

    /// 设置当前运行版本。已知的上游占位值不能当作真实运行版本展示或比较。
    mutating func setRunningVersion(from version: HarnessVersion?) {
        if version?.description == "0.0.1" {
            runningVersion = nil
            runningVersionWarning = "Harness 返回了占位版本 0.0.1，无法确定真实运行版本"
        } else {
            runningVersion = version
            runningVersionWarning = nil
        }
        refreshUpdateStatus()
    }

    /// 刷新 updateStatus：运行版本仅来自当前连接实例的 `host.describe`。
    /// npm 与 Managed Runtime 版本绝不用于推断当前运行实例。
    mutating func refreshUpdateStatus() {
        updateStatus = HarnessUpdateStatus.status(
            runningVersion: runningVersion,
            latestRelease: latestReleaseVersion,
            latestInstallable: latestInstallableVersion
        )
    }
}
