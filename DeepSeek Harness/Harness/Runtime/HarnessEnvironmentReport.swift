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
    /// Managed Runtime 状态（未准备 / 已就绪）。
    var managedRuntime: ManagedRuntimeStatus = .unknown
    /// Managed 模式固定的 exact Harness 版本。
    var managedVersion: HarnessVersion?
    /// npm registry 最新版本（查询失败为 nil）。
    var latestVersion: HarnessVersion?
    /// 更新状态（由 current / latest 计算）。
    var updateStatus: HarnessUpdateStatus = .unknown
}

extension HarnessEnvironmentReport {
    /// 当前应参与版本比较的版本（运行中取 running，否则取 managed）。
    var currentVersion: HarnessVersion? {
        runningVersion ?? managedVersion
    }

    /// 刷新 updateStatus（以 current / latest 为准）。
    mutating func refreshUpdateStatus() {
        updateStatus = HarnessUpdateStatus.status(current: currentVersion, latest: latestVersion)
    }
}
