import XCTest
@testable import DeepSeek_Harness

// MARK: - Fakes（单测不启动真实 Node / Harness）

/// fake 进程句柄：可记录信号，可控制运行状态。
final class FakeManagedProcessHandle: ManagedProcessHandle, @unchecked Sendable {
    let pid: Int32
    var running = true
    var exitOnInterrupt = false
    var exitOnTerminate = false
    private(set) var interruptCount = 0
    private(set) var terminateCount = 0
    private(set) var killCount = 0

    init(pid: Int32 = 4242) {
        self.pid = pid
    }

    func waitExit() async -> ManagedProcessResult {
        while running {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return ManagedProcessResult(exitCode: 0, stdout: "", stderr: "")
    }

    func interrupt() {
        interruptCount += 1
        if exitOnInterrupt { running = false }
    }

    func terminate() {
        terminateCount += 1
        if exitOnTerminate { running = false }
    }

    func kill() {
        killCount += 1
        running = false
    }

    func isRunning() -> Bool { running }
}

/// fake launcher：记录启动参数，返回可控句柄。
final class FakeProcessLauncher: ManagedProcessRunning, @unchecked Sendable {
    var handle: FakeManagedProcessHandle
    var launchError: Error?
    var runResult = ManagedProcessResult(exitCode: 0, stdout: "v22.0.0", stderr: "")
    private(set) var launchCalls: [(executable: URL, args: [String], env: [String: String])] = []

    init(handle: FakeManagedProcessHandle = FakeManagedProcessHandle()) {
        self.handle = handle
    }

    func run(executable: URL, arguments: [String],
             environment: [String: String], currentDirectory: URL?) async throws -> ManagedProcessResult {
        runResult
    }

    func launch(executable: URL, arguments: [String],
                environment: [String: String], currentDirectory: URL?) async throws -> any ManagedProcessHandle {
        launchCalls.append((executable, arguments, environment))
        if let launchError { throw launchError }
        return handle
    }
}

/// Phase 11：Managed Process Supervisor（文档 §11 / §16 / §17 / §18 / §32）。
final class ManagedProcessSupervisorTests: XCTestCase {

    private let nodePath = URL(fileURLWithPath: "/tmp/fake-node/bin/node")
    private let paths = ManagedRuntimePaths(rootURL: URL(fileURLWithPath: "/tmp/appsupport/dev.deepseekharness.DeepSeekHarness", isDirectory: true))

    private func makeSupervisor(launcher: FakeProcessLauncher = FakeProcessLauncher(),
                                portOccupied: Bool = false,
                                grace: ManagedProcessSupervisor.StopGrace = .init(intWait: 1, termWait: 1),
                                nodeAvailable: Bool = true) -> ManagedProcessSupervisor {
        let supervisor = ManagedProcessSupervisor(
            launcher: launcher,
            paths: paths,
            isPortOccupied: { _ in portOccupied }
        )
        supervisor.nodeLocator = { nodeAvailable ? self.nodePath : nil }
        supervisor.packageBinExists = { _ in true }
        supervisor.graceSeconds = grace
        supervisor.generationID = { UUID(uuidString: "12345678-1234-1234-1234-123456789012")! }
        return supervisor
    }

    // MARK: - Start

    func testStartSpawnsExactVersionWithIsolatedEnv() async throws {
        let launcher = FakeProcessLauncher()
        let supervisor = makeSupervisor(launcher: launcher)

        let identity = try await supervisor.start(version: "0.1.0-rc.7", port: 3080)

        XCTAssertEqual(identity.generationID, UUID(uuidString: "12345678-1234-1234-1234-123456789012"))
        XCTAssertEqual(identity.pid, 4242)
        XCTAssertEqual(identity.version, "0.1.0-rc.7")
        XCTAssertEqual(identity.port, 3080)

        XCTAssertEqual(launcher.launchCalls.count, 1)
        let call = launcher.launchCalls[0]
        XCTAssertEqual(call.executable, nodePath)
        // exact version bin + web 子命令 + --port
        XCTAssertTrue(call.args.contains("web"))
        XCTAssertTrue(call.args.contains("--port"))
        XCTAssertTrue(call.args.contains("3080"))
        XCTAssertTrue(call.args[0].contains("packages/0.1.0-rc.7/node_modules/@deepseek-ai/dsh/lib/bin.js"))
        // 隔离环境：DSH_HOME + 私有 npm cache
        XCTAssertEqual(call.env["DSH_HOME"], paths.managedHarnessHome.path)
        XCTAssertEqual(call.env["npm_config_cache"], paths.npmCacheDir.path)
    }

    func testStartRejectsWhenPortOccupied() async {
        let launcher = FakeProcessLauncher()
        let supervisor = makeSupervisor(launcher: launcher, portOccupied: true)
        do {
            _ = try await supervisor.start(version: "0.1.0-rc.7", port: 3080)
            XCTFail("端口被占用时应拒绝启动")
        } catch {
            XCTAssertEqual(error as? ManagedRuntimeError, .endpointOccupied)
        }
        XCTAssertTrue(launcher.launchCalls.isEmpty, "端口占用时不得启动进程")
    }

    func testStartRejectsUnsafeVersionOrPort() async {
        let supervisor = makeSupervisor()
        do {
            _ = try await supervisor.start(version: "../evil", port: 3080)
            XCTFail("非法版本应拒绝")
        } catch {
            XCTAssertEqual(error as? ManagedRuntimeError, .packagePreparationFailed)
        }
        do {
            _ = try await supervisor.start(version: "0.1.0", port: 0)
            XCTFail("非法端口应拒绝")
        } catch {
            XCTAssertEqual(error as? ManagedRuntimeError, .packagePreparationFailed)
        }
    }

    func testStartWhenAlreadyRunningFails() async throws {
        let supervisor = makeSupervisor()
        _ = try await supervisor.start(version: "0.1.0-rc.7", port: 3080)
        do {
            _ = try await supervisor.start(version: "0.1.0-rc.7", port: 3080)
            XCTFail("重复启动应失败")
        } catch {
            XCTAssertEqual(error as? ManagedRuntimeError, .startFailed)
        }
    }

    func testStartWithoutNodeFailsRuntimeMissing() async {
        let supervisor = makeSupervisor(nodeAvailable: false)
        do {
            _ = try await supervisor.start(version: "0.1.0-rc.7", port: 3080)
            XCTFail("无 Node 应失败")
        } catch {
            XCTAssertEqual(error as? ManagedRuntimeError, .runtimeMissing)
        }
    }

    // MARK: - Stop（文档 §18：SIGINT → SIGTERM → 仅 owned 才兜底）

    func testStopWrongIdentityRejected() async throws {
        let launcher = FakeProcessLauncher()
        let supervisor = makeSupervisor(launcher: launcher)
        let identity = try await supervisor.start(version: "0.1.0-rc.7", port: 3080)

        // PID 相同但 generation 不匹配（PID reuse 场景）→ 拒绝停止
        let forged = ManagedHarnessIdentity(
            generationID: UUID(), pid: identity.pid,
            startedAt: identity.startedAt, version: identity.version, port: identity.port
        )
        do {
            try await supervisor.stop(identity: forged)
            XCTFail("身份不匹配应拒绝停止")
        } catch {
            XCTAssertEqual(error as? ManagedRuntimeError, .stopFailed)
        }
        XCTAssertEqual(launcher.handle.interruptCount, 0, "身份不匹配时不得发信号")
    }

    func testStopGracefulInterruptOnly() async throws {
        let launcher = FakeProcessLauncher()
        launcher.handle.exitOnInterrupt = true
        let supervisor = makeSupervisor(launcher: launcher)
        let identity = try await supervisor.start(version: "0.1.0-rc.7", port: 3080)

        try await supervisor.stop(identity: identity)

        XCTAssertEqual(launcher.handle.interruptCount, 1, "SIGINT 应被发送")
        XCTAssertEqual(launcher.handle.terminateCount, 0, "SIGINT 生效则不应升级到 SIGTERM")
        XCTAssertEqual(launcher.handle.killCount, 0)
        XCTAssertEqual(supervisor.status(identity: identity), .stopped)
    }

    func testStopEscalatesToTerminateAndKill() async throws {
        let launcher = FakeProcessLauncher()
        // 句柄忽略所有信号 → 必须逐级升级到 SIGKILL
        let supervisor = makeSupervisor(launcher: launcher, grace: .init(intWait: 0, termWait: 0))
        let identity = try await supervisor.start(version: "0.1.0-rc.7", port: 3080)

        try await supervisor.stop(identity: identity)

        XCTAssertGreaterThanOrEqual(launcher.handle.interruptCount, 1)
        XCTAssertGreaterThanOrEqual(launcher.handle.terminateCount, 1)
        XCTAssertEqual(launcher.handle.killCount, 1, "最终应 SIGKILL")
        XCTAssertEqual(supervisor.status(identity: identity), .stopped)
    }

    // MARK: - Status

    func testStatusRunningAfterStart() async throws {
        let supervisor = makeSupervisor()
        let identity = try await supervisor.start(version: "0.1.0-rc.7", port: 3080)
        XCTAssertEqual(supervisor.status(identity: identity), .running(pid: identity.pid))
    }

    func testStatusStoppedForUnknownIdentity() async throws {
        let supervisor = makeSupervisor()
        let identity = try await supervisor.start(version: "0.1.0-rc.7", port: 3080)
        let forged = ManagedHarnessIdentity(
            generationID: UUID(), pid: identity.pid,
            startedAt: identity.startedAt, version: identity.version, port: identity.port
        )
        XCTAssertEqual(supervisor.status(identity: forged), .stopped, "身份不匹配 → 视为未运行")
    }

    // MARK: - stopActive（崩溃恢复 / 连接失效清理，文档 §19 / §47）

    func testStopActiveStopsRegisteredProcess() async throws {
        let launcher = FakeProcessLauncher()
        launcher.handle.exitOnInterrupt = true
        let supervisor = makeSupervisor(launcher: launcher)
        let identity = try await supervisor.start(version: "0.1.0-rc.7", port: 3080)

        await supervisor.stopActive()

        XCTAssertEqual(launcher.handle.interruptCount, 1)
        XCTAssertNil(supervisor.registration, "stopActive 后应清空活跃注册")
        XCTAssertEqual(supervisor.status(identity: identity), .stopped)
    }

    func testStopActiveNoopWhenNothingRunning() async {
        let supervisor = makeSupervisor()
        await supervisor.stopActive()  // 不应崩溃 / 不应报错
        XCTAssertNil(supervisor.registration)
    }

    // MARK: - 意外退出（文档 §18：unexpected exit handling）

    func testUnexpectedExitClearsRegistration() async throws {
        let launcher = FakeProcessLauncher()
        let supervisor = makeSupervisor(launcher: launcher)
        _ = try await supervisor.start(version: "0.1.0-rc.7", port: 3080)
        XCTAssertNotNil(supervisor.registration)

        // 进程意外退出
        launcher.handle.running = false
        // 等待后台监视任务清理注册
        let deadline = Date().addingTimeInterval(2)
        while supervisor.registration != nil && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNil(supervisor.registration, "意外退出后应清理活跃注册")
    }
}
