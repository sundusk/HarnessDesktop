import Foundation

// MARK: - 可注入的终端命令执行（规格 §34：所有新逻辑协议化、可注入，测试不真正起 Node / npm）

/// 执行一条终端命令并返回标准输出（可注入，测试用 fake）。
protocol ShellCommandExecuting: Sendable {
    /// - Parameters:
    ///   - executablePath: 可执行文件的绝对路径。
    ///   - arguments: 传给可执行文件的参数。
    ///   - timeout: 超时秒数；超时抛 `HarnessTerminalVersionError.timedOut`。
    /// - Returns: 标准输出原文（未裁剪）。
    func run(_ executablePath: String, arguments: [String], timeout: TimeInterval) async throws -> String
}

/// 真实实现：`Process` 执行、超时强杀、输出有界。
///
/// 阻塞部分在 detached 任务中执行，避免占用主线程；stderr 丢弃（错误只以退出码呈现），
/// 防止 stderr 管道写满导致死锁。
struct SystemShellCommandExecutor: ShellCommandExecuting {
    func run(_ executablePath: String, arguments: [String], timeout: TimeInterval) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice

            let timeoutFlag = TimeoutFlag()
            let watchdog = Task {
                try? await Task.sleep(for: .seconds(timeout))
                timeoutFlag.fired = true
                if process.isRunning {
                    process.terminate()
                }
            }
            defer { watchdog.cancel() }

            try process.run()
            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            if timeoutFlag.fired {
                throw HarnessTerminalVersionError.timedOut(executablePath)
            }
            guard process.terminationStatus == 0 else {
                throw HarnessTerminalVersionError.commandFailed(executablePath, process.terminationStatus)
            }
            guard let text = String(data: outData, encoding: .utf8) else {
                throw HarnessTerminalVersionError.invalidVersionOutput("")
            }
            return text
        }.value
    }
}

/// 超时标记（看护任务与主流程共享）。
private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _fired = false
    var fired: Bool {
        get { lock.withLock { _fired } }
        set { lock.withLock { _fired = newValue } }
    }
}

// MARK: - 可执行文件定位

/// 可执行文件解析：GUI 应用从 Finder 启动时 PATH 通常不含 Homebrew，
/// 需要在常见安装位置补查。
enum HarnessTerminalLocator {
    /// 在 PATH 与常见位置中查找可执行文件（npx / npm）。
    @Sendable
    static func resolveExecutable(_ name: String) -> String? {
        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
        var dirs = pathEnv.split(separator: ":", omittingEmptySubsequences: true).map(String.init)
        dirs += ["/opt/homebrew/bin", "/usr/local/bin"]
        for dir in dirs {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}

// MARK: - 版本检测错误

enum HarnessTerminalVersionError: Error, Equatable, Sendable {
    /// 找不到可执行文件（如 npx / npm 未安装）。
    case executableNotFound(String)
    /// 命令非零退出（可执行文件路径，退出码）。
    case commandFailed(String, Int32)
    /// 执行超时。
    case timedOut(String)
    /// 输出无法解析为版本号。
    case invalidVersionOutput(String)
}

// MARK: - 版本查询协议

/// 本地已安装（npx 解析的）Harness 版本查询。
protocol HarnessInstalledVersionProviding: Sendable {
    func fetchInstalledVersion() async throws -> HarnessVersion
}

/// npm 最新版本查询。
protocol HarnessLatestInstallableVersionProviding: Sendable {
    func fetchLatestInstallableVersion() async throws -> HarnessVersion
}

// MARK: - 终端命令实现

/// 通过 `npx -y @deepseek-ai/dsh --version` 检测本地 Harness 版本。
///
/// 说明：`-y` 避免 npx 首次安装时的交互确认；输出取最后一个非空行
/// （npm 可能把警告打到 stdout）。
struct NpxInstalledVersionProvider: HarnessInstalledVersionProviding {
    var executor: any ShellCommandExecuting
    var resolveExecutable: @Sendable (String) -> String? = HarnessTerminalLocator.resolveExecutable

    init(executor: any ShellCommandExecuting = SystemShellCommandExecutor()) {
        self.executor = executor
    }

    func fetchInstalledVersion() async throws -> HarnessVersion {
        guard let npx = resolveExecutable("npx") else {
            throw HarnessTerminalVersionError.executableNotFound("npx")
        }
        let output = try await executor.run(
            npx,
            arguments: ["-y", "@deepseek-ai/dsh", "--version"],
            timeout: 120
        )
        return try Self.parseVersionOutput(output)
    }

    /// 解析命令输出：取最后一个非空行作为版本号。
    static func parseVersionOutput(_ output: String) throws -> HarnessVersion {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let last = lines.last ?? output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let version = HarnessVersion(last) else {
            throw HarnessTerminalVersionError.invalidVersionOutput(output)
        }
        return version
    }
}

/// 通过 `npm view @deepseek-ai/dsh version` 查询 npm 最新版本。
struct NpmViewLatestVersionProvider: HarnessLatestInstallableVersionProviding {
    var executor: any ShellCommandExecuting
    var resolveExecutable: @Sendable (String) -> String? = HarnessTerminalLocator.resolveExecutable

    init(executor: any ShellCommandExecuting = SystemShellCommandExecutor()) {
        self.executor = executor
    }

    func fetchLatestInstallableVersion() async throws -> HarnessVersion {
        guard let npm = resolveExecutable("npm") else {
            throw HarnessTerminalVersionError.executableNotFound("npm")
        }
        let output = try await executor.run(
            npm,
            arguments: ["view", "@deepseek-ai/dsh", "version"],
            timeout: 60
        )
        return try NpxInstalledVersionProvider.parseVersionOutput(output)
    }
}

// MARK: - 弹窗文案（纯函数，测试友好）

/// 版本检查结果弹窗内容生成。
enum HarnessVersionCheckPresenter {
    /// - Returns: (标题, 详情)。
    static func popupContent(status: HarnessUpdateStatus) -> (title: String, detail: String) {
        switch status {
        case .upToDate(let current):
            return ("您使用的就是最新版本", "当前版本：\(current)")
        case .updateAvailable(let current, let latestRelease, _):
            return (
                "发现 DeepSeek Harness 新版本",
                "当前版本：\(current)\n最新版本：\(latestRelease)\n\n新版本已经可以安装。"
            )
        case .releaseAvailableButNotInstallable(let current, let latestRelease, let latestInstallable):
            let installable = latestInstallable?.description ?? "无法确认"
            return (
                "发现 DeepSeek Harness 新版本",
                "当前版本：\(current)\n最新版本：\(latestRelease)\nnpm 可安装版本：\(installable)\n\n官方已经发布新版本，但 npm 尚未同步。\n请等待 npm 发布后再更新。"
            )
        case .aheadOfLatest(let current, let latestRelease):
            return (
                "当前版本高于官方最新版本",
                "当前版本：\(current)\n官方最新版本：\(latestRelease)"
            )
        case .unknown, .checking, .failed:
            return (
                "版本检测失败",
                "无法确认官方最新版本或当前版本，请检查网络连接后重试。"
            )
        }
    }
}
