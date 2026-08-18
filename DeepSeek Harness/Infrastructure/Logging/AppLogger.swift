import Foundation
import os

/// 统一 Logger。
///
/// 安全要求：绝不记录 API Key、凭据、Prompt 全文、会话内容、用户文件内容、
/// 完整环境变量、npm auth、DSH secrets。
/// 只记录连接状态、版本、错误类型、event type、session ID（必要时截断）、PID / port。
enum AppLogger {
    static let app = Logger(subsystem: "dev.deepseekharness.DeepSeekHarness", category: "app")
    static let discovery = Logger(subsystem: "dev.deepseekharness.DeepSeekHarness", category: "discovery")
    static let webview = Logger(subsystem: "dev.deepseekharness.DeepSeekHarness", category: "webview")
    static let compatibility = Logger(subsystem: "dev.deepseekharness.DeepSeekHarness", category: "compatibility")
    static let activity = Logger(subsystem: "dev.deepseekharness.DeepSeekHarness", category: "activity")
    static let pet = Logger(subsystem: "dev.deepseekharness.DeepSeekHarness", category: "pet")
    // 2.0 规格 §31：Runtime Manager 新增分类。
    static let runtimeEnvironment = Logger(subsystem: "dev.deepseekharness.DeepSeekHarness", category: "runtime.environment")
    static let runtimeHelper = Logger(subsystem: "dev.deepseekharness.DeepSeekHarness", category: "runtime.helper")
    static let runtimeProcess = Logger(subsystem: "dev.deepseekharness.DeepSeekHarness", category: "runtime.process")
    static let version = Logger(subsystem: "dev.deepseekharness.DeepSeekHarness", category: "runtime.version")
    static let runtimeUpdate = Logger(subsystem: "dev.deepseekharness.DeepSeekHarness", category: "runtime.update")
    static let runtimeRollback = Logger(subsystem: "dev.deepseekharness.DeepSeekHarness", category: "runtime.rollback")
}
