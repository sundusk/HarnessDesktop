import XCTest
@testable import DeepSeek_Harness

// MARK: - Mocks

/// 可注入 Discovery。
struct MockDiscovery: HarnessDiscovering {
    var endpoint: HarnessEndpoint?
    func discover() async -> HarnessEndpoint? { endpoint }
}

/// Phase 8：Environment Doctor（2.0 规格 §9 检查顺序，只读）。
final class HarnessEnvironmentDoctorTests: XCTestCase {

    private var endpoint: HarnessEndpoint { .default }

    private func makeDoctor(discovery: MockDiscovery,
                            describe: @escaping @Sendable (HarnessEndpoint) async -> HarnessVersion?,
                            managedRuntime: ManagedRuntimeStatus = .unknown,
                            managedVersion: HarnessVersion? = nil,
                            latest: HarnessVersion? = nil) -> HarnessEnvironmentDoctor {
        HarnessEnvironmentDoctor(
            discovery: discovery,
            describe: describe,
            managedRuntimeStatus: { managedRuntime },
            managedVersion: { managedVersion },
            latestVersionProvider: { latest }
        )
    }

    // MARK: - 运行中 Harness

    /// 规格 §35：discovered unknown process → external；host.describe.version 接入统一 Version Model。
    func testRunningHarnessReportsExternalAndVersions() async {
        let doctor = makeDoctor(
            discovery: MockDiscovery(endpoint: endpoint),
            describe: { _ in HarnessVersion("0.1.0-rc.7") },
            latest: HarnessVersion("0.1.0-rc.8")
        )
        let report = await doctor.inspect()

        XCTAssertEqual(report.discoveredEndpoint, endpoint)
        XCTAssertEqual(report.ownership, .external)
        XCTAssertEqual(report.runningVersion, HarnessVersion("0.1.0-rc.7"))
        XCTAssertEqual(report.latestVersion, HarnessVersion("0.1.0-rc.8"))
        XCTAssertEqual(report.updateStatus, .updateAvailable(
            current: HarnessVersion("0.1.0-rc.7")!,
            latest: HarnessVersion("0.1.0-rc.8")!
        ))
    }

    /// describe 失败（host.describe 不可用）→ runningVersion unknown，但 ownership 仍为 external、不 crash。
    func testDescribeFailureKeepsExternalAndUnknownVersion() async {
        let doctor = makeDoctor(
            discovery: MockDiscovery(endpoint: endpoint),
            describe: { _ in nil },
            latest: HarnessVersion("0.1.0-rc.8")
        )
        let report = await doctor.inspect()

        XCTAssertEqual(report.discoveredEndpoint, endpoint)
        XCTAssertEqual(report.ownership, .external)
        XCTAssertNil(report.runningVersion)
        XCTAssertEqual(report.updateStatus, .unknown)
    }

    /// latest 查询失败（网络不可用）→ 不影响 Attach / 报告其余部分。
    func testLatestFailureDoesNotBreakReport() async {
        let doctor = makeDoctor(
            discovery: MockDiscovery(endpoint: endpoint),
            describe: { _ in HarnessVersion("0.1.0-rc.7") },
            latest: nil
        )
        let report = await doctor.inspect()

        XCTAssertEqual(report.discoveredEndpoint, endpoint)
        XCTAssertEqual(report.ownership, .external)
        XCTAssertEqual(report.runningVersion, HarnessVersion("0.1.0-rc.7"))
        XCTAssertNil(report.latestVersion)
        XCTAssertEqual(report.updateStatus, .unknown)
    }

    // MARK: - Harness 未运行

    func testNoHarnessKeepsManagedInfoForStartDecision() async {
        let doctor = makeDoctor(
            discovery: MockDiscovery(endpoint: nil),
            describe: { _ in nil },
            managedRuntime: .ready,
            managedVersion: HarnessVersion("0.1.0-rc.7"),
            latest: HarnessVersion("0.1.0-rc.8")
        )
        let report = await doctor.inspect()

        XCTAssertNil(report.discoveredEndpoint)
        XCTAssertNil(report.ownership)
        XCTAssertEqual(report.managedRuntime, .ready)
        XCTAssertEqual(report.managedVersion, HarnessVersion("0.1.0-rc.7"))
        // 未运行：更新状态以 managed 版本为基准
        XCTAssertEqual(report.updateStatus, .updateAvailable(
            current: HarnessVersion("0.1.0-rc.7")!,
            latest: HarnessVersion("0.1.0-rc.8")!
        ))
    }

    func testNoHarnessAndNoRuntime() async {
        let doctor = makeDoctor(
            discovery: MockDiscovery(endpoint: nil),
            describe: { _ in nil },
            managedRuntime: .missing,
            managedVersion: nil,
            latest: nil
        )
        let report = await doctor.inspect()

        XCTAssertNil(report.discoveredEndpoint)
        XCTAssertEqual(report.managedRuntime, .missing)
        XCTAssertNil(report.managedVersion)
        XCTAssertEqual(report.updateStatus, .unknown)
    }

    // MARK: - 检查顺序：已发现 Harness 时忽略 Managed 信息作为 current

    func testRunningHarnessUsesRunningVersionNotManagedVersion() async {
        let doctor = makeDoctor(
            discovery: MockDiscovery(endpoint: endpoint),
            describe: { _ in HarnessVersion("0.2.0") },
            managedRuntime: .ready,
            managedVersion: HarnessVersion("0.1.0-rc.7"),
            latest: HarnessVersion("0.1.0-rc.8")
        )
        let report = await doctor.inspect()

        // current = runningVersion（0.2.0）> latest（0.1.0-rc.8）→ aheadOfLatest
        XCTAssertEqual(report.runningVersion, HarnessVersion("0.2.0"))
        XCTAssertEqual(report.updateStatus, .aheadOfLatest(
            current: HarnessVersion("0.2.0")!,
            latest: HarnessVersion("0.1.0-rc.8")!
        ))
    }
}
