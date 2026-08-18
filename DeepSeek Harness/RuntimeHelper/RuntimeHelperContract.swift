import Foundation

// MARK: - XPC 契约（Phase 9 骨架，文档 §6 / §42）
//
// 本文件同时编译进 App target 与 RuntimeHelper target：
// - App 侧 `NSXPCRuntimeHelperTransport` 用它建立 NSXPCConnection；
// - Helper 侧 `RuntimeHelperService` 用它导出实现。
//
// 安全要求（文档 §6 / §32）：
// - 只有强类型能力方法（inspect / start / stop / status），
//   **禁止** runCommand / runShell / execute(arguments:) 等任意命令接口；
// - 参数全部为强类型 DTO / 标量，不存在任意路径 / 任意环境变量 / 任意命令行。

/// XPC 错误域。
public let RuntimeHelperErrorDomain = "dev.deepseekharness.RuntimeHelper"

/// XPC 错误码（客户端映射到 `HarnessRuntimeFailure`）。
public enum RuntimeHelperErrorCode: Int {
    case helperUnavailable = 1
    case callerNotAuthorized = 2
    case runtimeMissing = 3
    case runtimeIncompatible = 4
    case endpointOccupied = 5
    case startFailed = 6
    case stopFailed = 7
    case updateFailed = 8
    case rollbackFailed = 9
    case notImplemented = 10
    case packagePreparationFailed = 11
}

/// 运行环境检查结果 DTO（`inspectRuntime` 返回值）。
@objc(RuntimeInspectionDTO)
public final class RuntimeInspectionDTO: NSObject, NSSecureCoding {
    public static var supportsSecureCoding: Bool { true }

    public let nodeVersion: String?
    /// App-owned Node Runtime 是否就绪。
    public let runtimeReady: Bool
    /// Managed Harness Home（隔离数据目录）是否就绪。
    public let managedHomeReady: Bool

    public init(nodeVersion: String?, runtimeReady: Bool, managedHomeReady: Bool) {
        self.nodeVersion = nodeVersion
        self.runtimeReady = runtimeReady
        self.managedHomeReady = managedHomeReady
        super.init()
    }

    public required init?(coder: NSCoder) {
        nodeVersion = coder.decodeObject(of: NSString.self, forKey: "nodeVersion") as String?
        runtimeReady = coder.decodeBool(forKey: "runtimeReady")
        managedHomeReady = coder.decodeBool(forKey: "managedHomeReady")
    }

    public func encode(with coder: NSCoder) {
        coder.encode(nodeVersion as NSString?, forKey: "nodeVersion")
        coder.encode(runtimeReady, forKey: "runtimeReady")
        coder.encode(managedHomeReady, forKey: "managedHomeReady")
    }
}

/// Managed Harness 身份 DTO（文档 §17：不只存 PID）。
@objc(ManagedHarnessIdentityDTO)
public final class ManagedHarnessIdentityDTO: NSObject, NSSecureCoding {
    public static var supportsSecureCoding: Bool { true }

    /// generation token（UUID 字符串）。
    public let generationID: String
    public let pid: Int32
    public let startedAt: Date
    public let version: String
    public let port: Int

    public init(generationID: String, pid: Int32, startedAt: Date, version: String, port: Int) {
        self.generationID = generationID
        self.pid = pid
        self.startedAt = startedAt
        self.version = version
        self.port = port
        super.init()
    }

    public required init?(coder: NSCoder) {
        guard let generationID = coder.decodeObject(of: NSString.self, forKey: "generationID") as String?,
              let startedAt = coder.decodeObject(of: NSDate.self, forKey: "startedAt") as Date?,
              let version = coder.decodeObject(of: NSString.self, forKey: "version") as String? else {
            return nil
        }
        self.generationID = generationID
        self.startedAt = startedAt
        self.version = version
        self.pid = coder.decodeInt32(forKey: "pid")
        self.port = coder.decodeInteger(forKey: "port")
    }

    public func encode(with coder: NSCoder) {
        coder.encode(generationID as NSString, forKey: "generationID")
        coder.encode(pid, forKey: "pid")
        coder.encode(startedAt, forKey: "startedAt")
        coder.encode(version as NSString, forKey: "version")
        coder.encode(port, forKey: "port")
    }
}

/// 一键准备结果 DTO（`prepareRuntime` 返回值）。
@objc(RuntimePreparationResultDTO)
public final class RuntimePreparationResultDTO: NSObject, NSSecureCoding {
    public static var supportsSecureCoding: Bool { true }

    public let nodeVersion: String
    public let managedVersion: String

    public init(nodeVersion: String, managedVersion: String) {
        self.nodeVersion = nodeVersion
        self.managedVersion = managedVersion
        super.init()
    }

    public required init?(coder: NSCoder) {
        guard let nodeVersion = coder.decodeObject(of: NSString.self, forKey: "nodeVersion") as String?,
              let managedVersion = coder.decodeObject(of: NSString.self, forKey: "managedVersion") as String? else {
            return nil
        }
        self.nodeVersion = nodeVersion
        self.managedVersion = managedVersion
    }

    public func encode(with coder: NSCoder) {
        coder.encode(nodeVersion as NSString, forKey: "nodeVersion")
        coder.encode(managedVersion as NSString, forKey: "managedVersion")
    }
}

/// Helper XPC 接口（强类型白名单，禁止任意命令）。
@objc(RuntimeHelperProtocol)
public protocol RuntimeHelperProtocol {
    /// 检查运行环境（只读）。
    func inspectRuntime(withReply reply: @escaping (RuntimeInspectionDTO?, Error?) -> Void)

    /// 一键准备运行环境（App-owned Node Runtime + 私有 npm cache + Managed Harness Home）。
    /// exact version 由 App 侧解析后传入（文档 §13：禁止 @latest）。
    func prepareRuntime(version: String, withReply reply: @escaping (RuntimePreparationResultDTO?, Error?) -> Void)

    /// 启动 Managed Harness（固定 exact version）。
    func startHarness(version: String, port: Int, dataMode: String,
                      withReply reply: @escaping (ManagedHarnessIdentityDTO?, Error?) -> Void)

    /// 停止 Managed Harness（必须验证 generation ownership）。
    func stopHarness(identity: ManagedHarnessIdentityDTO,
                     withReply reply: @escaping (Error?) -> Void)

    /// 查询 Managed Harness 进程状态。
    func status(identity: ManagedHarnessIdentityDTO,
                withReply reply: @escaping (String?, Error?) -> Void)

    /// 设置「App 断开时是否停止 Managed Harness」（文档 §19 退出策略）。
    /// App 启动时按设置调用；连接失效时 Helper 据此决定是否停止活跃 Managed 进程。
    func setStopOnDisconnect(_ stop: Bool, withReply reply: @escaping (Error?) -> Void)
}

/// 由错误码构造 XPC 错误（不携带任何敏感信息）。
public func runtimeHelperError(_ code: RuntimeHelperErrorCode, message: String? = nil) -> NSError {
    NSError(domain: RuntimeHelperErrorDomain, code: code.rawValue,
            userInfo: message.map { [NSLocalizedDescriptionKey: $0] })
}
