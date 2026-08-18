import Foundation
import Darwin
import os

private let supervisorLog = Logger(subsystem: "dev.deepseekharness.DeepSeekHarness", category: "runtime.process")

// MARK: - 子进程运行基础设施（文档 §32 / §18：有界输出、进程树清理）

/// 子进程运行结果（stdout / stderr 有界）。
struct ManagedProcessResult: Equatable, Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

/// 进程句柄：可等待退出 / 向进程组发信号（SIGINT → SIGTERM → SIGKILL）。
protocol ManagedProcessHandle: Sendable {
    var pid: Int32 { get }
    /// 等待进程退出（轮询 waitpid，可取消；唯一收割点）。
    func waitExit() async -> ManagedProcessResult
    /// SIGINT（优雅停止第一步）。
    func interrupt()
    /// SIGTERM（优雅停止第二步）。
    func terminate()
    /// SIGKILL（兜底，仅所有权验证后）。
    func kill()
    /// 进程是否仍在运行（kill 探测，不收割）。
    func isRunning() -> Bool
}

/// 子进程运行器（协议注入，单测不启动真实 Node / npm）。
protocol ManagedProcessRunning: Sendable {
    /// 一次性运行并等待退出（短命令，如 node --version）。
    func run(executable: URL, arguments: [String],
             environment: [String: String], currentDirectory: URL?) async throws -> ManagedProcessResult
    /// 以独立进程组启动长驻进程（Managed Harness），返回可信号控制的句柄。
    func launch(executable: URL, arguments: [String],
                environment: [String: String], currentDirectory: URL?) async throws -> any ManagedProcessHandle
}

/// 真实实现：`posix_spawn` + 独立进程组 + 有界输出。
///
/// - `POSIX_SPAWN_SETPGROUP`：子进程自成进程组，向组发信号可清理整棵进程树
///   （避免「npx 退出、node 子进程仍存活」）；
/// - stdout / stderr 走管道有界读取（64KB），防止无限增长；
/// - 只用于 Helper 启动 App-owned Node / npm；App 主进程不直接启动进程。
struct ProcessGroupLauncher: ManagedProcessRunning {
    static let maxOutputBytes = 64 * 1024

    func run(executable: URL, arguments: [String],
             environment: [String: String], currentDirectory: URL?) async throws -> ManagedProcessResult {
        let handle = try await launch(executable: executable, arguments: arguments,
                                      environment: environment, currentDirectory: currentDirectory)
        return await handle.waitExit()
    }

    func launch(executable: URL, arguments: [String],
                environment: [String: String], currentDirectory: URL?) async throws -> any ManagedProcessHandle {
        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            throw ManagedRuntimeError.runtimeIncompatible
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        // stdout / stderr 管道
        var stdoutFDs: [Int32] = [0, 0]
        var stderrFDs: [Int32] = [0, 0]
        guard pipe(&stdoutFDs) == 0, pipe(&stderrFDs) == 0 else {
            throw ManagedRuntimeError.runtimeIncompatible
        }
        posix_spawn_file_actions_adddup2(&fileActions, stdoutFDs[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, stderrFDs[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, stdoutFDs[1])
        posix_spawn_file_actions_addclose(&fileActions, stderrFDs[1])

        var attr: posix_spawnattr_t?
        guard posix_spawnattr_init(&attr) == 0 else {
            close(stdoutFDs[0]); close(stdoutFDs[1]); close(stderrFDs[0]); close(stderrFDs[1])
            throw ManagedRuntimeError.runtimeIncompatible
        }
        defer { posix_spawnattr_destroy(&attr) }
        // 子进程自成进程组：向 -pid 发信号可清理整棵进程树
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))

        // 参数：可执行路径 + 参数（无 shell，无任意命令）
        let argv: [UnsafeMutablePointer<CChar>?] = ([executable.path] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }

        // 环境：父环境 + 覆盖（不修改父进程环境）
        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment { env[key] = value }
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { envp.forEach { free($0) } }

        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable.path, &fileActions, &attr, argv, envp)
        // 关闭父端写口（子进程持有）
        close(stdoutFDs[1])
        close(stderrFDs[1])
        guard status == 0 else {
            close(stdoutFDs[0]); close(stderrFDs[0])
            throw ManagedRuntimeError.startFailed
        }

        return ProcessHandleImpl(
            pid: pid,
            stdoutHandle: FileHandle(fileDescriptor: stdoutFDs[0], closeOnDealloc: true),
            stderrHandle: FileHandle(fileDescriptor: stderrFDs[0], closeOnDealloc: true),
            maxOutputBytes: Self.maxOutputBytes
        )
    }
}

/// 真实进程句柄：waitpid 轮询 + 进程组信号。
///
/// 注意：waitpid 只能收割一次——`isRunning()` 用 `kill(pid, 0)` 探测，
/// `waitExit()` 负责唯一一次收割并缓存退出状态。
private final class ProcessHandleImpl: ManagedProcessHandle, @unchecked Sendable {
    let pid: Int32
    private let stdoutHandle: FileHandle
    private let stderrHandle: FileHandle
    private let maxOutputBytes: Int

    private let lock = NSLock()
    private var _exitStatus: Int32?

    init(pid: Int32, stdoutHandle: FileHandle, stderrHandle: FileHandle, maxOutputBytes: Int) {
        self.pid = pid
        self.stdoutHandle = stdoutHandle
        self.stderrHandle = stderrHandle
        self.maxOutputBytes = maxOutputBytes
    }

    func interrupt() { Darwin.kill(-pid, SIGINT) }
    func terminate() { Darwin.kill(-pid, SIGTERM) }
    func kill() { Darwin.kill(-pid, SIGKILL) }

    /// 是否仍在运行（kill 探测；不收割）。
    func isRunning() -> Bool {
        if lock.withLock({ _exitStatus != nil }) { return false }
        return Darwin.kill(pid, 0) == 0
    }

    func waitExit() async -> ManagedProcessResult {
        // 轮询 waitpid（WNOHANG，可取消）；退出后做唯一一次阻塞收割。
        while true {
            let exited = await Self.waitpidExited(pid)
            if exited { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let status = reapExitStatus()
        let stdout = Self.boundedRead(handle: stdoutHandle, max: maxOutputBytes)
        let stderr = Self.boundedRead(handle: stderrHandle, max: maxOutputBytes)
        return ManagedProcessResult(exitCode: status, stdout: stdout, stderr: stderr)
    }

    /// WNOHANG 探测是否已退出（不收割）。
    private static func waitpidExited(_ pid: Int32) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            var status: Int32 = 0
            let result = waitpid(pid, &status, WNOHANG)
            return result != 0
        }.value
    }

    /// 唯一一次阻塞收割，返回退出码（被信号终止返回 128+signal）。
    private func reapExitStatus() -> Int32 {
        if let cached = lock.withLock({ _exitStatus }) { return cached }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        // C 宏未导入 Swift，手动实现（sys/wait.h 语义）
        let exitStatus: Int32
        if (status & 0x7f) == 0 {
            exitStatus = (status >> 8) & 0xff            // WIFEXITED + WEXITSTATUS
        } else if ((status & 0x7f) + 1) >> 1 > 0 {
            exitStatus = 128 + (status & 0x7f)           // WIFSIGNALED + WTERMSIG
        } else {
            exitStatus = -1
        }
        lock.withLock { _exitStatus = exitStatus }
        return exitStatus
    }

    private static func boundedRead(handle: FileHandle, max: Int) -> String {
        let data = handle.readDataToEndOfFile()
        let bounded = data.count > max ? data.prefix(max) : data
        return String(data: bounded, encoding: .utf8) ?? ""
    }
}

// MARK: - Managed Harness 进程监督器（文档 §11 / §17 / §18 / §32）

/// Managed Harness 进程监督器。
///
/// 职责：
/// - 维护**单一活跃 generation**（generationID + pid + 进程句柄）；
/// - 启动：endpoint 占用检查 → App-owned node + exact version → 独立进程组启动；
/// - 停止：SIGINT → 等待 → SIGTERM → 等待 →（仍 owned 才）SIGKILL 兜底；
/// - 意外退出：异步监视清理注册；
/// - 所有权：Stop / Kill 前必须验证 generationID + pid 与活跃注册一致（防 PID reuse）。
///
/// 依赖全部协议注入，单测用 fake runner / fake 端口探测。
/// 使用 class（引用语义）：锁保护状态必须跨任务共享。
final class ManagedProcessSupervisor: @unchecked Sendable {
    /// 活跃 generation 注册（文档 §17）。
    struct Registration: Equatable, Sendable {
        let generationID: UUID
        let pid: Int32
        let startedAt: Date
        let version: String
        let port: Int
    }

    struct StopGrace {
        /// SIGINT 后等待秒数。
        var intWait: Int = 3
        /// SIGTERM 后等待秒数。
        var termWait: Int = 3
    }

    var launcher: any ManagedProcessRunning
    var paths: ManagedRuntimePaths
    /// endpoint 占用探测（默认：TCP connect 127.0.0.1:port）。
    var isPortOccupied: @Sendable (Int) async -> Bool
    var now: @Sendable () -> Date = { Date() }
    var generationID: @Sendable () -> UUID = { UUID() }
    /// App-owned Node 定位（测试注入；默认取 App bundle）。
    var nodeLocator: @Sendable () -> URL? = { BundledNodeRuntimeLocator.bundledNodeURL() }
    /// exact 包 bin 存在性检查（测试注入；默认查文件系统）。
    var packageBinExists: @Sendable (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    /// SIGINT/SIGTERM 等待间隔（测试可缩短）。
    var graceSeconds = StopGrace()

    private let lock = NSLock()
    private var _registration: Registration?
    private var _handle: (any ManagedProcessHandle)?

    init(launcher: any ManagedProcessRunning,
         paths: ManagedRuntimePaths,
         isPortOccupied: @escaping @Sendable (Int) async -> Bool) {
        self.launcher = launcher
        self.paths = paths
        self.isPortOccupied = isPortOccupied
    }

    /// 当前活跃注册（只读副本）。
    var registration: Registration? {
        lock.withLock { _registration }
    }

    // MARK: - Start（文档 §16；Start 前重新检查 endpoint）

    func start(version: String, port: Int) async throws -> ManagedHarnessIdentity {
        guard ManagedPackageCache.isSafeVersionComponent(version) else {
            throw ManagedRuntimeError.packagePreparationFailed
        }
        guard (1...65535).contains(port) else {
            throw ManagedRuntimeError.packagePreparationFailed
        }
        // 并发保护：活跃 generation 已存在 → 不重复启动
        if lock.withLock({ _registration != nil }) {
            throw ManagedRuntimeError.startFailed
        }
        // endpoint 占用保护（文档 §16 / §32）
        if await isPortOccupied(port) {
            throw ManagedRuntimeError.endpointOccupied
        }
        // App-owned node + exact package（Phase 10 准备）
        guard let node = nodeLocator() else {
            throw ManagedRuntimeError.runtimeMissing
        }
        guard let packageDir = ManagedPackageCache.packageDir(for: paths, version: version) else {
            throw ManagedRuntimeError.packagePreparationFailed
        }
        let bin = packageDir.appendingPathComponent("node_modules/@deepseek-ai/dsh/lib/bin.js", isDirectory: false)
        guard packageBinExists(bin) else {
            throw ManagedRuntimeError.packagePreparationFailed
        }

        let id = generationID()
        let startedAt = now()
        // `dsh web --port <port>`（README 确认：web 是 --profile web 别名，--port 属于 web app；
        // `$DSH_HOME` 由启动器设置——profile-boot 显式支持）。
        let args = [bin.path, "web", "--port", "\(port)"]
        var env = ManagedPackageCache.environment(for: paths)
        env["DSH_HOME"] = paths.managedHarnessHome.path
        // 让子进程能找到随 Node 携带的 npm / npx
        let nodeBinDir = node.deletingLastPathComponent()
        env["PATH"] = (env["PATH"] ?? "") + ":" + nodeBinDir.path

        let handle: any ManagedProcessHandle
        do {
            handle = try await launcher.launch(
                executable: node,
                arguments: args,
                environment: env,
                currentDirectory: nil
            )
        } catch {
            throw ManagedRuntimeError.startFailed
        }

        // 注册活跃 generation（只有注册成功的 pid 才允许被 Stop）
        lock.withLock {
            _handle = handle
            _registration = Registration(
                generationID: id,
                pid: handle.pid,
                startedAt: startedAt,
                version: version,
                port: port
            )
        }
        // 意外退出 → 清理注册（异步监视）
        Task { [weak self] in
            _ = await handle.waitExit()
            self?.handleUnexpectedExit(handle: handle)
        }

        return ManagedHarnessIdentity(
            generationID: id,
            pid: handle.pid,
            startedAt: startedAt,
            version: version,
            port: port
        )
    }

    // MARK: - Stop（文档 §18：SIGINT → SIGTERM → 仅 owned 才兜底）

    func stop(identity: ManagedHarnessIdentity) async throws {
        let (handle, registration) = lock.withLock { (_handle, _registration) }
        guard let handle, let registration else {
            throw ManagedRuntimeError.stopFailed
        }
        // 所有权验证（文档 §17 / §32）：generationID + pid 都匹配才允许停止
        guard registration.generationID == identity.generationID,
              registration.pid == identity.pid else {
            throw ManagedRuntimeError.stopFailed
        }

        // SIGINT → 等待
        handle.interrupt()
        if await waitForExit(handle, timeoutSeconds: Double(graceSeconds.intWait)) {
            clearRegistrationIfOwned(identity)
            return
        }

        // SIGTERM → 等待
        handle.terminate()
        if await waitForExit(handle, timeoutSeconds: Double(graceSeconds.termWait)) {
            clearRegistrationIfOwned(identity)
            return
        }

        // 兜底：仅在确认仍是 owned generation 时 SIGKILL（防 PID reuse 误杀）
        let stillOwned = lock.withLock {
            _registration?.generationID == identity.generationID && _registration?.pid == identity.pid
        }
        if stillOwned, handle.isRunning() {
            handle.kill()
        }
        clearRegistrationIfOwned(identity)
    }

    // MARK: - Status

    func status(identity: ManagedHarnessIdentity) -> ManagedHarnessProcessStatus {
        let (handle, registration) = lock.withLock { (_handle, _registration) }
        guard let handle, let registration,
              registration.generationID == identity.generationID,
              registration.pid == identity.pid else {
            return .stopped
        }
        return handle.isRunning() ? .running(pid: identity.pid) : .stopped
    }

    /// 停止当前活跃 Managed Harness（用于 App 断开 / 退出策略；无活跃则无操作）。
    func stopActive() async {
        guard let registration = lock.withLock({ _registration }) else { return }
        let identity = ManagedHarnessIdentity(
            generationID: registration.generationID,
            pid: registration.pid,
            startedAt: registration.startedAt,
            version: registration.version,
            port: registration.port
        )
        try? await stop(identity: identity)
    }

    // MARK: - Private

    private func waitForExit(_ handle: any ManagedProcessHandle, timeoutSeconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while handle.isRunning() {
            if Date() >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return true
    }

    /// 意外退出（未被本 Supervisor 主动停止）：清注册；若进程仍在则补 SIGKILL。
    private func handleUnexpectedExit(handle: any ManagedProcessHandle) {
        let (reg, activeHandle) = lock.withLock { (_registration, _handle) }
        guard let reg, let activeHandle, activeHandle.pid == handle.pid else { return }
        if handle.isRunning() {
            handle.kill()
        }
        lock.withLock {
            if _registration?.pid == handle.pid {
                _registration = nil
                _handle = nil
            }
        }
        supervisorLog.info("Managed Harness 意外退出（pid \(reg.pid, privacy: .public)，version \(reg.version, privacy: .public)）")
    }

    private func clearRegistrationIfOwned(_ identity: ManagedHarnessIdentity) {
        lock.withLock {
            if _registration?.generationID == identity.generationID, _registration?.pid == identity.pid {
                _registration = nil
                _handle = nil
            }
        }
    }
}
