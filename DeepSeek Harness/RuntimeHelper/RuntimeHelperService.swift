import Foundation
import os
import Security

private let helperLog = Logger(subsystem: "dev.deepseekharness.DeepSeekHarness", category: "runtime.helper")

/// Runtime Helper XPC 服务（Phase 11：Managed Start / Stop）。
///
/// - 只导出强类型 `RuntimeHelperProtocol`，没有任意命令接口；
/// - 每个新连接先验证调用方（与 Helper 同 team 签名）才接受；
/// - `ManagedProcessSupervisor` 是**长生命周期单例**（跨 RPC 共享活跃 generation 注册）；
/// - `inspectRuntime` / `prepareRuntime` 只读 / 准备；start / stop / status 走 Supervisor。
final class RuntimeHelperService: NSObject, NSXPCListenerDelegate, RuntimeHelperProtocol {
    private let paths: ManagedRuntimePaths?
    /// 长生命周期监督器：start 注册的 generation 供后续 stop / status 使用。
    private let supervisor: ManagedProcessSupervisor
    /// 退出策略：App 断开连接时是否停止 Managed Harness（文档 §19）。
    private var stopOnDisconnect = true

    override init() {
        let paths = ManagedRuntimePaths.makeDefault()
        self.paths = paths
        self.supervisor = ManagedProcessSupervisor(
            launcher: ProcessGroupLauncher(),
            paths: paths ?? ManagedRuntimePaths(rootURL: URL(fileURLWithPath: NSTemporaryDirectory())),
            isPortOccupied: { port in await RuntimeHelperService.isPortReachable(port) }
        )
        super.init()
    }

    // MARK: - NSXPCListenerDelegate

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // 调用方身份验证（文档 §32：Helper 只接受签名主 App 的连接）。
        // 通过连接进程的 pid 读取其签名 Team ID，与 Helper 自己的 Team ID 比较。
        let callerTeamID = Self.teamID(for: newConnection.processIdentifier)
        let ownTeamID = Self.ownTeamID
        guard RuntimeHelperCallerValidator.accepts(callerTeamID: callerTeamID, expectedTeamID: ownTeamID) else {
            helperLog.info("拒绝 XPC 连接：调用方身份不匹配（pid \(newConnection.processIdentifier, privacy: .public)，team \(callerTeamID ?? "nil", privacy: .public)）")
            return false
        }
        // 退出策略（文档 §19）：App 连接断开（退出 / 崩溃）时按策略停止 Managed Harness。
        newConnection.invalidationHandler = { [weak self] in
            guard let self, self.stopOnDisconnect else { return }
            helperLog.info("App 连接断开，按退出策略停止 Managed Harness")
            Task { await self.supervisor.stopActive() }
        }
        newConnection.exportedInterface = NSXPCInterface(with: RuntimeHelperProtocol.self)
        newConnection.exportedObject = self
        newConnection.resume()
        helperLog.info("接受 XPC 连接（team \(ownTeamID ?? "nil", privacy: .public)）")
        return true
    }

    // MARK: - RuntimeHelperProtocol（强类型能力，禁止任意命令）

    func inspectRuntime(withReply reply: @escaping (RuntimeInspectionDTO?, Error?) -> Void) {
        guard let paths else {
            reply(RuntimeInspectionDTO(nodeVersion: nil, runtimeReady: false, managedHomeReady: false), nil)
            return
        }
        let fm = FileManager.default
        let node = BundledNodeRuntimeLocator.bundledNodeURL()
        let runtimeReady = node != nil
        let homeReady = fm.fileExists(atPath: paths.managedHarnessHome.path)
        reply(RuntimeInspectionDTO(
            nodeVersion: nil,
            runtimeReady: runtimeReady,
            managedHomeReady: homeReady
        ), nil)
    }

    func prepareRuntime(version: String, withReply reply: @escaping (RuntimePreparationResultDTO?, Error?) -> Void) {
        guard let paths else {
            reply(nil, runtimeHelperError(.runtimeMissing))
            return
        }
        let preparation = RuntimePreparation(
            executor: ManagedRuntimePreparer(paths: paths, runner: ProcessGroupLauncher())
        )
        Task {
            do {
                let result = try await preparation.prepare(version: version)
                reply(RuntimePreparationResultDTO(
                    nodeVersion: result.nodeVersion,
                    managedVersion: result.managedVersion
                ), nil)
            } catch {
                reply(nil, Self.mapPreparationError(error))
            }
        }
    }

    func startHarness(version: String, port: Int, dataMode: String,
                      withReply reply: @escaping (ManagedHarnessIdentityDTO?, Error?) -> Void) {
        Task {
            do {
                let identity = try await supervisor.start(version: version, port: port)
                reply(ManagedHarnessIdentityDTO(
                    generationID: identity.generationID.uuidString,
                    pid: identity.pid,
                    startedAt: identity.startedAt,
                    version: identity.version,
                    port: identity.port
                ), nil)
            } catch {
                reply(nil, Self.mapStartError(error))
            }
        }
    }

    func stopHarness(identity: ManagedHarnessIdentityDTO,
                     withReply reply: @escaping (Error?) -> Void) {
        guard let generationID = UUID(uuidString: identity.generationID) else {
            reply(runtimeHelperError(.stopFailed))
            return
        }
        let native = ManagedHarnessIdentity(
            generationID: generationID,
            pid: identity.pid,
            startedAt: identity.startedAt,
            version: identity.version,
            port: identity.port
        )
        Task {
            do {
                try await supervisor.stop(identity: native)
                reply(nil)
            } catch {
                reply(runtimeHelperError(.stopFailed))
            }
        }
    }

    func status(identity: ManagedHarnessIdentityDTO,
                withReply reply: @escaping (String?, Error?) -> Void) {
        guard let generationID = UUID(uuidString: identity.generationID) else {
            reply(nil, runtimeHelperError(.helperUnavailable))
            return
        }
        let native = ManagedHarnessIdentity(
            generationID: generationID,
            pid: identity.pid,
            startedAt: identity.startedAt,
            version: identity.version,
            port: identity.port
        )
        reply(supervisor.status(identity: native).wireCode, nil)
    }

    func setStopOnDisconnect(_ stop: Bool, withReply reply: @escaping (Error?) -> Void) {
        stopOnDisconnect = stop
        helperLog.info("退出策略：断开时停止 Managed = \(stop, privacy: .public)")
        reply(nil)
    }

    /// TCP 探测 endpoint 是否被占用（Start 前重新检查 endpoint，文档 §16 / §32）。
    static func isPortReachable(_ port: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard socket >= 0 else {
                continuation.resume(returning: false)
                return
            }
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(port).bigEndian
            addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let result = withUnsafePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    Darwin.connect(socket, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            Darwin.close(socket)
            continuation.resume(returning: result == 0)
        }
    }

    // MARK: - 错误映射

    private static func mapStartError(_ error: Error) -> NSError {
        switch error as? ManagedRuntimeError {
        case .endpointOccupied:
            return runtimeHelperError(.endpointOccupied)
        case .runtimeMissing:
            return runtimeHelperError(.runtimeMissing)
        case .packagePreparationFailed:
            return runtimeHelperError(.packagePreparationFailed)
        case .startFailed:
            return runtimeHelperError(.startFailed)
        case .runtimeIncompatible:
            return runtimeHelperError(.runtimeIncompatible)
        case .stopFailed, nil:
            return runtimeHelperError(.startFailed)
        }
    }

    private static func mapPreparationError(_ error: Error) -> NSError {
        switch error as? ManagedRuntimeError {
        case .runtimeMissing:
            return runtimeHelperError(.runtimeMissing)
        case .runtimeIncompatible:
            return runtimeHelperError(.runtimeIncompatible)
        case .packagePreparationFailed:
            return runtimeHelperError(.packagePreparationFailed)
        case .endpointOccupied, .startFailed, .stopFailed, nil:
            return runtimeHelperError(.helperUnavailable)
        }
    }

    // MARK: - 签名信息读取

    /// Helper 自己的 Team ID（ad-hoc 构建为 nil）。
    private static var ownTeamID: String? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return nil }
        return teamID(of: code)
    }

    /// 从调用方 pid 读取其签名 Team ID。
    /// - Returns: 无签名 / 无法读取 → nil（validator 会因此拒绝连接）。
    static func teamID(for pid: pid_t) -> String? {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: pid] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &code) == errSecSuccess,
              let code else {
            return nil
        }
        return teamID(of: code)
    }

    /// 从 SecCode 读取 Team ID。
    private static func teamID(of code: SecCode) -> String? {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode else {
            return nil
        }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info, let dict = info as? [CFString: Any] else {
            return nil
        }
        return dict[kSecCodeInfoTeamIdentifier] as? String
    }
}
