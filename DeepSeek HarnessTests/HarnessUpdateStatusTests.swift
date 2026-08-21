import XCTest
@testable import DeepSeek_Harness

final class HarnessUpdateStatusTests: XCTestCase {
    private let rc7 = HarnessVersion("0.1.0-rc.7")!
    private let rc8 = HarnessVersion("0.1.0-rc.8")!
    private let rc9 = HarnessVersion("0.1.0-rc.9")!

    func testStatusMatrixUsesRunningVersionForFreshnessAndNPMForInstallability() {
        XCTAssertEqual(
            HarnessUpdateStatus.status(runningVersion: rc7, latestRelease: rc7, latestInstallable: rc7),
            .upToDate(current: rc7)
        )
        XCTAssertEqual(
            HarnessUpdateStatus.status(runningVersion: rc7, latestRelease: rc8, latestInstallable: rc8),
            .updateAvailable(current: rc7, latestRelease: rc8, latestInstallable: rc8)
        )
        XCTAssertEqual(
            HarnessUpdateStatus.status(runningVersion: rc7, latestRelease: rc8, latestInstallable: rc7),
            .releaseAvailableButNotInstallable(current: rc7, latestRelease: rc8, latestInstallable: rc7)
        )
        XCTAssertEqual(
            HarnessUpdateStatus.status(runningVersion: rc8, latestRelease: rc8, latestInstallable: rc7),
            .runningLatestButNpmBehind(running: rc8, latestRelease: rc8, latestInstallable: rc7)
        )
        XCTAssertEqual(
            HarnessUpdateStatus.status(runningVersion: rc9, latestRelease: rc8, latestInstallable: rc8),
            .aheadOfLatest(current: rc9, latestRelease: rc8)
        )
        XCTAssertEqual(
            HarnessUpdateStatus.status(runningVersion: nil, latestRelease: rc8, latestInstallable: rc8),
            .unknown
        )
    }

    func testMissingGitHubCannotClaimUpToDateEvenWhenNPMIsKnown() {
        XCTAssertEqual(
            HarnessUpdateStatus.status(runningVersion: rc7, latestRelease: nil, latestInstallable: rc7),
            .unknown
        )
    }

    func testKnownReleaseWithUnknownNPMCannotClaimInstallable() {
        XCTAssertEqual(
            HarnessUpdateStatus.status(runningVersion: rc7, latestRelease: rc8, latestInstallable: nil),
            .releaseAvailableButNotInstallable(current: rc7, latestRelease: rc8, latestInstallable: nil)
        )
    }

    func testBuildMetadataIsIgnoredForReleaseFreshness() {
        let current = HarnessVersion("1.0.0")!
        let release = HarnessVersion("1.0.0+build5")!
        XCTAssertEqual(
            HarnessUpdateStatus.status(runningVersion: current, latestRelease: release, latestInstallable: nil),
            .upToDate(current: current)
        )
    }

    func testHasUpdateMeansManagedUpdateIsActuallyInstallable() {
        XCTAssertTrue(HarnessUpdateStatus.updateAvailable(current: rc7, latestRelease: rc8, latestInstallable: rc8).hasUpdate)
        XCTAssertFalse(HarnessUpdateStatus.releaseAvailableButNotInstallable(current: rc7, latestRelease: rc8, latestInstallable: rc7).hasUpdate)
        XCTAssertFalse(HarnessUpdateStatus.upToDate(current: rc8).hasUpdate)
        XCTAssertFalse(HarnessUpdateStatus.runningLatestButNpmBehind(running: rc8, latestRelease: rc8, latestInstallable: rc7).hasUpdate)
        XCTAssertFalse(HarnessUpdateStatus.aheadOfLatest(current: rc9, latestRelease: rc8).hasUpdate)
    }

    func testSummaryDistinguishesInstallableAndPendingNPMRelease() {
        XCTAssertEqual(
            HarnessUpdateStatus.updateAvailable(current: rc7, latestRelease: rc8, latestInstallable: rc8).summary,
            "有更新可用：0.1.0-rc.7 → 0.1.0-rc.8"
        )
        XCTAssertEqual(
            HarnessUpdateStatus.releaseAvailableButNotInstallable(current: rc7, latestRelease: rc8, latestInstallable: rc7).summary,
            "新版本 0.1.0-rc.8 已发布，npm 尚未同步"
        )
    }

    func testDescribePlaceholderIsMarkedUnknown() {
        var report = HarnessEnvironmentReport()
        report.setRunningVersion(from: HarnessVersion("0.0.1"))
        report.latestReleaseVersion = rc9
        report.latestInstallableVersion = rc7

        XCTAssertNil(report.runningVersion)
        XCTAssertEqual(report.runningVersionWarning, "Harness 返回了占位版本 0.0.1，无法确定真实运行版本")
        XCTAssertEqual(report.updateStatus, .unknown)
    }

    func testRunningVersionNeverFallsBackToInstallableOrManagedVersion() {
        var report = HarnessEnvironmentReport()
        report.managedVersion = rc7
        report.latestReleaseVersion = rc8
        report.latestInstallableVersion = rc8
        report.refreshUpdateStatus()

        XCTAssertNil(report.runningVersion)
        XCTAssertEqual(report.updateStatus, .unknown)
    }
}
