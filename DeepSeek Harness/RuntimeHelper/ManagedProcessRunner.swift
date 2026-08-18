import Foundation

/// 子进程运行结果（stdout / stderr 有界，文档 §32：防止内存无限增长）。
struct ManagedProcessResult: Equatable, Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

/// 子进程运行器（协议注入，单测不启动真实 Node / npm）。
protocol ManagedProcessRunning: Sendable {
    /// 运行可执行文件（非 shell）。参数 / 环境变量来自强类型调用方，不允许任意命令。
    func run(executable: URL, arguments: [String],
             environment: [String: String], currentDirectory: URL?) async throws -> ManagedProcessResult
}

/// 真实实现：`Process` + 有界输出缓冲（文档 §32）。
///
/// 仅用于 Helper 启动 App-owned Node / npm；App 主进程不直接启动进程。
struct ProcessRunner: ManagedProcessRunning {
    /// stdout / stderr 最大捕获字节（防止子进程输出无限增长）。
    static let maxOutputBytes = 64 * 1024

    func run(executable: URL, arguments: [String],
             environment: [String: String], currentDirectory: URL?) async throws -> ManagedProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            var env = ProcessInfo.processInfo.environment
            for (key, value) in environment {
                env[key] = value
            }
            process.environment = env
            if let currentDirectory {
                process.currentDirectoryURL = currentDirectory
            }

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }

            // 有界读取：边读边丢弃超出部分。
            let stdout = Self.boundedRead(from: stdoutPipe.fileHandleForReading)
            let stderr = Self.boundedRead(from: stderrPipe.fileHandleForReading)

            process.terminationHandler = { process in
                continuation.resume(returning: ManagedProcessResult(
                    exitCode: process.terminationStatus,
                    stdout: stdout.value,
                    stderr: stderr.value
                ))
            }
        }
    }

    /// 有界读取：最多保留 `maxOutputBytes`，其余丢弃。
    private static func boundedRead(from handle: FileHandle) -> (value: String, discarded: Bool) {
        let data = handle.readDataToEndOfFile()
        let bounded = data.count > maxOutputBytes ? data.prefix(maxOutputBytes) : data
        return (String(data: bounded, encoding: .utf8) ?? "", data.count > maxOutputBytes)
    }
}
