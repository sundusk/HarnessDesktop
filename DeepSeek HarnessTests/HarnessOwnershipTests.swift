import XCTest
@testable import DeepSeek_Harness

/// Phase 8：所有权模型（2.0 规格 §3 / §35 Ownership）。
final class HarnessOwnershipTests: XCTestCase {

    // MARK: - External 禁止破坏性操作（Never kill what you do not own）

    func testExternalCannotStop() {
        XCTAssertFalse(HarnessOwnership.external.canStop)
    }

    func testExternalCannotUpdate() {
        XCTAssertFalse(HarnessOwnership.external.canUpdate)
    }

    func testExternalCannotRollback() {
        XCTAssertFalse(HarnessOwnership.external.canRollback)
    }

    func testExternalCannotStart() {
        XCTAssertFalse(HarnessOwnership.external.canStart)
    }

    // MARK: - Managed 允许

    func testManagedAllowsAllOperations() {
        XCTAssertTrue(HarnessOwnership.managed.canStop)
        XCTAssertTrue(HarnessOwnership.managed.canUpdate)
        XCTAssertTrue(HarnessOwnership.managed.canRollback)
        XCTAssertTrue(HarnessOwnership.managed.canStart)
    }

    // MARK: - resolve

    func testDiscoveredUnknownProcessIsExternal() {
        // 规格 §35：discovered unknown process → external
        XCTAssertEqual(HarnessOwnership.resolve(generationMatchesManaged: false), .external)
    }

    func testHelperGenerationMatchIsManaged() {
        XCTAssertEqual(HarnessOwnership.resolve(generationMatchesManaged: true), .managed)
    }

    /// PID 相同但 generation 不匹配 → 不得视为 managed（防止 PID reuse 误杀）。
    func testPIDSameButGenerationMismatchIsExternal() {
        XCTAssertEqual(HarnessOwnership.resolve(generationMatchesManaged: false), .external)
    }

    // MARK: - 展示

    func testDisplayName() {
        XCTAssertEqual(HarnessOwnership.external.displayName, "外部")
        XCTAssertEqual(HarnessOwnership.managed.displayName, "HarnessDesktop")
    }
}
