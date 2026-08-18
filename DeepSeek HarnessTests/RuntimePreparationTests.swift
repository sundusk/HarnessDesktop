import XCTest
@testable import DeepSeek_Harness

// MARK: - fake 执行器（单测不启动真实 Node / npm）

final class FakePreparationExecutor: RuntimePreparationExecuting, @unchecked Sendable {
    var nodeVersion = "v22.0.0"
    var nodeError: Error?
    var versionError: Error?
    var cacheError: Error?
    var fetchError: Error?
    var verifyError: Error?
    private(set) var fetchedVersions: [String] = []
    private(set) var verifiedVersions: [String] = []

    func validateNode() async throws -> String {
        if let nodeError { throw nodeError }
        return nodeVersion
    }

    func validateVersion(_ version: String) async throws {
        if let versionError { throw versionError }
    }

    func prepareCache() async throws {
        if let cacheError { throw cacheError }
    }

    func fetchPackage(version: String) async throws {
        fetchedVersions.append(version)
        if let fetchError { throw fetchError }
    }

    func verifyExecutable(version: String) async throws {
        verifiedVersions.append(version)
        if let verifyError { throw verifyError }
    }
}

/// Phase 10：App-owned Node Runtime 核心（文档 §7 / §14 / §32 / §34）。
final class RuntimePreparationTests: XCTestCase {

    // MARK: - ManagedRuntimePaths（根目录限制，文档 §32）

    private var root: ManagedRuntimePaths {
        ManagedRuntimePaths(rootURL: URL(fileURLWithPath: "/tmp/AppSupport/dev.deepseekharness.DeepSeekHarness", isDirectory: true))
    }

    func testPathsLayout() {
        let paths = root
        XCTAssertEqual(paths.runtimeDir.path, "/tmp/AppSupport/dev.deepseekharness.DeepSeekHarness/Runtime")
        XCTAssertEqual(paths.nodeDir.path, "/tmp/AppSupport/dev.deepseekharness.DeepSeekHarness/Runtime/node")
        XCTAssertEqual(paths.npmCacheDir.path, "/tmp/AppSupport/dev.deepseekharness.DeepSeekHarness/Runtime/npm-cache")
        XCTAssertEqual(paths.managedHarnessHome.path, "/tmp/AppSupport/dev.deepseekharness.DeepSeekHarness/ManagedHarnessHome")
        XCTAssertEqual(paths.stateFile.path, "/tmp/AppSupport/dev.deepseekharness.DeepSeekHarness/Runtime/state/managed-runtime.json")
    }

    func testIsInsideRoot() {
        let rootURL = URL(fileURLWithPath: "/tmp/AppSupport/dev.deepseekharness.DeepSeekHarness", isDirectory: true)
        XCTAssertTrue(ManagedRuntimePaths.isInsideRoot(
            URL(fileURLWithPath: "/tmp/AppSupport/dev.deepseekharness.DeepSeekHarness/Runtime/node"),
            root: rootURL
        ))
        XCTAssertFalse(ManagedRuntimePaths.isInsideRoot(
            URL(fileURLWithPath: "/tmp/AppSupport/other/thing"),
            root: rootURL
        ))
        XCTAssertFalse(ManagedRuntimePaths.isInsideRoot(
            URL(fileURLWithPath: "/usr/local/bin/node"),
            root: rootURL
        ))
    }

    /// 路径穿越拒绝（文档 §32：App-owned Runtime 必须限制在固定根目录）。
    func testChildRejectsTraversal() {
        let paths = root
        XCTAssertNil(paths.child(relativePath: "../escape", isDirectory: true))
        XCTAssertNil(paths.child(relativePath: "a/../../escape", isDirectory: true))
        XCTAssertNil(paths.child(relativePath: "/absolute", isDirectory: true))
        XCTAssertNil(paths.child(relativePath: "", isDirectory: true))
        let ok = paths.child(relativePath: "Runtime/packages/0.1.0-rc.7", isDirectory: true)
        XCTAssertEqual(ok?.path, "/tmp/AppSupport/dev.deepseekharness.DeepSeekHarness/Runtime/packages/0.1.0-rc.7")
    }

    // MARK: - ManagedPackageCache（文档 §7.2 / §15）

    func testCacheEnvironmentUsesPrivateCache() {
        let env = ManagedPackageCache.environment(for: root)
        XCTAssertEqual(env["npm_config_cache"], root.npmCacheDir.path)
        XCTAssertEqual(env["NO_UPDATE_NOTIFIER"], "1")
    }

    func testPackageDirVersionSafety() {
        XCTAssertEqual(
            ManagedPackageCache.packageDir(for: root, version: "0.1.0-rc.7")?.path,
            "/tmp/AppSupport/dev.deepseekharness.DeepSeekHarness/Runtime/packages/0.1.0-rc.7"
        )
        // 非法版本：路径穿越 / 超长 → nil
        XCTAssertNil(ManagedPackageCache.packageDir(for: root, version: "../evil"))
        XCTAssertNil(ManagedPackageCache.packageDir(for: root, version: "0.1.0/../../x"))
        XCTAssertNil(ManagedPackageCache.packageDir(for: root, version: String(repeating: "a", count: 65)))
        XCTAssertNil(ManagedPackageCache.packageDir(for: root, version: "0.1.0@rc"))
    }

    // MARK: - RuntimePreparation 状态机（文档 §14 固定顺序）

    func testPrepareSuccessOrderAndResult() async throws {
        let executor = FakePreparationExecutor()
        var phases: [RuntimePreparePhase] = []
        let preparation = RuntimePreparation(executor: executor, onPhase: { phases.append($0) })

        let result = try await preparation.prepare(version: "0.1.0-rc.7")

        XCTAssertEqual(result.nodeVersion, "v22.0.0")
        XCTAssertEqual(result.managedVersion, "0.1.0-rc.7")
        XCTAssertEqual(executor.fetchedVersions, ["0.1.0-rc.7"])
        XCTAssertEqual(executor.verifiedVersions, ["0.1.0-rc.7"])
        XCTAssertEqual(phases, [.validatingNode, .validatingVersion, .preparingCache, .fetchingPackage, .verifying])
    }

    func testPrepareFailsAtNodeValidation() async {
        let executor = FakePreparationExecutor()
        executor.nodeError = HarnessRuntimeFailure.runtimeMissing
        let preparation = RuntimePreparation(executor: executor)
        do {
            _ = try await preparation.prepare(version: "0.1.0-rc.7")
            XCTFail("应失败")
        } catch {
            XCTAssertEqual(error as? HarnessRuntimeFailure, .runtimeMissing)
        }
        XCTAssertTrue(executor.fetchedVersions.isEmpty, "Node 校验失败后不得继续拉取包")
    }

    func testPrepareFailsAtVersionValidation() async {
        let executor = FakePreparationExecutor()
        executor.versionError = HarnessRuntimeFailure.packagePreparationFailed
        let preparation = RuntimePreparation(executor: executor)
        do {
            _ = try await preparation.prepare(version: "../evil")
            XCTFail("应失败")
        } catch {
            XCTAssertEqual(error as? HarnessRuntimeFailure, .packagePreparationFailed)
        }
        XCTAssertTrue(executor.fetchedVersions.isEmpty)
    }

    func testPrepareFailsAtFetch() async {
        let executor = FakePreparationExecutor()
        executor.fetchError = HarnessRuntimeFailure.packagePreparationFailed
        let preparation = RuntimePreparation(executor: executor)
        do {
            _ = try await preparation.prepare(version: "0.1.0-rc.7")
            XCTFail("应失败")
        } catch {
            XCTAssertEqual(error as? HarnessRuntimeFailure, .packagePreparationFailed)
        }
        XCTAssertTrue(executor.verifiedVersions.isEmpty, "拉取失败后不得验证可执行性")
    }

    func testPrepareFailsAtVerify() async {
        let executor = FakePreparationExecutor()
        executor.verifyError = HarnessRuntimeFailure.packagePreparationFailed
        let preparation = RuntimePreparation(executor: executor)
        do {
            _ = try await preparation.prepare(version: "0.1.0-rc.7")
            XCTFail("应失败")
        } catch {
            XCTAssertEqual(error as? HarnessRuntimeFailure, .packagePreparationFailed)
        }
    }

    // MARK: - BundledNodeRuntimeLocator（分架构）

    func testCurrentArchIsArm64OrX64() {
        let arch = BundledNodeRuntimeLocator.currentArch
        XCTAssertTrue(arch == "arm64" || arch == "x64")
    }

    // MARK: - 版本字符串安全（文档 §32）

    func testSafeVersionComponent() {
        XCTAssertTrue(ManagedPackageCache.isSafeVersionComponent("0.1.0-rc.7"))
        XCTAssertTrue(ManagedPackageCache.isSafeVersionComponent("1.2.3"))
        XCTAssertFalse(ManagedPackageCache.isSafeVersionComponent(""))
        XCTAssertFalse(ManagedPackageCache.isSafeVersionComponent("0.1.0/.."))
        XCTAssertFalse(ManagedPackageCache.isSafeVersionComponent(String(repeating: "a", count: 65)))
        XCTAssertFalse(ManagedPackageCache.isSafeVersionComponent("0.1.0@evil"))
    }
}
