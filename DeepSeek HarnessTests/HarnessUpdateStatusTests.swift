import XCTest
@testable import DeepSeek_Harness

/// Phase 8：更新状态计算（规格 §11 / §35 Version）。
final class HarnessUpdateStatusTests: XCTestCase {

    // MARK: - 基本状态

    func testUnknownWhenVersionMissing() {
        XCTAssertEqual(HarnessUpdateStatus.status(current: nil, latest: nil), .unknown)
        XCTAssertEqual(HarnessUpdateStatus.status(current: nil, latest: HarnessVersion("0.1.0")!), .unknown)
        XCTAssertEqual(HarnessUpdateStatus.status(current: HarnessVersion("0.1.0")!, latest: nil), .unknown)
    }

    func testUpToDateWhenEqual() {
        let current = HarnessVersion("0.1.0-rc.7")!
        XCTAssertEqual(
            HarnessUpdateStatus.status(current: current, latest: HarnessVersion("0.1.0-rc.7")!),
            .upToDate(current: current)
        )
    }

    func testUpdateAvailableWhenCurrentBelowLatest() {
        let current = HarnessVersion("0.1.0-rc.7")!
        let latest = HarnessVersion("0.1.0-rc.8")!
        XCTAssertEqual(
            HarnessUpdateStatus.status(current: current, latest: latest),
            .updateAvailable(current: current, latest: latest)
        )
    }

    func testAheadOfLatestWhenCurrentAboveLatest() {
        let current = HarnessVersion("0.1.0-rc.9")!
        let latest = HarnessVersion("0.1.0-rc.8")!
        XCTAssertEqual(
            HarnessUpdateStatus.status(current: current, latest: latest),
            .aheadOfLatest(current: current, latest: latest)
        )
    }

    // MARK: - prerelease 正确参与比较（0.1.0-rc.7 < 0.1.0-rc.8）

    func testPrereleaseUpdateDetection() {
        let current = HarnessVersion("0.1.0-rc.7")!
        let latest = HarnessVersion("0.1.0-rc.8")!
        XCTAssertEqual(
            HarnessUpdateStatus.status(current: current, latest: latest),
            .updateAvailable(current: current, latest: latest)
        )
    }

    func testSameCoreDifferentPrerelease() {
        // 1.0.0-rc.1 < 1.0.0 → updateAvailable
        let current = HarnessVersion("1.0.0-rc.1")!
        let latest = HarnessVersion("1.0.0")!
        XCTAssertEqual(
            HarnessUpdateStatus.status(current: current, latest: latest),
            .updateAvailable(current: current, latest: latest)
        )
    }

    func testBuildMetadataIgnoredForStatus() {
        let current = HarnessVersion("1.0.0")!
        let latest = HarnessVersion("1.0.0+build5")!
        XCTAssertEqual(
            HarnessUpdateStatus.status(current: current, latest: latest),
            .upToDate(current: current)
        )
    }

    // MARK: - 辅助

    func testHasUpdateOnlyWhenUpdateAvailable() {
        XCTAssertTrue(HarnessUpdateStatus.updateAvailable(current: HarnessVersion("0.1.0")!, latest: HarnessVersion("0.2.0")!).hasUpdate)
        XCTAssertFalse(HarnessUpdateStatus.upToDate(current: HarnessVersion("0.1.0")!).hasUpdate)
        XCTAssertFalse(HarnessUpdateStatus.aheadOfLatest(current: HarnessVersion("0.2.0")!, latest: HarnessVersion("0.1.0")!).hasUpdate)
        XCTAssertFalse(HarnessUpdateStatus.unknown.hasUpdate)
        XCTAssertFalse(HarnessUpdateStatus.checking.hasUpdate)
        XCTAssertFalse(HarnessUpdateStatus.failed.hasUpdate)
    }

    func testSummaryText() {
        XCTAssertNil(HarnessUpdateStatus.unknown.summary)
        XCTAssertNil(HarnessUpdateStatus.checking.summary)
        XCTAssertNil(HarnessUpdateStatus.failed.summary)
        XCTAssertEqual(
            HarnessUpdateStatus.updateAvailable(current: HarnessVersion("0.1.0-rc.7")!, latest: HarnessVersion("0.1.0-rc.8")!).summary,
            "有更新可用：0.1.0-rc.7 → 0.1.0-rc.8"
        )
        XCTAssertEqual(
            HarnessUpdateStatus.upToDate(current: HarnessVersion("0.1.0-rc.8")!).summary,
            "已是最新：0.1.0-rc.8"
        )
    }
}
