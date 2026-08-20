import AppKit
import os

private let menuBarLog = Logger(subsystem: "dev.deepseekharness.DeepSeekHarness", category: "menu")

/// 菜单栏协调器（AppKit `NSStatusItem` + `NSMenu`）。
///
/// 为什么不用 SwiftUI `MenuBarExtra`：macOS 26 下 MenuBarExtra 的菜单会错误地
/// 右对齐到屏幕边缘而不是锚定在状态项下方（表现为「菜单跑到右边、与鲸鱼图标脱开」）。
/// `NSStatusItem` 的 `NSMenu` 始终在图标正下方弹出 —— 这也是 dsh-moodball 采用的方案。
///
/// 只消费 `AppCoordinator` 的公开状态（connectionState / activityState /
/// sessionCount / harnessInfo / petSettings），菜单内容随状态变化即时刷新。
@MainActor
final class MenuBarCoordinator {
    private let coordinator: AppCoordinator
    private let onOpenWindow: () -> Void

    private var statusItem: NSStatusItem?
    private var statusTextItem: NSMenuItem?
    private var detailsItem: NSMenuItem?
    private var toggleItem: NSMenuItem?
    private var stopManagedItem: NSMenuItem?
    private var updateItem: NSMenuItem?
    private var rollbackItem: NSMenuItem?
    private var observationTask: Task<Void, Never>?
    private var changeContinuation: CheckedContinuation<Void, Never>?

    init(coordinator: AppCoordinator, onOpenWindow: @escaping () -> Void) {
        self.coordinator = coordinator
        self.onOpenWindow = onOpenWindow
    }

    // MARK: - 生命周期

    func start() {
        guard statusItem == nil else { return }
        setupStatusItem()
        startObservations()
        menuBarLog.info("菜单栏已启动")
    }

    func stop() {
        observationTask?.cancel()
        observationTask = nil
        resumeChangeWait()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
        menuBarLog.info("菜单栏已停止")
    }

    // MARK: - 状态项

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(named: "MenuBarIcon")
        item.button?.image?.isTemplate = true
        item.button?.toolTip = "DeepSeek Harness"
        item.button?.setAccessibilityLabel("DeepSeek Harness")
        item.menu = makeMenu()
        statusItem = item
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        statusTextItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        statusTextItem?.isEnabled = false
        menu.addItem(statusTextItem!)

        detailsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        detailsItem?.isEnabled = false
        detailsItem?.isHidden = true
        menu.addItem(detailsItem!)

        menu.addItem(.separator())

        // 悬浮球显示/隐藏开关（状态栏唯一的悬浮球入口；其余设置都在「设置…」里）
        toggleItem = NSMenuItem(title: "显示悬浮球", action: #selector(toggleBallVisibility(_:)), keyEquivalent: "")
        toggleItem?.target = self
        menu.addItem(toggleItem!)

        menu.addItem(.separator())

        menu.addItem(makeActionItem("打开 Harness", #selector(openWindowAction)))
        menu.addItem(makeActionItem("重新加载", #selector(reloadAction), keyEquivalent: "r"))
        menu.addItem(makeActionItem("在浏览器中打开", #selector(openInBrowserAction)))
        menu.addItem(makeActionItem("重新检测", #selector(rediscoverAction)))
        // App 自身更新检查（Harness 的更新管理在「设置 → 运行环境」，这里只查 App 版本）
        menu.addItem(makeActionItem("检查 App 更新…", #selector(checkForAppUpdatesAction)))
        // Phase 13：诊断信息导出（非敏感）
        menu.addItem(makeActionItem("复制诊断信息", #selector(copyDiagnosticsAction)))
        // Phase 11：停止 Managed Harness（只对 App 自己启动的进程显示；External 永不停止）
        stopManagedItem = makeActionItem("停止 Harness", #selector(stopManagedAction))
        stopManagedItem?.isHidden = true
        menu.addItem(stopManagedItem!)
        // Phase 12：更新 / 回退（仅 Managed；确认后执行）
        updateItem = makeActionItem("更新 Harness…", #selector(updateManagedAction))
        updateItem?.isHidden = true
        menu.addItem(updateItem!)
        rollbackItem = makeActionItem("回退到…", #selector(rollbackManagedAction))
        rollbackItem?.isHidden = true
        menu.addItem(rollbackItem!)

        menu.addItem(.separator())

        menu.addItem(makeActionItem("设置…", #selector(openSettingsAction), keyEquivalent: ","))
        let quitItem = makeActionItem("退出 DeepSeek Harness", #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)

        refreshMenu()
        return menu
    }

    private func makeActionItem(_ title: String, _ action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    // MARK: - 状态 → 菜单内容（Observation 驱动，不轮询）

    private func startObservations() {
        observationTask?.cancel()
        observationTask = Task { [weak self] in
            guard let self else { return }
            await self.observationLoop()
        }
    }

    private func observationLoop() async {
        refreshMenu()
        await waitForChange()
        guard !Task.isCancelled else { return }
        await observationLoop()
    }

    private func waitForChange() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            changeContinuation = continuation
            withObservationTracking {
                _ = coordinator.connectionState
                _ = coordinator.activityState
                _ = coordinator.sessionCount
                _ = coordinator.harnessInfo?.version
                _ = coordinator.petSettings.isBallVisible
                // Phase 8：版本 / 更新状态（检查更新后菜单栏即时刷新）
                _ = coordinator.environmentReport.updateStatus
                _ = coordinator.environmentReport.runningVersion
                _ = coordinator.environmentReport.latestReleaseVersion
                _ = coordinator.environmentReport.latestInstallableVersion
                // Phase 11：Managed 运行状态（停止项显隐）
                _ = coordinator.activeManagedIdentity
                // Phase 12：更新 / 回退状态
                _ = coordinator.isUpdatingManaged
                _ = coordinator.environmentReport.ownership
                _ = coordinator.environmentReport.updateStatus
            } onChange: { [weak self] in
                Task { @MainActor in
                    self?.resumeChangeWait()
                }
            }
        }
        changeContinuation = nil
    }

    private func resumeChangeWait() {
        changeContinuation?.resume()
        changeContinuation = nil
    }

    private func refreshMenu() {
        let text = statusText
        statusTextItem?.title = text
        statusItem?.button?.toolTip = text

        var details: [String] = []
        if coordinator.sessionCount > 0 {
            details.append("会话数：\(coordinator.sessionCount)")
        }
        // 版本优先取 currentVersion（占位值 0.0.1 由报告层以 latest 兜底）。
        if let version = coordinator.environmentReport.currentVersion {
            details.append("版本：\(version)")
        }
        // Phase 8：当前 / 最新版本 + 更新状态（规格 §20 / §24）
        if let latest = coordinator.environmentReport.latestReleaseVersion {
            details.append("官方最新：\(latest)")
        }
        switch coordinator.environmentReport.updateStatus {
        case .checking:
            details.append("正在检查更新…")
        case .updateAvailable:
            details.append("⬆ 有更新可用")
        case .releaseAvailableButNotInstallable:
            details.append("● 新版已发布，等待 npm")
        default:
            break
        }
        detailsItem?.title = details.joined(separator: " · ")
        detailsItem?.isHidden = details.isEmpty

        toggleItem?.title = coordinator.petSettings.isBallVisible ? "隐藏悬浮球" : "显示悬浮球"
        toggleItem?.state = coordinator.petSettings.isBallVisible ? .on : .off

        // Phase 11：只有 Managed Harness 运行中才显示「停止 Harness」
        stopManagedItem?.isHidden = coordinator.activeManagedIdentity == nil

        // Phase 12：Managed 且可更新 → 显示「更新 Harness…」；有上一版本 → 显示「回退到 X…」
        let isManaged = coordinator.activeManagedIdentity != nil
            || coordinator.environmentReport.ownership == .managed
        let notBusy = !coordinator.isUpdatingManaged
        updateItem?.isHidden = !(isManaged && coordinator.environmentReport.updateStatus.hasUpdate && notBusy)
        if let previous = coordinator.settings.previousManagedVersion {
            rollbackItem?.title = "回退到 \(previous)…"
            rollbackItem?.isHidden = !(isManaged && notBusy)
        } else {
            rollbackItem?.isHidden = true
        }
    }

    // MARK: - 文案

    private var statusText: String {
        switch coordinator.connectionState {
        case .unknown, .discovering, .connecting:
            return "状态：正在检测…"
        case .unavailable:
            return "状态：Harness 未运行"
        case .reconnecting:
            return "状态：正在重连…"
        case .connected, .degraded:
            return activityStatusText
        }
    }

    /// 已连接时的活动状态文案（规格 21：Status: Working 等，中文文案）。
    private var activityStatusText: String {
        switch coordinator.activityState {
        case .disconnected:
            return "状态：已断开"
        case .idle:
            return "状态：空闲"
        case .running:
            return "状态：工作中"
        case .waitingForInput:
            return "状态：等待输入"
        case .waitingForApproval:
            return "状态：等待批准"
        case .error(let message):
            if let message, !message.isEmpty {
                return "状态：错误 — \(message)"
            }
            return "状态：错误"
        }
    }

    // MARK: - 动作

    @objc private func toggleBallVisibility(_ sender: Any?) {
        coordinator.petSettings.isBallVisible.toggle()
    }

    @objc private func openWindowAction() {
        onOpenWindow()
    }

    @objc private func reloadAction() {
        coordinator.reload()
    }

    @objc private func openInBrowserAction() {
        coordinator.openInBrowser()
    }

    @objc private func rediscoverAction() {
        coordinator.rediscover()
    }

    @objc private func checkForAppUpdatesAction() {
        coordinator.checkForAppUpdates()
    }

    @objc private func copyDiagnosticsAction() {
        let text = coordinator.diagnosticsText()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        menuBarLog.info("诊断信息已复制")
    }

    @objc private func stopManagedAction() {
        coordinator.stopManagedHarness()
    }

    @objc private func updateManagedAction() {
        guard let current = coordinator.environmentReport.managedVersion,
              case .updateAvailable(_, _, let latestInstallable) = coordinator.environmentReport.updateStatus else { return }
        let alert = NSAlert()
        alert.messageText = "DeepSeek Harness 有新版本"
        alert.informativeText = "当前：\(current)\n可安装：\(latestInstallable)\n\nDeepSeek Harness 仍处于快速迭代阶段，新版本可能影响第三方插件或 Native API 兼容。"
        alert.addButton(withTitle: "更新并重新启动")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        coordinator.updateManagedHarness()
    }

    @objc private func rollbackManagedAction() {
        guard let current = coordinator.settings.managedVersion,
              let previous = coordinator.settings.previousManagedVersion else { return }
        let alert = NSAlert()
        alert.messageText = "回退到 \(previous)"
        alert.informativeText = "当前：\(current)\n回退：\(previous)"
        alert.addButton(withTitle: "回退并重新启动")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        coordinator.rollbackManagedHarness()
    }

    @objc private func openSettingsAction() {
        // SwiftUI Settings scene 会把「设置…」项放进系统主菜单的 app menu。
        // 直接把这个菜单项的 action 发给它的 target —— 比
        // `NSApp.sendAction(showSettingsWindow:, to: nil)` 可靠：后者走响应链，
        // 而 SwiftUI 的设置命令处理器不在响应链上时会静默失败（实测主窗口
        // 关闭或打开时都打不开设置）。
        if let item = Self.settingsMenuItem(in: NSApp.mainMenu) {
            if let action = item.action {
                menuBarLog.info("触发主菜单「设置…」项（target=\(String(describing: item.target), privacy: .public)）")
                NSApp.sendAction(action, to: item.target, from: item)
                return
            }
        }
        menuBarLog.info("未找到主菜单「设置…」项，回退私有 selector")
        // 兜底：标准私有 selector（macOS 13+ SwiftUI Settings 场景）
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    /// 递归查找主菜单里的「设置…」项（SwiftUI Settings 场景自动生成）。
    private static func settingsMenuItem(in menu: NSMenu?) -> NSMenuItem? {
        guard let menu else { return nil }
        for item in menu.items {
            if item.action == Selector(("showSettingsWindow:"))
                || item.action == Selector(("showPreferencesWindow:"))
                || item.title == "设置…"
                || item.title == "Settings…" {
                return item
            }
            if let submenu = item.submenu, let found = settingsMenuItem(in: submenu) {
                return found
            }
        }
        return nil
    }
}
