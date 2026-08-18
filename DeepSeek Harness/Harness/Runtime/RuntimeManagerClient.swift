import Foundation

// MARK: - Runtime Helper 传输边界（可注入；文档 §34 协议化）

/// Helper 传输层协议：客户端与 XPC 传输解耦，单测用 fake transport。
protocol RuntimeHelperTransporting: Sendable {
    func inspectRuntime() async throws -> RuntimeInspection
    func prepareRuntime(version: String) async throws -> RuntimePreparationResult
    func startHarness(version: String, port: Int, dataMode: ManagedDataMode) async throws -> ManagedHarnessIdentity
    func stopHarness(identity: ManagedHarnessIdentity) async throws
    func status(identity: ManagedHarnessIdentity) async throws -> ManagedHarnessProcessStatus
    func healthCheck() async -> Bool
}

// MARK: - NSXPCConnection 传输实现

/// 基于 XPC 的 Helper 传输（Phase 9 骨架）。
///
/// 说明（架构决策，见 ARCHITECTURE.md ADR-007）：
/// - Helper 是内嵌 XPC Service（`Contents/XPCServices/RuntimeHelper.xpc`）；
/// - XPC 要求 App 与 Helper 使用**同一 team 签名**。当前工程为可移植性使用
///   ad-hoc 签名（无 team）——此时连接失败，`inspectRuntime()` 抛出
///   `HarnessRuntimeFailure.helperUnavailable`，App 优雅降级（不影响 Web Core）；
///   正式分发构建（同一 Developer ID 签名）时连接正常工作。
final class NSXPCRuntimeHelperTransport: RuntimeHelperTransporting, @unchecked Sendable {
    private let serviceName: String
    private let lock = NSLock()
    private var connection: NSXPCConnection?

    init(serviceName: String = "dev.deepseekharness.DeepSeekHarness.RuntimeHelper") {
        self.serviceName = serviceName
    }

    deinit {
        lock.lock()
        connection?.invalidate()
        connection = nil
        lock.unlock()
    }

    /// 惰性创建连接（首次调用时）。
    private func makeConnection() -> NSXPCConnection {
        lock.withLock {
            if let connection { return connection }
            let newConnection = NSXPCConnection(serviceName: serviceName)
            newConnection.remoteObjectInterface = NSXPCInterface(with: RuntimeHelperProtocol.self)
            newConnection.resume()
            connection = newConnection
            return newConnection
        }
    }

    func inspectRuntime() async throws -> RuntimeInspection {
        try await call { (continuation: CheckedContinuation<RuntimeInspection, Error>) in
            let proxy = self.proxyWithHandler { error in
                continuation.resume(throwing: Self.mapError(error))
            }
            proxy.inspectRuntime { dto, error in
                if let error {
                    continuation.resume(throwing: Self.mapError(error))
                    return
                }
                guard let dto else {
                    continuation.resume(throwing: HarnessRuntimeFailure.helperUnavailable)
                    return
                }
                continuation.resume(returning: RuntimeInspection(
                    nodeVersion: dto.nodeVersion,
                    runtimeReady: dto.runtimeReady,
                    managedHomeReady: dto.managedHomeReady
                ))
            }
        }
    }

    func prepareRuntime(version: String) async throws -> RuntimePreparationResult {
        try await call { (continuation: CheckedContinuation<RuntimePreparationResult, Error>) in
            let proxy = self.proxyWithHandler { error in
                continuation.resume(throwing: Self.mapError(error))
            }
            proxy.prepareRuntime(version: version) { dto, error in
                if let error {
                    continuation.resume(throwing: Self.mapError(error))
                    return
                }
                guard let dto else {
                    continuation.resume(throwing: HarnessRuntimeFailure.packagePreparationFailed)
                    return
                }
                continuation.resume(returning: RuntimePreparationResult(
                    nodeVersion: dto.nodeVersion,
                    managedVersion: dto.managedVersion
                ))
            }
        }
    }

    func startHarness(version: String, port: Int, dataMode: ManagedDataMode) async throws -> ManagedHarnessIdentity {
        try await call { (continuation: CheckedContinuation<ManagedHarnessIdentity, Error>) in
            let proxy = self.proxyWithHandler { error in
                continuation.resume(throwing: Self.mapError(error))
            }
            proxy.startHarness(version: version, port: port, dataMode: dataMode.rawValue) { dto, error in
                if let error {
                    continuation.resume(throwing: Self.mapError(error))
                    return
                }
                guard let dto, let generationID = UUID(uuidString: dto.generationID) else {
                    continuation.resume(throwing: HarnessRuntimeFailure.startFailed)
                    return
                }
                continuation.resume(returning: ManagedHarnessIdentity(
                    generationID: generationID,
                    pid: dto.pid,
                    startedAt: dto.startedAt,
                    version: dto.version,
                    port: dto.port
                ))
            }
        }
    }

    func stopHarness(identity: ManagedHarnessIdentity) async throws {
        try await call { (continuation: CheckedContinuation<Void, Error>) in
            let proxy = self.proxyWithHandler { error in
                continuation.resume(throwing: Self.mapError(error))
            }
            proxy.stopHarness(identity: Self.dto(from: identity)) { error in
                if let error {
                    continuation.resume(throwing: Self.mapError(error))
                    return
                }
                continuation.resume(returning: ())
            }
        }
    }

    func status(identity: ManagedHarnessIdentity) async throws -> ManagedHarnessProcessStatus {
        try await call { (continuation: CheckedContinuation<ManagedHarnessProcessStatus, Error>) in
            let proxy = self.proxyWithHandler { error in
                continuation.resume(throwing: Self.mapError(error))
            }
            proxy.status(identity: Self.dto(from: identity)) { code, error in
                if let error {
                    continuation.resume(throwing: Self.mapError(error))
                    return
                }
                guard let code, let status = ManagedHarnessProcessStatus.fromWireCode(code, pid: identity.pid) else {
                    continuation.resume(throwing: HarnessRuntimeFailure.helperUnavailable)
                    return
                }
                continuation.resume(returning: status)
            }
        }
    }

    func healthCheck() async -> Bool {
        (try? await inspectRuntime()) != nil
    }

    // MARK: - Private

    /// XPC 调用通用骨架：连接失败 / 身份不匹配时错误处理器会恢复 continuation（不挂起）。
    private func call<T>(_ body: @escaping (CheckedContinuation<T, Error>) -> Void) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            body(continuation)
        }
    }

    /// 远程代理；连接建立失败时通过 errorHandler 恢复调用方。
    private func proxyWithHandler(_ errorHandler: @escaping (Error) -> Void) -> RuntimeHelperProtocol {
        let connection = self.makeConnection()
        let proxy = connection.remoteObjectProxyWithErrorHandler(errorHandler)
        // remoteObjectInterface 已固定为 RuntimeHelperProtocol，代理必然符合该 @objc 协议；
        // force cast 在此是静态保证的（连接建立失败走 errorHandler，不会走到这里返回非协议代理）。
        return proxy as! RuntimeHelperProtocol
    }

    private static func dto(from identity: ManagedHarnessIdentity) -> ManagedHarnessIdentityDTO {
        ManagedHarnessIdentityDTO(
            generationID: identity.generationID.uuidString,
            pid: identity.pid,
            startedAt: identity.startedAt,
            version: identity.version,
            port: identity.port
        )
    }

    /// XPC 错误 → `HarnessRuntimeFailure`（只映射错误码，不携带敏感信息）。
    static func mapError(_ error: Error) -> HarnessRuntimeFailure {
        let nsError = error as NSError
        guard nsError.domain == RuntimeHelperErrorDomain else {
            // 连接建立失败（无签名 / Helper 不存在 / XPC 拒绝）→ helperUnavailable
            return .helperUnavailable
        }
        switch nsError.code {
        case RuntimeHelperErrorCode.callerNotAuthorized.rawValue: return .helperUnavailable
        case RuntimeHelperErrorCode.runtimeMissing.rawValue: return .runtimeMissing
        case RuntimeHelperErrorCode.runtimeIncompatible.rawValue: return .runtimeIncompatible
        case RuntimeHelperErrorCode.endpointOccupied.rawValue: return .endpointOccupied
        case RuntimeHelperErrorCode.startFailed.rawValue: return .startFailed
        case RuntimeHelperErrorCode.stopFailed.rawValue: return .stopFailed
        case RuntimeHelperErrorCode.updateFailed.rawValue: return .updateFailed
        case RuntimeHelperErrorCode.rollbackFailed.rawValue: return .rollbackFailed
        case RuntimeHelperErrorCode.packagePreparationFailed.rawValue: return .packagePreparationFailed
        default: return .helperUnavailable
        }
    }
}

// MARK: - Runtime Manager 客户端

/// Runtime Manager 客户端：`HarnessRuntimeManaging` 的默认实现。
///
/// 通过可注入的 `RuntimeHelperTransporting`（生产 = XPC）访问 Helper；
/// 单测注入 fake transport，不触碰真实 XPC（规格 §34：单测禁止真正启动 Node / npm / Harness）。
final class RuntimeManagerClient: HarnessRuntimeManaging, @unchecked Sendable {
    private let transport: any RuntimeHelperTransporting

    init(transport: any RuntimeHelperTransporting = NSXPCRuntimeHelperTransport()) {
        self.transport = transport
    }

    func inspectRuntime() async throws -> RuntimeInspection {
        try await transport.inspectRuntime()
    }

    func prepareRuntime(version: String) async throws -> RuntimePreparationResult {
        try await transport.prepareRuntime(version: version)
    }

    func startHarness(version: String, port: Int, dataMode: ManagedDataMode) async throws -> ManagedHarnessIdentity {
        // Phase 9 骨架：启动流程由 Phase 11（Managed Start / Stop）实现。
        throw HarnessRuntimeFailure.startFailed
    }

    func stopHarness(identity: ManagedHarnessIdentity) async throws {
        try await transport.stopHarness(identity: identity)
    }

    func status(identity: ManagedHarnessIdentity) async throws -> ManagedHarnessProcessStatus {
        try await transport.status(identity: identity)
    }

    func healthCheck() async -> Bool {
        await transport.healthCheck()
    }
}
