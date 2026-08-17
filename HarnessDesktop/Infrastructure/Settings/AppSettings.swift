import Foundation

/// 应用设置（V1 极简：仅 Harness 地址与端口）。
///
/// 禁止配置非 loopback host：读取时对非法值回退默认值。
final class AppSettings {
    private var store: SettingsStore

    init(store: SettingsStore = SettingsStore()) {
        self.store = store
    }

    /// Harness host。仅允许 loopback；非法值回退 `127.0.0.1`。
    var host: String {
        get {
            let stored = store.host
            return HarnessEndpoint.isAllowedLoopbackHost(stored) ? stored : "127.0.0.1"
        }
        set {
            store.host = newValue
        }
    }

    /// Harness port。范围 1...65535；非法值回退 `3080`。
    var port: Int {
        get {
            let stored = store.port
            return (1...65535).contains(stored) ? stored : 3080
        }
        set {
            store.port = newValue
        }
    }

    /// 启动时是否显示主窗口。
    var launchMainWindowAtStart: Bool {
        get { store.launchMainWindowAtStart }
        set { store.launchMainWindowAtStart = newValue }
    }
}
