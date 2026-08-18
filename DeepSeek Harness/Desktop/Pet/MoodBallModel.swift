import Foundation
import SwiftUI
import Observation

// MARK: - HarnessActivityState → 心情球 mood 映射（纯函数，可单测）

/// 把 Domain 层活动状态翻译成心情球的呈现层 mood。
///
/// 与 dsh-moodball 的状态色契约对应：
/// - `idle` → 空闲（蓝）
/// - `running` → `waiting`（正在思考中，绿）
/// - `waitingForApproval` → `authorizing`（等待你的授权，黄）
/// - `waitingForInput` → `questioning`（做出你的抉择，粉）
/// - `error` → `failed`（出错了，红）
/// - `disconnected` → `disconnected`（未连接，灰）
/// - 任务完成的 transient 事件 → `done`（搞定啦，青，短暂庆祝后回 idle）
enum MoodBallMood {
    static func mood(for state: HarnessActivityState) -> String {
        switch state {
        case .disconnected: return "disconnected"
        case .idle: return "idle"
        case .running: return "waiting"
        case .waitingForInput: return "questioning"
        case .waitingForApproval: return "authorizing"
        case .error: return "failed"
        }
    }

    static func label(for mood: String) -> String {
        switch mood {
        case "idle": return "空闲"
        case "waiting": return "正在思考中"
        case "authorizing": return "等待你的授权"
        case "questioning": return "做出你的抉择"
        case "done": return "搞定啦"
        case "failed": return "出错了"
        case "disconnected": return "未连接"
        default: return "未知"
        }
    }

    /// 状态气泡文字：空闲 / 未连接不显示；其余状态显示中文状态名。
    static func bubbleText(for mood: String) -> String? {
        switch mood {
        case "idle", "disconnected":
            return nil
        default:
            return label(for: mood)
        }
    }
}

// MARK: - 心情球模型

/// 心情球呈现层模型：把 `AppCoordinator.activityState`（Domain 层唯一状态出口）
/// 映射成球体外观（mood / 颜色 / 气泡文字），并承载与状态无关的交互状态
/// （双击兴奋晃动、任务完成短暂庆祝）。
///
/// 观察链：SwiftUI 视图访问 `model.mood` 时，Observation 会一路跟踪到
/// coordinator 的 `activityState`（connectionState / reducer），状态变化自动刷新。
@MainActor
@Observable
final class MoodBallModel {
    /// 弱引用协调器，避免保留环（coordinator 持有 model）。
    /// 由 AppCoordinator 在 init 完成后注入。
    weak var coordinator: AppCoordinator?
    let settings: MoodBallSettings

    init(settings: MoodBallSettings) {
        self.settings = settings
    }

    // MARK: 外观（由 coordinator 状态 + 设置派生）

    var mood: String {
        if let transientMood { return transientMood }
        return MoodBallMood.mood(for: coordinator?.activityState ?? .disconnected)
    }

    var moodLabel: String {
        MoodBallMood.label(for: mood)
    }

    var color: Color {
        settings.moodColors[mood] ?? Color(hex: disconnectedHex)
    }

    var ballSize: CGFloat { settings.ballSize }
    var breathingPeriod: Double { settings.breathingSpeed }

    var bubbleText: String? {
        MoodBallMood.bubbleText(for: mood)
    }

    // MARK: 显隐（菜单栏 / 设置页共用同一开关）

    var isBallVisible: Bool { settings.isBallVisible }

    // MARK: 双击兴奋晃动

    /// 双击触发的「兴奋」晃动起点；view 据此计算约 2s 的衰减摆动（超时后忽略）
    private(set) var wiggleTriggeredAt: Date?

    func triggerWiggle() {
        wiggleTriggeredAt = Date()
    }

    // MARK: 任务完成短暂庆祝（transient）

    /// 任务完成时短暂进入 `done`（青色「搞定啦」），`holdDuration` 后回到真实状态。
    /// AppCoordinator 在 drain 到 completion 事件时调用。
    private(set) var transientMood: String?
    private var transientTask: Task<Void, Never>?

    func noteTaskCompletion(holdDuration: TimeInterval = 2.5) {
        transientMood = "done"
        transientTask?.cancel()
        transientTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(holdDuration))
            guard !Task.isCancelled else { return }
            self?.transientMood = nil
        }
    }
}
