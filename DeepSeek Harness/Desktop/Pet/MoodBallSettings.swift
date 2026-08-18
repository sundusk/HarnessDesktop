import Foundation
import SwiftUI
import Observation

// MARK: - 心情球状态 → 颜色契约
//
// 颜色契约与 dsh-moodball 保持一致（蓝=空闲 / 绿=思考中 / 黄=等待授权 /
// 粉=等待选择 / 青=搞定 / 红=出错 / 灰=未连接），可由设置面板自定义。
// mood 词汇是 harnessDesktop 自己的呈现层词汇（由 MoodBallModel 从
// HarnessActivityState 映射而来），与上游 wire 事件无关。

struct MoodColorConfig: Identifiable {
    let mood: String
    let label: String
    let defaultHex: UInt32
    var id: String { mood }
}

/// 6 个可表达状态的默认颜色（顺序固定）。
let moodColorConfigs: [MoodColorConfig] = [
    MoodColorConfig(mood: "idle",         label: "空闲",       defaultHex: 0x60a5fa), // 蓝
    MoodColorConfig(mood: "waiting",      label: "正在思考中", defaultHex: 0x34d399), // 绿
    MoodColorConfig(mood: "authorizing",  label: "等待你的授权", defaultHex: 0xfacc15), // 黄
    MoodColorConfig(mood: "questioning",  label: "做出你的抉择", defaultHex: 0xec4899), // 粉
    MoodColorConfig(mood: "done",         label: "搞定啦",     defaultHex: 0x22d3ee), // 青
    MoodColorConfig(mood: "failed",       label: "出错了",     defaultHex: 0xf87171), // 红
]

/// 未连接时的灰色
let disconnectedHex: UInt32 = 0x9ca3af

// MARK: - 点击穿透模式

enum ClickThroughMode: String, CaseIterable, Identifiable {
    case hover     // 悬停时恢复响应（默认）
    case always    // 永远穿透（不可拖拽）
    case never     // 永不穿透（常驻响应）

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hover: return "悬停时恢复响应"
        case .always: return "永远点击穿透"
        case .never: return "永不穿透"
        }
    }
}

// MARK: - 眼睛颜色（仅黑白两色）

enum EyeColor: String, CaseIterable, Identifiable {
    case white
    case black

    var id: String { rawValue }

    var label: String {
        switch self {
        case .white: return "白色"
        case .black: return "黑色"
        }
    }

    var color: Color {
        switch self {
        case .white: return .white
        case .black: return .black
        }
    }
}

extension Color {
    /// 0xRRGGBB → Color
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }
}

// MARK: - 心情球设置（UserDefaults 持久化）

/// 心情球设置。由 AppCoordinator 持有并注入给面板 / 菜单栏 / 设置页；
/// 不使用全局 singleton（规格 29.9），默认值与被修改时立即写入 UserDefaults。
@MainActor
@Observable
final class MoodBallSettings {
    private let defaults: UserDefaults

    private enum Key {
        static let ballSize = "moodball.ballSize"
        static let breathingSpeed = "moodball.breathingSpeed"
        static let showEyes = "moodball.showEyes"
        static let eyeColor = "moodball.eyeColor"
        static let showStatusBubble = "moodball.showStatusBubble"
        static let glowEnabled = "moodball.glowEnabled"
        static let lockPosition = "moodball.lockPosition"
        static let clickThrough = "moodball.clickThrough"
        static let rememberPosition = "moodball.rememberPosition"
        static let isBallVisible = "moodball.isBallVisible"
        static let positionX = "moodball.ballPositionX"
        static let positionY = "moodball.ballPositionY"
        static let moodColorPrefix = "moodball.moodColor."
    }

    // MARK: 外观

    /// 球体直径 60–200，默认 120
    var ballSize: CGFloat {
        didSet { defaults.set(Double(ballSize), forKey: Key.ballSize) }
    }

    /// 呼吸周期（秒）0.5–5，默认 2.0
    var breathingSpeed: Double {
        didSet { defaults.set(breathingSpeed, forKey: Key.breathingSpeed) }
    }

    /// 是否显示心情球眼睛（竖向椭圆），默认开
    var showEyes: Bool {
        didSet { defaults.set(showEyes, forKey: Key.showEyes) }
    }

    /// 眼睛颜色（仅黑白两色），默认黑
    var eyeColor: EyeColor {
        didSet { defaults.set(eyeColor.rawValue, forKey: Key.eyeColor) }
    }

    /// 状态气泡：非空闲时在球脑门上方显示中文状态提醒，默认开
    var showStatusBubble: Bool {
        didSet { defaults.set(showStatusBubble, forKey: Key.showStatusBubble) }
    }

    /// 外发光：球体周围的彩色光晕 + 投影，默认开
    var glowEnabled: Bool {
        didSet { defaults.set(glowEnabled, forKey: Key.glowEnabled) }
    }

    /// 锁定位置：开启后不可拖拽（仍可双击），默认关
    var lockPosition: Bool {
        didSet { defaults.set(lockPosition, forKey: Key.lockPosition) }
    }

    // MARK: 行为

    /// 点击穿透模式
    var clickThroughMode: ClickThroughMode {
        didSet { defaults.set(clickThroughMode.rawValue, forKey: Key.clickThrough) }
    }

    /// 记住拖拽位置（重启恢复）
    var rememberPosition: Bool {
        didSet { defaults.set(rememberPosition, forKey: Key.rememberPosition) }
    }

    /// 悬浮球显隐（菜单栏「显示/隐藏」开关与设置页共用同一开关）
    var isBallVisible: Bool {
        didSet { defaults.set(isBallVisible, forKey: Key.isBallVisible) }
    }

    // MARK: 颜色

    /// mood → 颜色（跟随 mood 永远生效；颜色可自定义）
    private(set) var moodColors: [String: Color] = [:]

    /// 未连接灰
    var disconnectedColor: Color {
        didSet {
            // 存成 hex 字符串（UInt32 直接 set 会存成数字，读回时 string 是十进制，
            // hexFromDefaults 按 16 进制解析会把颜色读坏）
            defaults.set(String(format: "%06X", colorToHex(disconnectedColor)), forKey: Key.moodColorPrefix + "disconnected")
        }
    }

    // MARK: 位置

    /// 上次拖拽保存的窗口原点（nil = 从未保存）
    var savedBallPosition: CGPoint? {
        get {
            guard let x = defaults.object(forKey: Key.positionX) as? CGFloat,
                  let y = defaults.object(forKey: Key.positionY) as? CGFloat else { return nil }
            return CGPoint(x: x, y: y)
        }
        set {
            if let newValue {
                defaults.set(newValue.x, forKey: Key.positionX)
                defaults.set(newValue.y, forKey: Key.positionY)
            } else {
                defaults.removeObject(forKey: Key.positionX)
                defaults.removeObject(forKey: Key.positionY)
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let d = defaults
        let clamp = { (v: Double, lo: Double, hi: Double) in min(max(v, lo), hi) }

        ballSize = CGFloat(clamp(d.double(forKey: Key.ballSize) == 0 ? 120 : d.double(forKey: Key.ballSize), 60, 200))
        breathingSpeed = clamp(d.double(forKey: Key.breathingSpeed) == 0 ? 2.0 : d.double(forKey: Key.breathingSpeed), 0.5, 5)
        showEyes = d.object(forKey: Key.showEyes) == nil ? true : d.bool(forKey: Key.showEyes)
        eyeColor = EyeColor(rawValue: d.string(forKey: Key.eyeColor) ?? "") ?? .black
        showStatusBubble = d.object(forKey: Key.showStatusBubble) == nil ? true : d.bool(forKey: Key.showStatusBubble)
        glowEnabled = d.object(forKey: Key.glowEnabled) == nil ? true : d.bool(forKey: Key.glowEnabled)
        lockPosition = d.object(forKey: Key.lockPosition) == nil ? false : d.bool(forKey: Key.lockPosition)
        clickThroughMode = ClickThroughMode(rawValue: d.string(forKey: Key.clickThrough) ?? "") ?? .hover
        rememberPosition = d.object(forKey: Key.rememberPosition) == nil ? true : d.bool(forKey: Key.rememberPosition)
        isBallVisible = d.object(forKey: Key.isBallVisible) == nil ? true : d.bool(forKey: Key.isBallVisible)
        disconnectedColor = Color(hex: hexFromDefaults(d, key: Key.moodColorPrefix + "disconnected") ?? disconnectedHex)

        // 读各状态颜色（没存过就用契约默认值）
        var colors: [String: Color] = [:]
        for cfg in moodColorConfigs {
            let hex = hexFromDefaults(d, key: Key.moodColorPrefix + cfg.mood) ?? cfg.defaultHex
            colors[cfg.mood] = Color(hex: hex)
        }
        moodColors = colors
    }

    /// 设置某个 mood 的颜色
    func setMoodColor(_ mood: String, _ color: Color) {
        moodColors[mood] = color
        // 存成 hex 字符串（同 disconnectedColor 的原因）
        defaults.set(String(format: "%06X", colorToHex(color)), forKey: Key.moodColorPrefix + mood)
    }

    /// 全部恢复契约默认色
    func resetMoodColors() {
        var colors: [String: Color] = [:]
        for cfg in moodColorConfigs {
            colors[cfg.mood] = Color(hex: cfg.defaultHex)
            defaults.removeObject(forKey: Key.moodColorPrefix + cfg.mood)
        }
        moodColors = colors
        disconnectedColor = Color(hex: disconnectedHex)
        defaults.removeObject(forKey: Key.moodColorPrefix + "disconnected")
    }
}

// MARK: - hex 工具

func colorToHex(_ color: Color) -> UInt32 {
    let resolved = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
    let r = Int((resolved.redComponent * 255).rounded())
    let g = Int((resolved.greenComponent * 255).rounded())
    let b = Int((resolved.blueComponent * 255).rounded())
    return UInt32(r << 16 | g << 8 | b)
}

func hexFromDefaults(_ d: UserDefaults, key: String) -> UInt32? {
    guard let raw = d.string(forKey: key), let value = UInt32(raw, radix: 16) else { return nil }
    return value
}
