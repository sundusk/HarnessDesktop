import XCTest
@testable import DeepSeek_Harness

// MARK: - fake 执行器（单测不启动真实进程）

final class FakeUpdateExecutor: HarnessUpdateExecuting, @unchecked Sendable {
    var prepareError: Error?
    var stopError: Error?
    /// 按版本指定的启动错误（候选失败但恢复成功等场景）。
    var launchErrors: [String: Error] = [:]
    var verifyResult = true
    private(set) var prepared: [String] = []
    private(set) var stopped = false
    private(set) var launched: [String] = []
    private(set) var verified: [String] = []

    func prepareCandidate(version: String) async throws {
        prepared.append(version)
        if let prepareError { throw prepareError }
    }

    func stopCurrent() async throws {
        stopped = true
        if let stopError { throw stopError }
    }

    func launchCandidate(version: String) async throws -> ManagedHarnessIdentity {
        launched.append(version)
        if let error = launchErrors[version] { throw error }
        return .fixture
    }

    func verifyVersion(expected: String) async -> Bool {
        verified.append(expected)
        return verifyResult
    }
}

/// Phase 12：更新 / 回退事务（文档 §21 / §22 / §23 事务化语义）。
final class HarnessUpdateTransactionTests: XCTestCase {

    private func makeTransaction(_ executor: FakeUpdateExecutor) -> HarnessUpdateTransaction {
        HarnessUpdateTransaction(executor: executor)
    }

    // MARK: - Update 成功

    func testUpdateSuccessCommitsCandidate() async {
        let executor = FakeUpdateExecutor()
        var phases: [HarnessUpdatePhase] = []
        let transaction = HarnessUpdateTransaction(executor: executor, onPhase: { phases.append($0) })

        let result = await transaction.update(from: "0.1.0-rc.7", candidate: "0.1.0-rc.8")

        XCTAssertEqual(result, .committed(version: "0.1.0-rc.8"))
        XCTAssertEqual(executor.prepared, ["0.1.0-rc.8"])
        XCTAssertTrue(executor.stopped)
        XCTAssertEqual(executor.launched, ["0.1.0-rc.8"])
        XCTAssertEqual(executor.verified, ["0.1.0-rc.8"])
        XCTAssertEqual(phases, [.preparingCandidate, .stoppingCurrent, .launchingCandidate, .verifying, .committing])
    }

    // MARK: - 候选准备失败（当前版本不受影响，文档 §23）

    func testUpdateCandidatePrepareFailsLeavesCurrentUntouched() async {
        let executor = FakeUpdateExecutor()
        executor.prepareError = HarnessRuntimeFailure.packagePreparationFailed
        let transaction = makeTransaction(executor)

        let result = await transaction.update(from: "0.1.0-rc.7", candidate: "0.1.0-rc.8")

        XCTAssertEqual(result, .failed(.packagePreparationFailed))
        XCTAssertFalse(executor.stopped, "候选准备失败不得停止当前 Harness")
        XCTAssertTrue(executor.launched.isEmpty, "候选准备失败不得启动任何版本")
    }

    // MARK: - 停止失败

    func testUpdateStopFails() async {
        let executor = FakeUpdateExecutor()
        executor.stopError = HarnessRuntimeFailure.stopFailed
        let transaction = makeTransaction(executor)

        let result = await transaction.update(from: "0.1.0-rc.7", candidate: "0.1.0-rc.8")

        XCTAssertEqual(result, .failed(.stopFailed))
        XCTAssertTrue(executor.launched.isEmpty)
    }

    // MARK: - 候选启动失败 → 恢复 fallback（文档 §23）

    func testUpdateLaunchFailsRestoresCurrent() async {
        let executor = FakeUpdateExecutor()
        executor.launchErrors["0.1.0-rc.8"] = HarnessRuntimeFailure.startFailed
        let transaction = makeTransaction(executor)

        let result = await transaction.update(from: "0.1.0-rc.7", candidate: "0.1.0-rc.8")

        XCTAssertEqual(result, .restored(version: "0.1.0-rc.7"))
        XCTAssertEqual(executor.launched, ["0.1.0-rc.8", "0.1.0-rc.7"], "候选失败后应恢复原版本")
    }

    // MARK: - 版本校验失败 → 恢复 fallback（文档 §23 health-check-before-commit）

    func testUpdateVersionMismatchRestoresCurrent() async {
        let executor = FakeUpdateExecutor()
        executor.verifyResult = false
        let transaction = makeTransaction(executor)

        let result = await transaction.update(from: "0.1.0-rc.7", candidate: "0.1.0-rc.8")

        XCTAssertEqual(result, .restored(version: "0.1.0-rc.7"))
        XCTAssertEqual(executor.launched, ["0.1.0-rc.8", "0.1.0-rc.7"])
    }

    // MARK: - 恢复也失败 → 明确错误（不删除任何版本记录）

    func testUpdateRestoreFailsReturnsFailed() async {
        let executor = FakeUpdateExecutor()
        executor.launchErrors["0.1.0-rc.8"] = HarnessRuntimeFailure.startFailed
        executor.launchErrors["0.1.0-rc.7"] = HarnessRuntimeFailure.startFailed
        let transaction = makeTransaction(executor)

        let result = await transaction.update(from: "0.1.0-rc.7", candidate: "0.1.0-rc.8")

        XCTAssertEqual(result, .failed(.updateFailed))
    }

    // MARK: - Rollback（文档 §22）

    func testRollbackSuccess() async {
        let executor = FakeUpdateExecutor()
        let transaction = makeTransaction(executor)

        let result = await transaction.rollback(from: "0.1.0-rc.8", previous: "0.1.0-rc.7")

        XCTAssertEqual(result, .committed(version: "0.1.0-rc.7"))
        XCTAssertEqual(executor.launched, ["0.1.0-rc.7"])
        XCTAssertEqual(executor.verified, ["0.1.0-rc.7"])
    }

    func testRollbackLaunchFails() async {
        let executor = FakeUpdateExecutor()
        executor.launchErrors["0.1.0-rc.7"] = HarnessRuntimeFailure.startFailed
        let transaction = makeTransaction(executor)

        let result = await transaction.rollback(from: "0.1.0-rc.8", previous: "0.1.0-rc.7")

        XCTAssertEqual(result, .failed(.rollbackFailed))
    }

    // MARK: - verifyHarnessVersion（host.describe 版本校验；用不可达端口快速失败）

    func testVerifyHarnessVersionReturnsFalseWhenUnreachable() async {
        struct NoDiscovery: HarnessDiscovering {
            func discover() async -> HarnessEndpoint? { nil }
        }
        let ok = await AppCoordinator.verifyHarnessVersion(
            expected: "0.1.0-rc.8", discovery: NoDiscovery(), maxAttempts: 1
        )
        XCTAssertFalse(ok)
    }

    // MARK: - 设置持久化（文档 §13 / §21 / §22）

    func testPreviousManagedVersionPersists() {
        let suiteName = "HarnessUpdateTransactionTests-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(store: SettingsStore(defaults: UserDefaults(suiteName: suiteName)!))

        XCTAssertNil(settings.previousManagedVersion)
        settings.managedVersion = "0.1.0-rc.8"
        settings.previousManagedVersion = "0.1.0-rc.7"

        let reloaded = AppSettings(store: SettingsStore(defaults: UserDefaults(suiteName: suiteName)!))
        XCTAssertEqual(reloaded.managedVersion, "0.1.0-rc.8")
        XCTAssertEqual(reloaded.previousManagedVersion, "0.1.0-rc.7")
    }
}
