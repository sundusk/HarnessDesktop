import Foundation

/// UserDefaults 持久化层（V1 不需要数据库）。
struct SettingsStore {
    private let defaults: UserDefaults

    private enum Key {
        static let host = "settings.host"
        static let port = "settings.port"
        static let launchMainWindowAtStart = "settings.launchMainWindowAtStart"
        static let notificationsEnabled = "settings.notificationsEnabled"
        // 旧 npm 缓存键仅用于向 installable 缓存迁移。
        static let lastUpdateCheckDate = "runtime.version.lastUpdateCheckDate"
        static let latestKnownHarnessVersion = "runtime.version.latestKnown"
        static let lastReleaseCheckDate = "runtime.version.release.lastCheckDate"
        static let latestKnownHarnessReleaseVersion = "runtime.version.release.latestKnown"
        static let lastInstallableCheckDate = "runtime.version.installable.lastCheckDate"
        static let latestKnownHarnessInstallableVersion = "runtime.version.installable.latestKnown"
        // 终端命令检测到的本地 Harness 版本（`npx -y @deepseek-ai/dsh --version`）。
        static let lastDetectedHarnessVersion = "runtime.version.lastDetected"
        // Phase 11：Managed Harness 设置（文档 §19 / §26 / §27）。
        static let launchManagedHarnessAtAppStart = "runtime.launchManagedHarnessAtAppStart"
        static let stopManagedHarnessOnQuit = "runtime.stopManagedHarnessOnQuit"
        static let managedVersion = "runtime.managedVersion"
        static let previousManagedVersion = "runtime.previousManagedVersion"
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

    // MARK: - 双版本源缓存

    var lastReleaseCheckDate: Date? {
        get { defaults.object(forKey: Key.lastReleaseCheckDate) as? Date }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Key.lastReleaseCheckDate)
            } else {
                defaults.removeObject(forKey: Key.lastReleaseCheckDate)
            }
        }
    }

    var latestKnownHarnessReleaseVersion: String? {
        get { defaults.string(forKey: Key.latestKnownHarnessReleaseVersion) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Key.latestKnownHarnessReleaseVersion)
            } else {
                defaults.removeObject(forKey: Key.latestKnownHarnessReleaseVersion)
            }
        }
    }

    var lastInstallableCheckDate: Date? {
        get {
            if let value = defaults.object(forKey: Key.lastInstallableCheckDate) as? Date { return value }
            guard let legacy = defaults.object(forKey: Key.lastUpdateCheckDate) as? Date else { return nil }
            defaults.set(legacy, forKey: Key.lastInstallableCheckDate)
            return legacy
        }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Key.lastInstallableCheckDate)
            } else {
                defaults.removeObject(forKey: Key.lastInstallableCheckDate)
            }
        }
    }

    var latestKnownHarnessInstallableVersion: String? {
        get {
            if let value = defaults.string(forKey: Key.latestKnownHarnessInstallableVersion) { return value }
            guard let legacy = defaults.string(forKey: Key.latestKnownHarnessVersion) else { return nil }
            defaults.set(legacy, forKey: Key.latestKnownHarnessInstallableVersion)
            return legacy
        }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Key.latestKnownHarnessInstallableVersion)
            } else {
                defaults.removeObject(forKey: Key.latestKnownHarnessInstallableVersion)
            }
        }
    }

    /// 终端命令检测到的本地 Harness 版本（nil = 尚未成功检测过）。
    var lastDetectedHarnessVersion: String? {
        get { defaults.string(forKey: Key.lastDetectedHarnessVersion) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Key.lastDetectedHarnessVersion)
            } else {
                defaults.removeObject(forKey: Key.lastDetectedHarnessVersion)
            }
        }
    }
}

// MARK: - Phase 8：版本服务缓存适配

extension SettingsStore: HarnessVersionCacheStoring {}

// MARK: - Phase 11：Managed Harness 设置（文档 §13 / §19 / §27）

extension SettingsStore {
    /// 打开 App 时自动启动 Managed Harness（默认 false，文档 §27）。
    var launchManagedHarnessAtAppStart: Bool {
        get { defaults.object(forKey: Key.launchManagedHarnessAtAppStart) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.launchManagedHarnessAtAppStart) }
    }

    /// 退出 App 时停止 Managed Harness（默认 true，文档 §19 V1 推荐）。
    var stopManagedHarnessOnQuit: Bool {
        get { defaults.object(forKey: Key.stopManagedHarnessOnQuit) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.stopManagedHarnessOnQuit) }
    }

    /// 固定的 exact Harness 版本（文档 §13：保存于 Desktop 自己的设置，禁止写 Harness Profile）。
    var managedVersion: String? {
        get { defaults.string(forKey: Key.managedVersion) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Key.managedVersion)
            } else {
                defaults.removeObject(forKey: Key.managedVersion)
            }
        }
    }

    /// 上一版本（文档 §13 / §21：更新时保存旧版，供回退；禁止写 Harness Profile）。
    var previousManagedVersion: String? {
        get { defaults.string(forKey: Key.previousManagedVersion) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Key.previousManagedVersion)
            } else {
                defaults.removeObject(forKey: Key.previousManagedVersion)
            }
        }
    }
}
