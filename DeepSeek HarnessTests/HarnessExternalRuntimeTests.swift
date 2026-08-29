import XCTest
@testable import DeepSeek_Harness

private struct RuntimeTestCommandRunner: HarnessCommandRunning {
    let latest: String
    let installedJSON: String

    func run(executableName: String, arguments: [String], currentDirectory: URL?) async throws -> ManagedProcessResult {
        if arguments.first == "view" {
            return ManagedProcessResult(exitCode: 0, stdout: latest, stderr: "")
        }
        return ManagedProcessResult(exitCode: 0, stdout: installedJSON, stderr: "")
    }
}

private final class RuntimeTestConfigurationStore: HarnessRuntimeConfigurationStoring, @unchecked Sendable {
    var value = HarnessRuntimeConfiguration()

    func load() throws -> HarnessRuntimeConfiguration { value }
    func save(_ configuration: HarnessRuntimeConfiguration) throws { value = configuration }
}

private struct RuntimeTestDiscovery: HarnessDiscovering {
    let result: HarnessEndpoint?

    func discover() async -> HarnessEndpoint? { result }
}

private final class RuntimeTestProcessHandle: HarnessRuntimeProcessHandle, @unchecked Sendable {
    let pid: Int32
    private(set) var running = true

    init(pid: Int32 = 4242) { self.pid = pid }
    func authenticatedURL() -> URL? { nil }
    func interrupt() { running = false }
    func terminate() { running = false }
    func kill() { running = false }
    func isRunning() -> Bool { running }
}

private final class RuntimeTestProcessLauncher: HarnessRuntimeProcessLaunching, @unchecked Sendable {
    let handle = RuntimeTestProcessHandle()
    private(set) var mode: HarnessRuntimeMode?
    private(set) var sourcePath: URL?
    private(set) var port: Int?
    private(set) var logURL: URL?

    func launch(mode: HarnessRuntimeMode, sourcePath: URL?, port: Int, logURL: URL) throws -> any HarnessRuntimeProcessHandle {
        self.mode = mode
        self.sourcePath = sourcePath
        self.port = port
        self.logURL = logURL
        return handle
    }
}

final class HarnessExternalRuntimeTests: XCTestCase {
    func testMainAppEntitlementsAllowUserInstalledToolchains() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let entitlementsURL = repositoryRoot
            .appendingPathComponent("DeepSeek Harness/Resources/DeepSeek Harness.entitlements")
        let data = try Data(contentsOf: entitlementsURL)
        let entitlements = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        XCTAssertNil(
            entitlements["com.apple.security.app-sandbox"],
            "主 App 启用 Sandbox 会阻止 npm/source 模式访问并启动用户安装的工具链"
        )
    }

    func testExecutableLocatorChecksAdditionalDirectoriesWhenGUIPathIsShort() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("npx")
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        defer { try? FileManager.default.removeItem(at: directory) }

        let resolved = HarnessExecutableLocator.url(
            for: "npx",
            environment: ["PATH": "/usr/bin:/bin"],
            additionalSearchDirectories: [directory.path]
        )

        XCTAssertEqual(resolved?.standardizedFileURL, executable.standardizedFileURL)
    }

    func testExecutableLocatorFindsUserGlobalPnpmWhenGUIPathIsShort() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("pnpm")
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        defer { try? FileManager.default.removeItem(at: directory) }

        let resolved = HarnessExecutableLocator.url(
            for: "pnpm",
            environment: ["PATH": "/usr/bin:/bin", "HOME": "/Users/test"],
            additionalSearchDirectories: [directory.path]
        )

        XCTAssertEqual(resolved?.standardizedFileURL, executable.standardizedFileURL)
    }

    func testExecutableEnvironmentPrependsResolvedBinDirectoryToGUIPath() {
        let executable = URL(fileURLWithPath: "/opt/homebrew/bin/npx")

        let environment = HarnessExecutableLocator.environment(
            for: executable,
            base: ["PATH": "/usr/bin:/bin", "HOME": "/Users/test"]
        )

        XCTAssertEqual(environment["PATH"], "/opt/homebrew/bin:/usr/bin:/bin")
        XCTAssertEqual(environment["HOME"], "/Users/test")
    }

    func testExecutableEnvironmentAddsNodeDirectoryForUserInstalledPnpm() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let pnpmDirectory = root.appendingPathComponent("pnpm-bin")
        let nodeDirectory = root.appendingPathComponent("node-bin")
        try FileManager.default.createDirectory(at: pnpmDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nodeDirectory, withIntermediateDirectories: true)
        let pnpm = pnpmDirectory.appendingPathComponent("pnpm")
        let node = nodeDirectory.appendingPathComponent("node")
        for executable in [pnpm, node] {
            try Data("#!/bin/sh\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let environment = HarnessExecutableLocator.environment(
            for: pnpm,
            base: ["PATH": "/usr/bin:/bin", "HOME": "/Users/test"],
            additionalSearchDirectories: [pnpmDirectory.path, nodeDirectory.path]
        )

        XCTAssertEqual(
            environment["PATH"],
            "\(pnpmDirectory.path):\(nodeDirectory.path):/usr/bin:/bin"
        )
    }

    func testExternalRuntimeStatusIsRunningOnlyForRunningProcess() {
        let record = HarnessRuntimeProcessRecord(
            pid: 4242,
            mode: .source,
            startedAt: Date(timeIntervalSince1970: 0),
            logPath: "/tmp/harness.log"
        )

        XCTAssertTrue(HarnessExternalRuntimeStatus.running(record).isRunning)
        XCTAssertFalse(HarnessExternalRuntimeStatus.stopped.isRunning)
        XCTAssertFalse(HarnessExternalRuntimeStatus.starting(.npm).isRunning)
        XCTAssertFalse(HarnessExternalRuntimeStatus.failed("error").isRunning)
    }

    func testConfigurationStoreRoundTripsISO8601JSON() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("config.json")
        let store = JSONHarnessRuntimeConfigurationStore(fileURL: url)
        let expected = HarnessRuntimeConfiguration(
            runtimeMode: .source,
            sourcePath: "/tmp/deepseek-harness",
            port: 3080,
            autoStart: true
        )

        try store.save(expected)
        XCTAssertEqual(try store.load(), expected)
        try? FileManager.default.removeItem(at: directory)
    }

    func testSelectSourceDirectoryPersistsDirectoryAndAcceptsPackageJSON() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("deepseek-harness")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(#"{"name":"deepseek-harness","version":"0.1.0-rc.8"}"#.utf8)
            .write(to: source.appendingPathComponent("package.json"))

        let store = RuntimeTestConfigurationStore()
        let manager = HarnessRuntimeManager(
            discovery: RuntimeTestDiscovery(result: nil),
            processLauncher: RuntimeTestProcessLauncher(),
            configurationStore: store,
            isPortOccupied: { _ in false },
            logDirectory: root.appendingPathComponent("logs")
        )

        let configuration = try await manager.selectSourceDirectory(
            at: source.appendingPathComponent("package.json")
        )

        XCTAssertEqual(configuration.runtimeMode, .source)
        XCTAssertEqual(configuration.sourcePath, source.standardizedFileURL.path)
        XCTAssertEqual(store.value.sourcePath, source.standardizedFileURL.path)
        try? FileManager.default.removeItem(at: root)
    }

    func testDetectorReadsNpmVersionsAndSourceManifests() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("Projects/AI/deepseek-harness")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(#"{"name":"deepseek-harness","version":"0.1.0-rc.8"}"#.utf8)
            .write(to: source.appendingPathComponent("package.json"))

        let runner = RuntimeTestCommandRunner(
            latest: "0.1.0-rc.9\n",
            installedJSON: #"{"dependencies":{"@deepseek-ai/dsh":{"version":"0.1.0-rc.7"}}}"#
        )
        let detector = HarnessRuntimeDetector(commandRunner: runner, homeURL: root)
        let inventory = await detector.detect()

        XCTAssertEqual(inventory.npmLatestVersion, "0.1.0-rc.9")
        XCTAssertEqual(inventory.npmInstalledVersion, "0.1.0-rc.7")
        XCTAssertEqual(inventory.sourceInstallations, [
            HarnessSourceInstallation(path: source.standardizedFileURL.path, version: "0.1.0-rc.8")
        ])
        try? FileManager.default.removeItem(at: root)
    }

    func testManagerUsesFixedNpmArgumentsAndTracksThenStopsOwnedProcess() async throws {
        let launcher = RuntimeTestProcessLauncher()
        let store = RuntimeTestConfigurationStore()
        let manager = HarnessRuntimeManager(
            discovery: SequencedRuntimeTestDiscovery(),
            processLauncher: launcher,
            configurationStore: store,
            isPortOccupied: { _ in false },
            logDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )

        let record = try await manager.start(mode: .npm, sourcePath: nil, port: 3080)
        XCTAssertEqual(record.pid, 4242)
        XCTAssertEqual(launcher.mode, .npm)
        XCTAssertEqual(launcher.port, 3080)
        XCTAssertNil(launcher.sourcePath)
        XCTAssertEqual(store.value.runtimeMode, .npm)
        XCTAssertEqual(store.value.port, 3080)

        try await manager.stop()
        let status = await manager.status()
        XCTAssertEqual(status, .stopped)
    }

    func testManagerNeverStopsAlreadyRunningExternalHarness() async {
        let launcher = RuntimeTestProcessLauncher()
        let endpoint = HarnessEndpoint(host: "127.0.0.1", port: 3080)!
        let manager = HarnessRuntimeManager(
            discovery: RuntimeTestDiscovery(result: endpoint),
            processLauncher: launcher,
            isPortOccupied: { _ in XCTFail("已有 Harness 时不应探测端口"); return true }
        )

        do {
            _ = try await manager.start(mode: .npm, sourcePath: nil, port: 3080)
            XCTFail("已有 Harness 应直接 Attach")
        } catch {
            XCTAssertEqual(error as? HarnessExternalRuntimeFailure, .harnessAlreadyRunning)
        }
        XCTAssertNil(launcher.mode)
    }
}

private actor SequencedRuntimeTestDiscovery: HarnessDiscovering {
    private var callCount = 0

    func discover() async -> HarnessEndpoint? {
        callCount += 1
        return callCount >= 2 ? HarnessEndpoint(host: "127.0.0.1", port: 3080) : nil
    }
}
