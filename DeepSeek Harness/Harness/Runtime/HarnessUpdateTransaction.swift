import Foundation

// MARK: - Update / Rollback 事务（文档 §20 / §21 / §22 / §23）

/// 更新 / 回退事务的进行阶段（UI 进度 / 日志用）。
enum HarnessUpdatePhase: Equatable, Sendable {
    case preparingCandidate
    case stoppingCurrent
    case launchingCandidate
    case verifying
    case committing
    case restoringPrevious
}

/// 更新 / 回退事务结果。
enum HarnessUpdateResult: Equatable, Sendable {
    /// 提交成功（新版本已启动并通过版本校验）。
    case committed(version: String)
    /// 候选失败，已恢复 fallback 版本。
    case restored(version: String)
    /// 失败（候选准备失败 / 停止失败 / 恢复也失败）。
    case failed(HarnessRuntimeFailure)
}

/// 更新事务执行器（协议注入，单测不启动真实进程；文档 §34）。
protocol HarnessUpdateExecuting: Sendable {
    /// 准备候选版本（exact package；版本隔离目录，不触碰当前版本）。
    func prepareCandidate(version: String) async throws
    /// 停止当前 Managed Harness（未运行则无操作）。
    func stopCurrent() async throws
    /// 启动指定版本（更新候选 / 回退版本 / 失败恢复）。
    func launchCandidate(version: String) async throws -> ManagedHarnessIdentity
    /// 等待 loopback ready 后校验报告版本 == expected。
    func verifyVersion(expected: String) async -> Bool
}

/// 更新事务状态机（文档 §23：事务化语义）。
///
/// 正确顺序：
/// ```text
/// PrepareCandidate(latest) → success → StopCurrent → LaunchCandidate
///   → health check（版本校验）→ success → Commit managedVersion
/// ```
/// 候选准备失败：当前版本不受影响（.failed，不进入后续步骤）；
/// 候选启动失败 / 版本不符：尝试恢复 fallback（= 更新前的 working version）；
/// 恢复也失败：.failed（明确错误，不删除任何版本记录）。
struct HarnessUpdateTransaction: Sendable {
    var executor: any HarnessUpdateExecuting
    var onPhase: @Sendable (HarnessUpdatePhase) -> Void = { _ in }

    /// 更新：`current` 为当前 working 版本，`candidate` 为目标版本。
    /// 成功后返回 .committed(candidate)；失败恢复返回 .restored(current)。
    func update(from current: String, candidate: String) async -> HarnessUpdateResult {
        onPhase(.preparingCandidate)
        do {
            try await executor.prepareCandidate(version: candidate)
        } catch {
            // 候选准备失败：当前版本完全不受影响（文档 §23）
            return .failed(.packagePreparationFailed)
        }

        onPhase(.stoppingCurrent)
        do {
            try await executor.stopCurrent()
        } catch {
            return .failed(.stopFailed)
        }

        onPhase(.launchingCandidate)
        do {
            _ = try await executor.launchCandidate(version: candidate)
        } catch {
            return await restore(version: current)
        }

        onPhase(.verifying)
        guard await executor.verifyVersion(expected: candidate) else {
            return await restore(version: current)
        }

        onPhase(.committing)
        return .committed(version: candidate)
    }

    /// 回退：`previous` 为目标版本（文档 §22）。
    /// 回退启动失败 → .rollbackFailed（当前记录保留，可「恢复到 X」）。
    func rollback(from current: String, previous: String) async -> HarnessUpdateResult {
        onPhase(.stoppingCurrent)
        do {
            try await executor.stopCurrent()
        } catch {
            return .failed(.stopFailed)
        }

        onPhase(.launchingCandidate)
        do {
            _ = try await executor.launchCandidate(version: previous)
        } catch {
            return .failed(.rollbackFailed)
        }

        onPhase(.verifying)
        guard await executor.verifyVersion(expected: previous) else {
            return .failed(.rollbackFailed)
        }

        onPhase(.committing)
        return .committed(version: previous)
    }

    /// 候选失败 → 恢复 fallback（更新前的 working 版本）。
    private func restore(version: String) async -> HarnessUpdateResult {
        onPhase(.restoringPrevious)
        do {
            _ = try await executor.launchCandidate(version: version)
            return .restored(version: version)
        } catch {
            return .failed(.updateFailed)
        }
    }
}
