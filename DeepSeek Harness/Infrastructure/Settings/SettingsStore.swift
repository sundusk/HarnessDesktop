import Foundation

/// UserDefaults 持久化层（V1 不需要数据库）。
struct SettingsStore {
    private let defaults: UserDefaults

    private enum Key {
        static let host = "settings.host"
        static let port = "settings.port"
        static let launchMainWindowAtStart = "settings.launchMainWindowAtStart"
        static let notificationsEnabled = "settings.notificationsEnabled"
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

    var launchMainWindowAtStart: Bool {
        get {
            defaults.object(forKey: Key.launchMainWindowAtStart) as? Bool ?? true
        }
        set { defaults.set(newValue, forKey: Key.launchMainWindowAtStart) }
    }

    var notificationsEnabled: Bool {
        get {
            defaults.object(forKey: Key.notificationsEnabled) as? Bool ?? true
        }
        set { defaults.set(newValue, forKey: Key.notificationsEnabled) }
    }
}
