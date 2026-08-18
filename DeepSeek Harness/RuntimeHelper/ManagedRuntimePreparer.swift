import Foundation

/// Helper 侧准备错误（服务层映射为 XPC 错误码；不携带敏感信息）。
enum ManagedRuntimeError: Error, Equatable, Sendable {
    case runtimeMissing
    case runtimeIncompatible
    case packagePreparationFailed
}

/// 一键准备执行器（Helper 侧真实实现；文档 §14 / §15）。
///
/// - 使用 App-owned Node / npm + App-owned npm cache + exact version；
/// - 不修改父 Shell 环境、不写全局 npm config；
/// - stdout / stderr 有界（`ProcessRunner`）。
struct ManagedRuntimePreparer: RuntimePreparationExecuting {
    var paths: ManagedRuntimePaths
    var runner: any ManagedProcessRunning
    var nodeLocator: @Sendable () -> URL? = { BundledNodeRuntimeLocator.bundledNodeURL() }

    // MARK: - RuntimePreparationExecuting

    func validateNode() async throws -> String {
        guard let node = nodeLocator() else {
            throw ManagedRuntimeError.runtimeMissing
        }
        let result = try await runner.run(
            executable: node,
            arguments: ["--version"],
            environment: [:],
            currentDirectory: nil
        )
        guard result.exitCode == 0 else {
            throw ManagedRuntimeError.runtimeIncompatible
        }
        let version = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty, version.count <= 64 else {
            throw ManagedRuntimeError.runtimeIncompatible
        }
        return version
    }

    func validateVersion(_ version: String) async throws {
        guard ManagedPackageCache.isSafeVersionComponent(version) else {
            throw ManagedRuntimeError.packagePreparationFailed
        }
    }

    func prepareCache() async throws {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: paths.npmCacheDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: paths.managedHarnessHome, withIntermediateDirectories: true)
            try fm.createDirectory(at: paths.runtimeDir.appendingPathComponent("state", isDirectory: true),
                                   withIntermediateDirectories: true)
        } catch {
            throw ManagedRuntimeError.packagePreparationFailed
        }
    }

    func fetchPackage(version: String) async throws {
        guard let node = nodeLocator() else {
            throw ManagedRuntimeError.runtimeMissing
        }
        guard let packageDir = ManagedPackageCache.packageDir(for: paths, version: version) else {
            throw ManagedRuntimeError.packagePreparationFailed
        }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: packageDir, withIntermediateDirectories: true)
        } catch {
            throw ManagedRuntimeError.packagePreparationFailed
        }
        // 概念命令（非 shell）：<node>/bin/npm install --prefix <packageDir> @deepseek-ai/dsh@<exact>
        // 使用 App-owned npm（随 Node 一同携带）与私有 cache 环境。
        let npm = node.deletingLastPathComponent().appendingPathComponent("npm")
        let args = ["install", "--prefix", packageDir.path,
                    "--no-save", "--no-audit", "--no-fund",
                    "@deepseek-ai/dsh@\(version)"]
        let result = try await runner.run(
            executable: npm,
            arguments: args,
            environment: ManagedPackageCache.environment(for: paths),
            currentDirectory: packageDir
        )
        guard result.exitCode == 0 else {
            throw ManagedRuntimeError.packagePreparationFailed
        }
    }

    func verifyExecutable(version: String) async throws {
        guard let packageDir = ManagedPackageCache.packageDir(for: paths, version: version) else {
            throw ManagedRuntimeError.packagePreparationFailed
        }
        // 验证官方 bin 入口存在且可执行（package.json bin.dsh）。
        let bin = packageDir.appendingPathComponent("node_modules/.bin/dsh", isDirectory: false)
        let fm = FileManager.default
        guard fm.fileExists(atPath: bin.path) else {
            throw ManagedRuntimeError.packagePreparationFailed
        }
    }
}
