import Foundation

/// UserDefaults 持久化层（V1 不需要数据库）。
struct SettingsStore {
    private let defaults: UserDefaults

    private enum Key {
        static let host = "settings.host"
        static let port = "settings.port"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var host: String {
        get { defaults.string(forKey: Key.host) ?? "127.0.0.1" }
        set { defaults.set(newValue, forKey: Key.host) }
    }

    var port: Int {
        get {
            let stored = defaults.integer(forKey: Key.port)
            return stored == 0 ? 3080 : stored
        }
        set { defaults.set(newValue, forKey: Key.port) }
    }
}
