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
    /// 终端命令检测到的本地 Harness 版本（`npx -y @deepseek-ai/dsh --version`）。
    ///
    /// 说明：`host.describe.version` 可能为上游硬编码占位值（如恒为 0.0.1），
    /// 因此比较时优先使用本字段（用户侧事实），握手值仅作回退。
    var detectedVersion: HarnessVersion?
    /// Managed Runtime 状态（未准备 / 已就绪）。
    var managedRuntime: ManagedRuntimeStatus = .unknown
    /// Managed 模式固定的 exact Harness 版本。
    var managedVersion: HarnessVersion?
    /// npm registry 最新版本（查询失败为 nil）。
    var latestVersion: HarnessVersion?
    /// 更新状态（由 current / latest 计算）。
    var updateStatus: HarnessUpdateStatus = .unknown
}

extension HarnessVersion {
    /// `host.describe` 可能返回上游硬编码占位版本（如恒为 `0.0.1`），
    /// 不代表真实安装版本；参与版本比较时应视为“当前版本未知”。
    var isDescribePlaceholder: Bool {
        self == HarnessVersion("0.0.1")
    }
}

extension HarnessEnvironmentReport {
    /// 当前应参与版本比较的版本（终端检测优先，其次运行中，其次 managed）。
    ///
    /// `host.describe` 的占位版本（如 `0.0.1`）视为“当前版本未知”，
    /// 以 latest 兜底——用户经 `npx @deepseek-ai/dsh` 运行时即跟踪 latest，
    /// 避免一直显示上游占位版本（0.0.1）而看不到真实版本。
    var currentVersion: HarnessVersion? {
        let raw = detectedVersion ?? runningVersion ?? managedVersion
        if let raw, raw.isDescribePlaceholder {
            return latestVersion
        }
        return raw
    }

    /// 刷新 updateStatus（以 current / latest 为准）。
    mutating func refreshUpdateStatus() {
        updateStatus = HarnessUpdateStatus.status(current: currentVersion, latest: latestVersion)
    }
}
