import Foundation

/// 通知防抖策略（纯逻辑，可测试）。
///
/// 同一 key（session + 事件类型）在 `minInterval` 内只放行一次，
/// 防止快速状态变化造成通知轰炸（规格 22）。
struct NotificationDebouncePolicy: Sendable {
    var minInterval: TimeInterval
    private var lastSentAt: [String: Date] = [:]

    init(minInterval: TimeInterval = 30) {
        self.minInterval = minInterval
    }

    /// 是否允许发送。允许时记录本次时间。
    mutating func shouldSend(key: String, now: Date) -> Bool {
        if let last = lastSentAt[key], now.timeIntervalSince(last) < minInterval {
            return false
        }
        lastSentAt[key] = now
        return true
    }
}
