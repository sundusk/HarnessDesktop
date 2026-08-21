import Foundation

/// 环境检查协议（2.0 规格 §34）。只读，不启动任何进程。
protocol HarnessEnvironmentInspecting: Sendable {
    func inspect() async -> HarnessEnvironmentReport
}

/// Environment Doctor（2.0 规格 §9）：启动检查顺序固定、只读。
///
/// 检查顺序（规格 §9）：
/// ```text
/// 1. Probe configured loopback endpoint
/// 2. 如果 Harness 正在运行
///    2.1 host.describe → running version
///    2.2 标记 ownership（Phase 8：无 Managed 身份匹配 → external）
/// 3. 后台查询 latest version（失败不影响报告其余部分）
/// 4. 如果没有 Harness
///    4.1 保留 Managed Runtime 状态 / managedVersion
///    4.2 由 UI 决定 Start / Prepare
/// ```
///
/// 依赖全部通过协议注入，单测不需要真实 Harness / npm / Node。
struct HarnessEnvironmentDoctor: HarnessEnvironmentInspecting {
    /// 端点探测。
    var discovery: any HarnessDiscovering
    /// 对运行中 Harness 执行 `host.describe` 并返回版本（失败返回 nil，Web UI 不受影响）。
    var describe: @Sendable (HarnessEndpoint) async -> HarnessVersion?
    /// 当前 Managed Runtime 状态。
    var managedRuntimeStatus: @Sendable () -> ManagedRuntimeStatus
    /// 当前 Managed 固定的 exact 版本。
    var managedVersion: @Sendable () -> HarnessVersion?
    /// npm 可安装版本查询（带缓存 / 节流；nil = 不可用）。
    /// GitHub Release 查询由上层协调器补充，不能阻塞本地环境检查。
    var latestInstallableVersionProvider: @Sendable () async -> HarnessVersion?

    func inspect() async -> HarnessEnvironmentReport {
        var report = HarnessEnvironmentReport()
        report.managedRuntime = managedRuntimeStatus()
        report.managedVersion = managedVersion()

        // 1. Probe configured loopback endpoint
        guard let endpoint = await discovery.discover() else {
            // 4. Harness 未运行：Managed Runtime 信息已在报告中，UI 决定 Start / Prepare。
            //    更新状态以 managed 版本为基准（有 managedVersion 时）。
            report.latestInstallableVersion = await latestInstallableVersionProvider()
            report.refreshUpdateStatus()
            return report
        }

        // 2. Harness 正在运行
        report.discoveredEndpoint = endpoint
        // 2.1 host.describe → running version（统一 Version Model）
        report.setRunningVersion(from: await describe(endpoint))
        // 2.2 所有权：Phase 8 尚无 Managed 身份匹配能力，未知来源一律 external
        //     （规格 §35 Ownership：discovered unknown process → external）。
        report.ownership = .external

        // 3. 后台查询 latest（失败不影响 Attach / Web UI）
        report.latestInstallableVersion = await latestInstallableVersionProvider()
        report.refreshUpdateStatus()
        return report
    }
}
