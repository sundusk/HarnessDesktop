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

    /// 是否启用通知。
    var notificationsEnabled: Bool {
        get { store.notificationsEnabled }
        set { store.notificationsEnabled = newValue }
    }

    // MARK: - 双版本源缓存

    var lastReleaseCheckDate: Date? {
        get { store.lastReleaseCheckDate }
        set { store.lastReleaseCheckDate = newValue }
    }

    var latestKnownHarnessReleaseVersion: String? {
        get { store.latestKnownHarnessReleaseVersion }
        set { store.latestKnownHarnessReleaseVersion = newValue }
    }

    var lastInstallableCheckDate: Date? {
        get { store.lastInstallableCheckDate }
        set { store.lastInstallableCheckDate = newValue }
    }

    var latestKnownHarnessInstallableVersion: String? {
        get { store.latestKnownHarnessInstallableVersion }
        set { store.latestKnownHarnessInstallableVersion = newValue }
    }

    // MARK: - Phase 11：Managed Harness 设置（文档 §19 / §27）

    /// 打开 App 时自动启动 Managed Harness（默认 false）。
    var launchManagedHarnessAtAppStart: Bool {
        get { store.launchManagedHarnessAtAppStart }
        set { store.launchManagedHarnessAtAppStart = newValue }
    }

    /// 退出 App 时停止 Managed Harness（默认 true）。
    var stopManagedHarnessOnQuit: Bool {
        get { store.stopManagedHarnessOnQuit }
        set { store.stopManagedHarnessOnQuit = newValue }
    }

    /// 固定的 exact Harness 版本（文档 §13）。
    var managedVersion: String? {
        get { store.managedVersion }
        set { store.managedVersion = newValue }
    }

    /// 上一版本（文档 §13 / §21 / §22：供回退）。
    var previousManagedVersion: String? {
        get { store.previousManagedVersion }
        set { store.previousManagedVersion = newValue }
    }
}

// MARK: - Phase 8：版本服务缓存适配

extension AppSettings: HarnessVersionCacheStoring {}
