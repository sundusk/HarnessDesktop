import Foundation
import Darwin

// MARK: - External Harness runtime model

/// Harness 的外部启动方式。Managed Runtime 使用独立的 Helper API，不属于此枚举。
enum HarnessRuntimeMode: String, CaseIterable, Codable, Equatable, Sendable {
    case npm
    case source

    var title: String {
        switch self {
        case .npm: return "npm"
        case .source: return "源码"
        }
    }
}

/// 扫描得到的 Harness 源码安装。
struct HarnessSourceInstallation: Codable, Equatable, Identifiable, Sendable {
    let path: String
    let version: String

    var id: String { path }
}

/// npm / 源码扫描结果。它只描述可启动候选，不作为当前运行版本来源。
struct HarnessRuntimeInventory: Equatable, Sendable {
    var npmLatestVersion: String?
    var npmInstalledVersion: String?
    var sourceInstallations: [HarnessSourceInstallation]

    static let empty = HarnessRuntimeInventory(
        npmLatestVersion: nil,
        npmInstalledVersion: nil,
        sourceInstallations: []
    )
}

/// 按文档 §9 保存的启动配置。
struct HarnessRuntimeConfiguration: Codable, Equatable, Sendable {
    var runtimeMode: HarnessRuntimeMode = .npm
    var sourcePath: String?
    var sourceBookmark: Data? = nil
    var port: Int = 3080
    var autoStart: Bool = false
}

/// 文档 §10 要求的进程追踪记录。
struct HarnessRuntimeProcessRecord: Codable, Equatable, Sendable {
    let pid: Int32
    let mode: HarnessRuntimeMode
    let startedAt: Date
    let logPath: String
}

enum HarnessExternalRuntimeStatus: Equatable, Sendable {
    case stopped
    case starting(HarnessRuntimeMode)
    case running(HarnessRuntimeProcessRecord)
    case failed(String)
}

enum HarnessExternalRuntimeFailure: Error, Equatable, Sendable {
    case nodeUnavailable
    case pnpmUnavailable
    case sourcePathMissing
    case sourceSelectionFailed
    case invalidPort
    case endpointOccupied
    case harnessAlreadyRunning
    case startFailed
    case startupTimeout(logPath: String)
    case stopFailed
}

extension HarnessExternalRuntimeFailure {
    var userMessage: String {
        switch self {
        case .nodeUnavailable:
            return "未找到 Node 环境，请安装 Node.js 后重试。"
        case .pnpmUnavailable:
            return "源码模式需要 pnpm，请先安装 pnpm。"
        case .sourcePathMissing:
            return "未找到有效的 deepseek-harness 源码目录。"
        case .sourceSelectionFailed:
            return "无法保存源码目录访问权限，请重新选择源码目录。"
        case .invalidPort:
            return "端口必须是 1…65535 之间的整数。"
        case .endpointOccupied:
            return "端口已被占用，请先停止占用 3080 端口的服务。"
        case .harnessAlreadyRunning:
            return "Harness 已在运行，正在连接现有实例。"
        case .startFailed:
            return "Harness 启动失败，请查看日志。"
        case .startupTimeout(let logPath):
            return "Harness 启动超时，请查看日志：\(logPath)"
        case .stopFailed:
            return "Harness 停止失败，请查看日志。"
        }
    }
}

// MARK: - Configuration store

protocol HarnessRuntimeConfigurationStoring: Sendable {
    func load() throws -> HarnessRuntimeConfiguration
    func save(_ configuration: HarnessRuntimeConfiguration) throws
}

struct JSONHarnessRuntimeConfigurationStore: HarnessRuntimeConfigurationStoring, Sendable {
    let fileURL: URL

    init(fileURL: URL = JSONHarnessRuntimeConfigurationStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("HarnessDesktop", isDirectory: true)
            .appendingPathComponent("config.json", isDirectory: false)
    }

    func load() throws -> HarnessRuntimeConfiguration {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return HarnessRuntimeConfiguration()
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder.runtime.decode(HarnessRuntimeConfiguration.self, from: data)
    }

    func save(_ configuration: HarnessRuntimeConfiguration) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder.runtime.encode(configuration)
        try data.write(to: fileURL, options: .atomic)
    }
}

private extension JSONEncoder {
    static var runtime: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var runtime: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// MARK: - npm / source detection

protocol HarnessCommandRunning: Sendable {
    func run(executableName: String, arguments: [String], currentDirectory: URL?) async throws -> ManagedProcessResult
}

struct SystemHarnessCommandRunner: HarnessCommandRunning, Sendable {
    func run(executableName: String, arguments: [String], currentDirectory: URL?) async throws -> ManagedProcessResult {
        guard let executable = HarnessExecutableLocator.url(for: executableName) else {
            throw HarnessExternalRuntimeFailure.nodeUnavailable
        }
        return try await ProcessGroupLauncher().run(
            executable: executable,
            arguments: arguments,
            environment: [:],
            currentDirectory: currentDirectory
        )
    }
}

enum HarnessExecutableLocator {
    static func url(for name: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        if name.contains("/") {
            let url = URL(fileURLWithPath: name)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
        let paths = (environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
            .split(separator: ":")
            .map(String.init)
        for path in paths {
            let candidate = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}

struct HarnessRuntimeDetector: @unchecked Sendable {
    var commandRunner: any HarnessCommandRunning
    var homeURL: URL

    init(commandRunner: any HarnessCommandRunning = SystemHarnessCommandRunner(),
         homeURL: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.commandRunner = commandRunner
        self.homeURL = homeURL
    }

    func detect() async -> HarnessRuntimeInventory {
        async let latest = npmLatestVersion()
        async let installed = npmInstalledVersion()
        let (latestVersion, installedVersion) = await (latest, installed)
        return HarnessRuntimeInventory(
            npmLatestVersion: latestVersion,
            npmInstalledVersion: installedVersion,
            sourceInstallations: sourceInstallations()
        )
    }

    private func npmLatestVersion() async -> String? {
        let result = try? await commandRunner.run(
            executableName: "npm",
            arguments: ["view", "@deepseek-ai/dsh", "version"],
            currentDirectory: nil
        )
        return normalizedVersion(result?.stdout)
    }

    private func npmInstalledVersion() async -> String? {
        let result = try? await commandRunner.run(
            executableName: "npm",
            arguments: ["list", "-g", "@deepseek-ai/dsh", "--depth=0", "--json"],
            currentDirectory: nil
        )
        guard let stdout = result?.stdout.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: stdout) as? [String: Any],
              let dependencies = object["dependencies"] as? [String: Any],
              let package = dependencies["@deepseek-ai/dsh"] as? [String: Any],
              let version = package["version"] as? String else {
            return nil
        }
        return normalizedVersion(version)
    }

    private func sourceInstallations() -> [HarnessSourceInstallation] {
        let roots = ["Projects", "Developer", "Documents", "Work"].map {
            homeURL.appendingPathComponent($0, isDirectory: true)
        }
        var results: [HarnessSourceInstallation] = []
        var seen = Set<String>()
        let fileManager = FileManager.default

        for root in roots where fileManager.fileExists(atPath: root.path) {
            let candidates = [root] + (fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )?.compactMap { $0 as? URL } ?? [])
            for candidate in candidates where candidate.lastPathComponent == "deepseek-harness" {
                let manifest = candidate.appendingPathComponent("package.json")
                guard let data = try? Data(contentsOf: manifest),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let version = object["version"] as? String,
                      !version.isEmpty else { continue }
                let path = candidate.standardizedFileURL.path
                guard seen.insert(path).inserted else { continue }
                results.append(HarnessSourceInstallation(path: path, version: version))
            }
        }
        return results.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func normalizedVersion(_ value: String?) -> String? {
        guard let value else { return nil }
        let version = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? nil : version
    }
}

// MARK: - External process ownership

protocol HarnessRuntimeProcessHandle: Sendable {
    var pid: Int32 { get }
    func interrupt()
    func terminate()
    func kill()
    func isRunning() -> Bool
}

protocol HarnessRuntimeProcessLaunching: Sendable {
    func launch(mode: HarnessRuntimeMode, sourcePath: URL?, port: Int, logURL: URL) throws -> any HarnessRuntimeProcessHandle
}

struct SystemHarnessRuntimeProcessLauncher: HarnessRuntimeProcessLaunching, Sendable {
    func launch(mode: HarnessRuntimeMode, sourcePath: URL?, port: Int, logURL: URL) throws -> any HarnessRuntimeProcessHandle {
        let executableName: String
        let arguments: [String]
        let currentDirectory: URL?
        switch mode {
        case .npm:
            executableName = "npx"
            arguments = ["@deepseek-ai/dsh", "web", "--port", String(port)]
            currentDirectory = nil
        case .source:
            guard let sourcePath,
                  FileManager.default.fileExists(atPath: sourcePath.appendingPathComponent("package.json").path) else {
                throw HarnessExternalRuntimeFailure.sourcePathMissing
            }
            executableName = "pnpm"
            arguments = ["dsh", "web", "--port", String(port)]
            currentDirectory = sourcePath
        }
        guard let executable = HarnessExecutableLocator.url(for: executableName) else {
            throw mode == .npm ? HarnessExternalRuntimeFailure.nodeUnavailable : .pnpmUnavailable
        }
        return try FoundationHarnessRuntimeProcess(
            executable: executable,
            arguments: arguments,
            currentDirectory: currentDirectory,
            logURL: logURL
        )
    }
}

private final class FoundationHarnessRuntimeProcess: HarnessRuntimeProcessHandle, @unchecked Sendable {
    let process: Process
    let pid: Int32
    private let output: FileHandle
    private let lock = NSLock()
    private var didCloseOutput = false

    init(executable: URL, arguments: [String], currentDirectory: URL?, logURL: URL) throws {
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: logURL)
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.environment = ProcessInfo.processInfo.environment
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            try? output.close()
            throw HarnessExternalRuntimeFailure.startFailed
        }
        self.process = process
        self.pid = process.processIdentifier
        self.output = output
        // 该进程组由本次启动拥有，停止时只向此 pid 的组发信号。
        _ = setpgid(pid, pid)
    }

    func interrupt() { signal(SIGINT) }
    func terminate() { signal(SIGTERM) }
    func kill() { signal(SIGKILL) }
    func isRunning() -> Bool { process.isRunning }

    private func signal(_ signal: Int32) {
        guard process.isRunning else { return }
        if getpgid(pid) == pid {
            _ = Darwin.kill(-pid, signal)
        } else if signal == SIGINT {
            process.interrupt()
        } else if signal == SIGTERM {
            process.terminate()
        } else {
            _ = Darwin.kill(pid, signal)
        }
    }

    deinit { closeOutput() }

    private func closeOutput() {
        lock.withLock {
            guard !didCloseOutput else { return }
            didCloseOutput = true
            try? output.close()
        }
    }
}

// MARK: - Runtime manager

protocol HarnessRuntimeControlling: Sendable {
    func detect() async -> HarnessRuntimeInventory
    func configuration() async -> HarnessRuntimeConfiguration
    func selectSourceDirectory(at url: URL) async throws -> HarnessRuntimeConfiguration
    func start(mode: HarnessRuntimeMode, sourcePath: String?, port: Int) async throws -> HarnessRuntimeProcessRecord
    func stop() async throws
    func restart() async throws -> HarnessRuntimeProcessRecord
    func status() async -> HarnessExternalRuntimeStatus
    func update(discovery: any HarnessDiscovering) async
}

/// npm / 源码启动的统一入口（文档 §4）。
///
/// 它只启动两个固定的 argv 组合，不接收任意 shell 字符串；
/// `runningVersion` 仍由 AppCoordinator 的 `host.describe` 握手提供。
actor HarnessRuntimeManager: HarnessRuntimeControlling {
    private var discovery: any HarnessDiscovering
    private let detector: HarnessRuntimeDetector
    private let processLauncher: any HarnessRuntimeProcessLaunching
    private let configurationStore: any HarnessRuntimeConfigurationStoring
    private let isPortOccupied: @Sendable (Int) async -> Bool
    private let logDirectory: URL
    private var configurationValue: HarnessRuntimeConfiguration
    private var activeProcess: (any HarnessRuntimeProcessHandle)?
    private var activeRecord: HarnessRuntimeProcessRecord?
    private var lastMode: HarnessRuntimeMode = .npm
    private var lastSourcePath: String?
    private var lastPort = 3080
    private var monitorTask: Task<Void, Never>?
    private var sourceAccessURL: URL?

    init(discovery: any HarnessDiscovering,
         detector: HarnessRuntimeDetector = HarnessRuntimeDetector(),
         processLauncher: any HarnessRuntimeProcessLaunching = SystemHarnessRuntimeProcessLauncher(),
         configurationStore: any HarnessRuntimeConfigurationStoring = JSONHarnessRuntimeConfigurationStore(),
         isPortOccupied: @escaping @Sendable (Int) async -> Bool = { port in await HarnessPortProbe.isOccupied(port) },
         logDirectory: URL = JSONHarnessRuntimeConfigurationStore.defaultFileURL().deletingLastPathComponent().appendingPathComponent("logs", isDirectory: true)) {
        self.discovery = discovery
        self.detector = detector
        self.processLauncher = processLauncher
        self.configurationStore = configurationStore
        self.isPortOccupied = isPortOccupied
        self.logDirectory = logDirectory
        self.configurationValue = (try? configurationStore.load()) ?? HarnessRuntimeConfiguration()
        self.lastMode = self.configurationValue.runtimeMode
        self.lastSourcePath = self.configurationValue.sourcePath
        self.lastPort = self.configurationValue.port
        self.sourceAccessURL = nil
    }

    func detect() async -> HarnessRuntimeInventory {
        await detector.detect()
    }

    func configuration() async -> HarnessRuntimeConfiguration {
        configurationValue
    }

    func selectSourceDirectory(at url: URL) async throws -> HarnessRuntimeConfiguration {
        let sourceURL = try normalizedSourceURL(from: url)
        let bookmark = try? sourceURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        configurationValue.runtimeMode = .source
        configurationValue.sourcePath = sourceURL.path
        configurationValue.sourceBookmark = bookmark
        lastMode = .source
        lastSourcePath = sourceURL.path
        try configurationStore.save(configurationValue)
        beginSourceAccess(for: sourceURL)
        return configurationValue
    }

    func update(discovery: any HarnessDiscovering) async {
        self.discovery = discovery
    }

    func status() async -> HarnessExternalRuntimeStatus {
        if let record = activeRecord, activeProcess?.isRunning() == true {
            return .running(record)
        }
        return activeRecord == nil ? .stopped : .stopped
    }

    func start(mode: HarnessRuntimeMode, sourcePath: String?, port: Int) async throws -> HarnessRuntimeProcessRecord {
        guard (1...65535).contains(port) else { throw HarnessExternalRuntimeFailure.invalidPort }
        guard activeProcess == nil else { throw HarnessExternalRuntimeFailure.startFailed }
        if await discovery.discover() != nil {
            throw HarnessExternalRuntimeFailure.harnessAlreadyRunning
        }
        guard !(await isPortOccupied(port)) else {
            throw HarnessExternalRuntimeFailure.endpointOccupied
        }

        let validatedSourcePath: URL?
        switch mode {
        case .npm:
            validatedSourcePath = nil
        case .source:
            let requestedPath = sourcePath ?? configurationValue.sourcePath
            guard let requestedPath else { throw HarnessExternalRuntimeFailure.sourcePathMissing }
            let url = try sourceURL(for: requestedPath)
            beginSourceAccess(for: url)
            validatedSourcePath = url
        }

        let logURL = logDirectory.appendingPathComponent(
            "harness-\(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-"))-\(mode.rawValue).log",
            isDirectory: false
        )
        let process: any HarnessRuntimeProcessHandle
        do {
            process = try processLauncher.launch(mode: mode, sourcePath: validatedSourcePath, port: port, logURL: logURL)
        } catch let failure as HarnessExternalRuntimeFailure {
            throw failure
        } catch {
            throw HarnessExternalRuntimeFailure.startFailed
        }

        let record = HarnessRuntimeProcessRecord(pid: process.pid, mode: mode, startedAt: Date(), logPath: logURL.path)
        activeProcess = process
        activeRecord = record
        lastMode = mode
        lastSourcePath = validatedSourcePath?.path ?? sourcePath
        lastPort = port
        configurationValue.runtimeMode = mode
        configurationValue.sourcePath = lastSourcePath
        configurationValue.port = port
        try? configurationStore.save(configurationValue)
        monitorTask?.cancel()
        monitorTask = monitor(process: process)

        for _ in 0..<60 {
            if await discovery.discover() != nil {
                AppLogger.runtimeProcess.info("外部 Harness 已启动：mode=\(mode.rawValue, privacy: .public) pid=\(process.pid, privacy: .public) port=\(port, privacy: .public)")
                return record
            }
            guard process.isRunning() else {
                clearActiveProcess(process)
                throw HarnessExternalRuntimeFailure.startFailed
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        try? await stopProcess(process, record: record)
        throw HarnessExternalRuntimeFailure.startupTimeout(logPath: logURL.path)
    }

    func stop() async throws {
        guard let process = activeProcess, let record = activeRecord else { return }
        try await stopProcess(process, record: record)
        AppLogger.runtimeProcess.info("外部 Harness 已停止：pid=\(record.pid, privacy: .public)")
    }

    func restart() async throws -> HarnessRuntimeProcessRecord {
        if activeProcess != nil { try await stop() }
        return try await start(mode: lastMode, sourcePath: lastSourcePath, port: lastPort)
    }

    private func monitor(process: any HarnessRuntimeProcessHandle) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled && process.isRunning() {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard !Task.isCancelled else { return }
            await self?.clearActiveProcess(process)
        }
    }

    private func stopProcess(_ process: any HarnessRuntimeProcessHandle, record: HarnessRuntimeProcessRecord) async throws {
        guard activeRecord == record, activeProcess?.pid == process.pid else {
            throw HarnessExternalRuntimeFailure.stopFailed
        }
        monitorTask?.cancel()
        process.interrupt()
        if await waitUntilStopped(process, timeout: 3) {
            clearActiveProcess(process)
            return
        }
        process.terminate()
        if await waitUntilStopped(process, timeout: 3) {
            clearActiveProcess(process)
            return
        }
        process.kill()
        if await waitUntilStopped(process, timeout: 1) {
            clearActiveProcess(process)
            return
        }
        throw HarnessExternalRuntimeFailure.stopFailed
    }

    private func waitUntilStopped(_ process: any HarnessRuntimeProcessHandle, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return !process.isRunning()
    }

    private func clearActiveProcess(_ process: any HarnessRuntimeProcessHandle) {
        guard activeProcess?.pid == process.pid else { return }
        activeProcess = nil
        activeRecord = nil
    }

    private func normalizedSourceURL(from url: URL) throws -> URL {
        var sourceURL = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory) else {
            throw HarnessExternalRuntimeFailure.sourcePathMissing
        }
        if !isDirectory.boolValue && sourceURL.lastPathComponent == "package.json" {
            sourceURL.deleteLastPathComponent()
            isDirectory = true
        }
        guard isDirectory.boolValue,
              FileManager.default.fileExists(atPath: sourceURL.appendingPathComponent("package.json").path) else {
            throw HarnessExternalRuntimeFailure.sourcePathMissing
        }
        return sourceURL
    }

    private func sourceURL(for path: String) throws -> URL {
        if path == configurationValue.sourcePath,
           let bookmark = configurationValue.sourceBookmark {
            var isStale = false
            if let resolved = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                if isStale,
                   let refreshedBookmark = try? resolved.bookmarkData(
                       options: [.withSecurityScope],
                       includingResourceValuesForKeys: nil,
                       relativeTo: nil
                   ) {
                    configurationValue.sourceBookmark = refreshedBookmark
                    try? configurationStore.save(configurationValue)
                }
                return try normalizedSourceURL(from: resolved)
            }
        }
        return try normalizedSourceURL(from: URL(fileURLWithPath: path))
    }

    private func beginSourceAccess(for url: URL) {
        guard sourceAccessURL?.standardizedFileURL.path != url.standardizedFileURL.path else { return }
        sourceAccessURL?.stopAccessingSecurityScopedResource()
        sourceAccessURL = url.startAccessingSecurityScopedResource() ? url : nil
    }
}

enum HarnessPortProbe {
    static func isOccupied(_ port: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard socket >= 0 else {
                continuation.resume(returning: false)
                return
            }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(port).bigEndian
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            Darwin.close(socket)
            continuation.resume(returning: result == 0)
        }
    }
}
