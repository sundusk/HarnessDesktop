import Foundation

/// 一键准备运行环境的结果。
struct RuntimePreparationResult: Equatable, Sendable {
    /// App-owned Node Runtime 版本。
    let nodeVersion: String
    /// Prepare 时固定的 exact Harness version（文档 §13：禁止 @latest）。
    let managedVersion: String
}

/// 一键准备运行环境的执行阶段（UI 进度展示用）。
enum RuntimePreparePhase: Equatable, Sendable {
    case validatingNode
    case validatingVersion
    case preparingCache
    case fetchingPackage
    case verifying
}

/// 一键准备执行器（协议注入，单测不启动真实 Node / npm；文档 §34）。
protocol RuntimePreparationExecuting: Sendable {
    /// 校验 App-owned Node Runtime 并返回版本（未携带 Node → runtimeMissing）。
    func validateNode() async throws -> String
    /// 校验 exact Harness version 字符串（长度 / 字符白名单，防路径穿越）。
    func validateVersion(_ version: String) async throws
    /// 准备私有 npm cache 与 Managed Harness Home。
    func prepareCache() async throws
    /// 拉取 exact Harness package 到 App-owned 目录（npm_config_cache 指向私有目录）。
    func fetchPackage(version: String) async throws
    /// 验证 package 可执行。
    func verifyExecutable(version: String) async throws
}

/// 一键准备状态机（文档 §14）。
///
/// 步骤顺序固定：校验 Node → 校验 exact 版本 → 准备 cache → 拉取包 → 验证可执行。
/// exact version 由 App 侧 `HarnessVersionService` 解析后传入（文档 §13：禁止 @latest）。
/// 任一步失败抛错误，调用方映射为 `HarnessRuntimeFailure`；不产出「半成品已就绪」状态。
struct RuntimePreparation: Sendable {
    var executor: any RuntimePreparationExecuting
    var onPhase: @Sendable (RuntimePreparePhase) -> Void = { _ in }

    func prepare(version: String) async throws -> RuntimePreparationResult {
        onPhase(.validatingNode)
        let nodeVersion = try await executor.validateNode()

        onPhase(.validatingVersion)
        try await executor.validateVersion(version)

        onPhase(.preparingCache)
        try await executor.prepareCache()

        onPhase(.fetchingPackage)
        try await executor.fetchPackage(version: version)

        onPhase(.verifying)
        try await executor.verifyExecutable(version: version)

        return RuntimePreparationResult(nodeVersion: nodeVersion, managedVersion: version)
    }
}
