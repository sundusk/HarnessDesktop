import Foundation

// MARK: - Runtime Manager 原生模型（Phase 9 骨架；文档 §6 / §17）

/// Managed Harness 身份（文档 §17：不只存 PID）。
///
/// 停止 / 状态查询时必须同时验证 generationID + pid，避免 PID reuse 误杀。
struct ManagedHarnessIdentity: Codable, Equatable, Sendable {
    let generationID: UUID
    let pid: Int32
    let startedAt: Date
    let version: String
    let port: Int
}

/// Managed Harness 进程状态。
enum ManagedHarnessProcessStatus: Equatable, Sendable {
    case running(pid: Int32)
    case stopped
    case exited(code: Int32)

    /// XPC 传输用的字符串码。
    var wireCode: String {
        switch self {
        case .running: return "running"
        case .stopped: return "stopped"
        case .exited: return "exited"
        }
    }

    static func fromWireCode(_ code: String, pid: Int32) -> ManagedHarnessProcessStatus? {
        switch code {
        case "running": return .running(pid: pid)
        case "stopped": return .stopped
        case "exited": return .exited(code: pid)
        default: return nil
        }
    }
}

/// Managed 数据模式（文档 §8.2：V1 只实现隔离模式）。
enum ManagedDataMode: String, Equatable, Sendable {
    /// 隔离的 Managed Harness 数据目录（推荐，V1 唯一模式）。
    case isolated = "isolated"
    /// 使用默认 Harness 数据目录（高级；V1 不实现）。
    case `default` = "default"
}

/// 运行环境检查结果。
struct RuntimeInspection: Equatable, Sendable {
    /// App-owned Node Runtime 版本（未准备为 nil）。
    var nodeVersion: String?
    /// App-owned Node Runtime 是否就绪。
    var runtimeReady: Bool
    /// Managed Harness Home（隔离数据目录）是否就绪。
    var managedHomeReady: Bool

    static let missing = RuntimeInspection(nodeVersion: nil, runtimeReady: false, managedHomeReady: false)
}

// MARK: - 强类型能力协议（文档 §6：禁止 runCommand / runShell / execute）

/// Runtime Manager 能力协议（App 侧视图）。
///
/// 只暴露强类型能力；**没有任何任意命令 / 任意 shell / 任意可执行路径 / 任意环境字典**。
protocol HarnessRuntimeManaging: Sendable {
    /// 检查运行环境（只读）。
    func inspectRuntime() async throws -> RuntimeInspection

    /// 一键准备运行环境（App-owned Node Runtime + 私有 npm cache + Managed Harness Home）。
    /// - Parameter version: 要固定的 exact Harness version（App 侧解析，文档 §13：禁止 @latest）。
    func prepareRuntime(version: String) async throws -> RuntimePreparationResult

    /// 启动 Managed Harness。
    func startHarness(version: String, port: Int, dataMode: ManagedDataMode) async throws -> ManagedHarnessIdentity

    /// 停止 Managed Harness（按 generation ownership 验证）。
    func stopHarness(identity: ManagedHarnessIdentity) async throws

    /// 查询 Managed Harness 进程状态。
    func status(identity: ManagedHarnessIdentity) async throws -> ManagedHarnessProcessStatus

    /// Helper 健康检查。
    func healthCheck() async -> Bool
}
