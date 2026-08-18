import XCTest
@testable import DeepSeek_Harness

/// fake transport：单测不触碰真实 XPC（规格 §34：单测禁止真正启动 Node / npm / Harness）。
final class FakeRuntimeHelperTransport: RuntimeHelperTransporting, @unchecked Sendable {
    var inspection: RuntimeInspection = .missing
    var inspectionError: Error?
    var prepareResult: Result<RuntimePreparationResult, Error> = .failure(HarnessRuntimeFailure.packagePreparationFailed)
    var startResult: Result<ManagedHarnessIdentity, Error> = .failure(HarnessRuntimeFailure.startFailed)
    var stopError: Error?
    var statusResult: Result<ManagedHarnessProcessStatus, Error> = .success(.stopped)
    private(set) var stoppedIdentities: [ManagedHarnessIdentity] = []
    private(set) var statusedIdentities: [ManagedHarnessIdentity] = []
    private(set) var preparedVersions: [String] = []

    func inspectRuntime() async throws -> RuntimeInspection {
        if let inspectionError { throw inspectionError }
        return inspection
    }

    func prepareRuntime(version: String) async throws -> RuntimePreparationResult {
        preparedVersions.append(version)
        return try prepareResult.get()
    }

    func startHarness(version: String, port: Int, dataMode: ManagedDataMode) async throws -> ManagedHarnessIdentity {
        try startResult.get()
    }

    func stopHarness(identity: ManagedHarnessIdentity) async throws {
        stoppedIdentities.append(identity)
        if let stopError { throw stopError }
    }

    func status(identity: ManagedHarnessIdentity) async throws -> ManagedHarnessProcessStatus {
        statusedIdentities.append(identity)
        return try statusResult.get()
    }

    func healthCheck() async -> Bool {
        // 与真实 XPC 传输语义一致：能完成 inspect 即健康。
        (try? await inspectRuntime()) != nil
    }
}

/// Phase 9：Runtime Manager 客户端（规格 §6 / §34 / §42）。
final class RuntimeManagerClientTests: XCTestCase {

    private func makeClient(_ transport: FakeRuntimeHelperTransport) -> RuntimeManagerClient {
        RuntimeManagerClient(transport: transport)
    }

    // MARK: - inspectRuntime

    func testInspectRuntimeReturnsInspection() async throws {
        let transport = FakeRuntimeHelperTransport()
        transport.inspection = RuntimeInspection(nodeVersion: "v22.0.0", runtimeReady: true, managedHomeReady: true)
        let client = makeClient(transport)

        let inspection = try await client.inspectRuntime()
        XCTAssertEqual(inspection.nodeVersion, "v22.0.0")
        XCTAssertTrue(inspection.runtimeReady)
        XCTAssertTrue(inspection.managedHomeReady)
    }

    func testInspectRuntimePropagatesError() async {
        let transport = FakeRuntimeHelperTransport()
        transport.inspectionError = HarnessRuntimeFailure.helperUnavailable
        let client = makeClient(transport)

        do {
            _ = try await client.inspectRuntime()
            XCTFail("应抛出 helperUnavailable")
        } catch {
            XCTAssertEqual(error as? HarnessRuntimeFailure, .helperUnavailable)
        }
    }

    // MARK: - stop / status：身份透传与所有权验证（文档 §17）

    func testStopPassesIdentityUntouched() async throws {
        let transport = FakeRuntimeHelperTransport()
        let client = makeClient(transport)
        let identity = ManagedHarnessIdentity(
            generationID: UUID(),
            pid: 4242,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            version: "0.1.0-rc.7",
            port: 3080
        )

        try await client.stopHarness(identity: identity)
        XCTAssertEqual(transport.stoppedIdentities, [identity], "身份必须原样透传，供 Helper 验证 generation ownership")
    }

    func testStopPropagatesError() async {
        let transport = FakeRuntimeHelperTransport()
        transport.stopError = HarnessRuntimeFailure.stopFailed
        let client = makeClient(transport)

        do {
            try await client.stopHarness(identity: .fixture)
            XCTFail("应抛出 stopFailed")
        } catch {
            XCTAssertEqual(error as? HarnessRuntimeFailure, .stopFailed)
        }
    }

    func testStatusMapsResult() async throws {
        let transport = FakeRuntimeHelperTransport()
        transport.statusResult = .success(.running(pid: 4242))
        let client = makeClient(transport)

        let status = try await client.status(identity: .fixture)
        XCTAssertEqual(status, .running(pid: 4242))
        XCTAssertEqual(transport.statusedIdentities, [.fixture])
    }

    func testStatusPropagatesError() async {
        let transport = FakeRuntimeHelperTransport()
        transport.statusResult = .failure(HarnessRuntimeFailure.helperUnavailable)
        let client = makeClient(transport)

        do {
            _ = try await client.status(identity: .fixture)
            XCTFail("应抛出 helperUnavailable")
        } catch {
            XCTAssertEqual(error as? HarnessRuntimeFailure, .helperUnavailable)
        }
    }

    // MARK: - health check

    func testHealthCheckTrueWhenInspectionSucceeds() async {
        let transport = FakeRuntimeHelperTransport()
        transport.inspection = RuntimeInspection(nodeVersion: "v22", runtimeReady: true, managedHomeReady: true)
        let client = makeClient(transport)
        let healthy = await client.healthCheck()
        XCTAssertTrue(healthy)
    }

    func testHealthCheckFalseWhenInspectionFails() async {
        let transport = FakeRuntimeHelperTransport()
        transport.inspectionError = HarnessRuntimeFailure.helperUnavailable
        let client = makeClient(transport)
        let healthy = await client.healthCheck()
        XCTAssertFalse(healthy)
    }

    // MARK: - Phase 10：prepareRuntime

    func testPrepareRuntimePassesVersionAndReturnsResult() async throws {
        let transport = FakeRuntimeHelperTransport()
        transport.prepareResult = .success(RuntimePreparationResult(nodeVersion: "v22.0.0", managedVersion: "0.1.0-rc.7"))
        let client = makeClient(transport)

        let result = try await client.prepareRuntime(version: "0.1.0-rc.7")
        XCTAssertEqual(transport.preparedVersions, ["0.1.0-rc.7"], "exact version 必须透传给 Helper")
        XCTAssertEqual(result.nodeVersion, "v22.0.0")
        XCTAssertEqual(result.managedVersion, "0.1.0-rc.7")
    }

    func testPrepareRuntimePropagatesError() async {
        let transport = FakeRuntimeHelperTransport()
        transport.prepareResult = .failure(HarnessRuntimeFailure.packagePreparationFailed)
        let client = makeClient(transport)

        do {
            _ = try await client.prepareRuntime(version: "0.1.0-rc.7")
            XCTFail("应抛出 packagePreparationFailed")
        } catch {
            XCTAssertEqual(error as? HarnessRuntimeFailure, .packagePreparationFailed)
        }
    }

    // MARK: - Phase 9 骨架：未实现的能力返回明确错误（不静默成功）

    func testStartHarnessThrowsStartFailedInSkeleton() async {
        let client = makeClient(FakeRuntimeHelperTransport())
        do {
            _ = try await client.startHarness(version: "0.1.0-rc.7", port: 3080, dataMode: .isolated)
            XCTFail("Phase 9 骨架应返回 startFailed")
        } catch {
            XCTAssertEqual(error as? HarnessRuntimeFailure, .startFailed)
        }
    }
}

extension ManagedHarnessIdentity {
    /// 测试夹具。
    static let fixture = ManagedHarnessIdentity(
        generationID: UUID(uuidString: "12345678-1234-1234-1234-123456789012")!,
        pid: 1000,
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        version: "0.1.0-rc.7",
        port: 3080
    )
}
