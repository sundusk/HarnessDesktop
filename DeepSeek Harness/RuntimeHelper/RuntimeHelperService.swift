import Foundation
import os
import Security

private let helperLog = Logger(subsystem: "dev.deepseekharness.DeepSeekHarness", category: "runtime.helper")

/// Runtime Helper XPC 服务（Phase 9 骨架；文档 §6 / §9 / §42）。
///
/// - 只导出强类型 `RuntimeHelperProtocol`，没有任意命令接口；
/// - 每个新连接先验证调用方（与 Helper 同 team 签名）才接受；
/// - `inspectRuntime` 只读；start / stop / status 在 Phase 10/11 实现前返回
///   `notImplemented`（骨架行为，不启动任何进程）。
final class RuntimeHelperService: NSObject, NSXPCListenerDelegate, RuntimeHelperProtocol {

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
        newConnection.exportedInterface = NSXPCInterface(with: RuntimeHelperProtocol.self)
        newConnection.exportedObject = self
        newConnection.resume()
        helperLog.info("接受 XPC 连接（team \(ownTeamID ?? "nil", privacy: .public)）")
        return true
    }

    // MARK: - RuntimeHelperProtocol（强类型能力，禁止任意命令）

    func inspectRuntime(withReply reply: @escaping (RuntimeInspectionDTO?, Error?) -> Void) {
        // Phase 9 骨架：Managed Runtime 尚未准备（Phase 10 实现 App-owned Node Runtime）。
        reply(RuntimeInspectionDTO(nodeVersion: nil, runtimeReady: false, managedHomeReady: false), nil)
    }

    func startHarness(version: String, port: Int, dataMode: String,
                      withReply reply: @escaping (ManagedHarnessIdentityDTO?, Error?) -> Void) {
        // Phase 11 实现 Managed Start；骨架阶段不启动任何进程。
        reply(nil, runtimeHelperError(.notImplemented, message: "Managed Start 将在后续阶段提供"))
    }

    func stopHarness(identity: ManagedHarnessIdentityDTO,
                     withReply reply: @escaping (Error?) -> Void) {
        reply(runtimeHelperError(.notImplemented, message: "Managed Stop 将在后续阶段提供"))
    }

    func status(identity: ManagedHarnessIdentityDTO,
                withReply reply: @escaping (String?, Error?) -> Void) {
        reply(nil, runtimeHelperError(.notImplemented, message: "Managed Status 将在后续阶段提供"))
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
