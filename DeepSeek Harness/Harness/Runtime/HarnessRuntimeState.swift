import Foundation

/// Managed Runtime 状态（2.0 规格 §9 / §14）。
enum ManagedRuntimeStatus: Equatable, Sendable {
    case unknown
    case missing
    case ready
}

/// Harness 运行时状态（2.0 规格 §16）。
///
/// Phase 8 只读阶段不会进入 `preparing` / `starting` / `stopping` 等
/// 有进程变化的状态；这些 case 为后续 Phase（Managed Start / Stop）预留。
enum HarnessRuntimeState: Equatable, Sendable {
    case checking
    case notRunning
    case preparing
    case starting(version: HarnessVersion?)
    case runningExternal(version: HarnessVersion?)
    case runningManaged(version: HarnessVersion?)
    case stopping
    case failed(HarnessRuntimeFailure)
}

/// Runtime Manager 错误模型（2.0 规格 §30）。
///
/// 不携带底层 stderr 全文，只给错误码；诊断细节单独走诊断页。
enum HarnessRuntimeFailure: Error, Equatable, Sendable {
    case helperUnavailable
    case runtimeMissing
    case runtimeIncompatible
    case endpointOccupied
    case packagePreparationFailed
    case startFailed
    case startupTimeout
    case versionVerificationFailed
    case stopFailed
    case updateFailed
    case rollbackFailed
    case networkUnavailable
}

extension HarnessRuntimeFailure {
    /// 面向用户的中文错误码文案（不包含敏感细节）。
    var userMessage: String {
        switch self {
        case .helperUnavailable: return "运行环境助手不可用"
        case .runtimeMissing: return "运行环境未准备"
        case .runtimeIncompatible: return "运行环境不兼容"
        case .endpointOccupied: return "端口已被占用"
        case .packagePreparationFailed: return "Harness 包准备失败"
        case .startFailed: return "启动失败"
        case .startupTimeout: return "启动超时"
        case .versionVerificationFailed: return "版本校验失败"
        case .stopFailed: return "停止失败"
        case .updateFailed: return "更新失败"
        case .rollbackFailed: return "回退失败"
        case .networkUnavailable: return "网络不可用"
        }
    }
}
