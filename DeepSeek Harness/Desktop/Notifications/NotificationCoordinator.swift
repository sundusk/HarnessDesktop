import AppKit
import Foundation
import UserNotifications

/// 通知协调器（规格 22）。
///
/// 场景：
/// - `approval/requested`、`question/requested` → 立即通知；
/// - Agent 从 running → idle（任务完成）→ 通知（前台使用主窗口时抑制，防瞬态抖动）；
/// - `agent-error` → 通知（debounce，防刷屏）。
///
/// 安全：通知正文不包含错误消息 / prompt / 会话内容；session id 只展示截断前缀。
@MainActor
final class NotificationCoordinator {
    private let center: UNUserNotificationCenter
    private let settings: AppSettings
    private var completionDebouncer = NotificationDebouncePolicy(minInterval: 30)
    private var errorDebouncer = NotificationDebouncePolicy(minInterval: 60)

    init(center: UNUserNotificationCenter = .current(), settings: AppSettings) {
        self.center = center
        self.settings = settings
    }

    /// 请求通知授权（应用启动时调用）。
    func requestAuthorization() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    /// 处理 Domain Event（approval / question / error）。
    func handle(event: HarnessDomainEvent) {
        guard settings.notificationsEnabled else { return }
        switch event {
        case .approvalRequested(let sessionID):
            post(title: "需要批准",
                 body: "Session \(Self.shortID(sessionID)) 正在等待操作批准",
                 identifier: "approval-\(sessionID)")
        case .questionRequested(let sessionID):
            post(title: "等待回答",
                 body: "Session \(Self.shortID(sessionID)) 向你提出了问题",
                 identifier: "question-\(sessionID)")
        case .agentError(let sessionID, _):
            // error 通知不带错误内容（可能含敏感信息），且按 session debounce。
            guard errorDebouncer.shouldSend(key: sessionID, now: Date()) else { return }
            post(title: "任务出错",
                 body: "Session \(Self.shortID(sessionID)) 发生错误",
                 identifier: "error-\(sessionID)")
        default:
            break
        }
    }

    /// 处理 transient 完成事件（running → idle）。
    func handleCompletion(_ completion: HarnessCompletionEvent) {
        guard settings.notificationsEnabled else { return }
        // 前台使用主窗口时不反复发送完成通知（规格 22）。
        guard !NSApp.isActive else { return }
        guard completionDebouncer.shouldSend(key: completion.sessionID, now: completion.timestamp) else { return }
        post(title: "任务完成",
             body: "Session \(Self.shortID(completion.sessionID)) 已完成",
             identifier: "completion-\(completion.sessionID)")
    }

    private func post(title: String, body: String, identifier: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        center.add(request)
    }

    private static func shortID(_ id: String) -> String {
        String(id.prefix(8))
    }
}
