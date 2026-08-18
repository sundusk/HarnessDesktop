import SwiftUI

/// 设置页：左右标签页布局。
///
/// - 左侧标签：**常规**（Harness 连接，Save 式）、**运行环境**（2.0 Runtime Manager，即时生效）
///   与 **悬浮球**（心情球设置，即时生效）；
/// - 右侧内容区随标签切换。
struct SettingsView: View {
    /// Phase 13：coordinator 提供环境报告与 Runtime 动作（更新 / 回退 / 检查）。
    let coordinator: AppCoordinator
    let settings: AppSettings
    let onSettingsChanged: () -> Void
    let onResetBallPosition: () -> Void

    @Bindable var petSettings: MoodBallSettings

    @State private var tab: Tab = .general

    @State private var host: String
    @State private var portText: String
    @State private var launchAtStart: Bool
    @State private var notificationsEnabled: Bool
    @State private var errorMessage: String?

    enum Tab: String, CaseIterable, Identifiable {
        case general = "常规"
        case runtime = "运行环境"
        case moodBall = "悬浮球"
        var id: String { rawValue }
    }

    init(coordinator: AppCoordinator,
         settings: AppSettings,
         petSettings: MoodBallSettings,
         onResetBallPosition: @escaping () -> Void = {},
         onSettingsChanged: @escaping () -> Void = {}) {
        self.coordinator = coordinator
        self.settings = settings
        self.petSettings = petSettings
        self.onResetBallPosition = onResetBallPosition
        self.onSettingsChanged = onSettingsChanged
        _host = State(initialValue: settings.host)
        _portText = State(initialValue: String(settings.port))
        _launchAtStart = State(initialValue: settings.launchMainWindowAtStart)
        _notificationsEnabled = State(initialValue: settings.notificationsEnabled)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 170)
                .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            Group {
                switch tab {
                case .general:
                    generalTab
                case .runtime:
                    runtimeTab
                case .moodBall:
                    moodBallTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 680, height: 580)
    }

    // MARK: - 左侧标签栏

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("设置")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            ForEach(Tab.allCases) { item in
                Button {
                    tab = item
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: icon(for: item))
                            .frame(width: 16)
                        Text(item.rawValue)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(tab == item ? Color.accentColor.opacity(0.18) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .foregroundStyle(tab == item ? Color.accentColor : .primary)
            }

            Spacer()
        }
        .padding(.top, 16)
    }

    private func icon(for tab: Tab) -> String {
        switch tab {
        case .general: return "network"
        case .runtime: return "gearshape.2"
        case .moodBall: return "circle.hexagongrid.fill"
        }
    }

    // MARK: - 常规（Harness 连接，Save 式）

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                Form {
                    Section("Harness 连接") {
                        TextField("Harness 地址", text: $host)
                        TextField("Harness 端口", text: $portText)
                        Toggle("启动时显示主窗口", isOn: $launchAtStart)
                        Toggle("启用通知", isOn: $notificationsEnabled)
                    }
                }
                .formStyle(.grouped)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                }
            }

            HStack {
                Spacer()
                Button("保存") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(isDirty ? Color.accentColor : .gray)
                .disabled(!isDirty)
            }
            .padding(16)
        }
    }

    /// 编辑内容与已保存设置是否有差异。
    ///
    /// 决定「保存」按钮状态：无差异时按钮为灰色禁用，有差异时变蓝可点击，
    /// 保存成功后（字段与 settings 一致）自动恢复灰色。
    private var isDirty: Bool {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedHost != settings.host
            || Int(portText) != settings.port
            || launchAtStart != settings.launchMainWindowAtStart
            || notificationsEnabled != settings.notificationsEnabled
    }

    private func save() {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard HarnessEndpoint.isAllowedLoopbackHost(trimmedHost) else {
            errorMessage = "仅允许 loopback 地址（127.0.0.1 / localhost / ::1）"
            return
        }
        guard let port = Int(portText), (1...65535).contains(port) else {
            errorMessage = "端口必须是 1...65535 之间的整数"
            return
        }

        settings.host = trimmedHost
        settings.port = port
        settings.launchMainWindowAtStart = launchAtStart
        settings.notificationsEnabled = notificationsEnabled
        errorMessage = nil
        onSettingsChanged()
    }

    // MARK: - 运行环境（2.0 Runtime Manager，即时生效）

    private var runtimeTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Form {
                    Section {
                        runtimeModeSection
                    } header: {
                        Text("Harness 模式")
                    }

                    Section {
                        runtimeVersionSection
                    } header: {
                        Text("Managed Harness")
                    }

                    Section {
                        Toggle("打开 App 时自动启动 Managed Harness", isOn: Binding(
                            get: { settings.launchManagedHarnessAtAppStart },
                            set: { settings.launchManagedHarnessAtAppStart = $0 }
                        ))
                        Picker("退出 App 时", selection: Binding(
                            get: { settings.stopManagedHarnessOnQuit },
                            set: { settings.stopManagedHarnessOnQuit = $0 }
                        )) {
                            Text("停止 Managed Harness").tag(true)
                            Text("保持 Managed Harness 运行").tag(false)
                        }
                        .pickerStyle(.radioGroup)
                    } header: {
                        Text("启动 / 退出")
                    } footer: {
                        Text("External Harness（终端启动的）永远不会被本应用停止。")
                    }

                    Section {
                        LabeledContent("数据模式") {
                            Text("隔离模式（ManagedHarnessHome）")
                        }
                        LabeledContent("数据路径") {
                            Text(managedHomePath)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("数据")
                    }
                }
                .formStyle(.grouped)
            }
        }
    }

    /// Harness 模式：外部 / HarnessDesktop / 未运行。
    private var runtimeModeSection: some View {
        LabeledContent("当前") {
            Text(runtimeModeText)
        }
    }

    private var runtimeModeText: String {
        switch coordinator.environmentReport.ownership {
        case .external:
            return "外部 Harness（已连接）"
        case .managed:
            return "Managed Harness（HarnessDesktop 启动）"
        case nil:
            return "未运行"
        }
    }

    /// Managed Harness 版本 + 更新 / 回退动作（文档 §26）。
    @ViewBuilder
    private var runtimeVersionSection: some View {
        LabeledContent("当前版本") {
            // 报告层 currentVersion：占位值（0.0.1）自动以 latest 兜底，
            // 避免一直显示上游硬编码占位版本。
            Text(coordinator.environmentReport.currentVersion?.description ?? "未配置")
        }
        LabeledContent("上一版本") {
            Text(settings.previousManagedVersion ?? "无")
        }
        LabeledContent("最新版本") {
            Text(coordinator.environmentReport.latestVersion?.description ?? "unknown")
        }
        if let summary = coordinator.environmentReport.updateStatus.summary {
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        HStack(spacing: 12) {
            Button("检查更新") {
                coordinator.checkForUpdates()
            }
            Button("更新 Harness…") {
                coordinator.updateManagedHarness()
            }
            .disabled(!canUpdate)
            Button("回退…") {
                coordinator.rollbackManagedHarness()
            }
            .disabled(settings.previousManagedVersion == nil)
        }
    }

    private var canUpdate: Bool {
        coordinator.environmentReport.updateStatus.hasUpdate
            && (coordinator.environmentReport.ownership == .managed
                || coordinator.activeManagedIdentity != nil)
    }

    private var managedHomePath: String {
        ManagedRuntimePaths.makeDefault()?.managedHarnessHome.path ?? "不可用"
    }

    // MARK: - 悬浮球（即时生效）

    private var moodBallTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Form {
                    Section {
                        petSection
                    } header: {
                        Text("心情球")
                    } footer: {
                        Text("悬浮球设置即时生效：修改球大小、呼吸速度、颜色等会立刻反映到桌面上的心情球。")
                    }
                }
                .formStyle(.grouped)
            }
        }
    }

    @ViewBuilder
    private var petSection: some View {
        Toggle("显示悬浮球", isOn: $petSettings.isBallVisible)
            .help("关闭后桌面心情球隐藏，菜单栏「显示悬浮球」可随时重新打开")

        LabeledContent("球体大小") {
            HStack {
                Slider(value: $petSettings.ballSize, in: 60...200, step: 4)
                Text("\(Int(petSettings.ballSize)) px")
                    .monospacedDigit()
                    .frame(width: 52, alignment: .trailing)
                    .foregroundStyle(.secondary)
            }
        }

        LabeledContent("呼吸速度") {
            HStack {
                Slider(value: $petSettings.breathingSpeed, in: 0.5...5, step: 0.1)
                Text(String(format: "%.1fs", petSettings.breathingSpeed))
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
                    .foregroundStyle(.secondary)
            }
        }
        Text("周期越短呼吸越快。")
            .font(.caption)
            .foregroundStyle(.secondary)

        Toggle("显示眼睛", isOn: $petSettings.showEyes)

        LabeledContent("眼睛颜色") {
            Picker("", selection: $petSettings.eyeColor) {
                ForEach(EyeColor.allCases) { color in
                    Text(color.label).tag(color)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 140)
        }

        Toggle("显示气泡文字", isOn: $petSettings.showStatusBubble)
        Text("非空闲状态时在球上方显示漫画风状态提醒（正在思考中/等待你的授权…），空闲自动隐藏。")
            .font(.caption)
            .foregroundStyle(.secondary)

        Toggle("发光", isOn: $petSettings.glowEnabled)
        Text("关闭后球体不再显示彩色光晕与投影。")
            .font(.caption)
            .foregroundStyle(.secondary)

        LabeledContent("点击穿透") {
            Picker("", selection: $petSettings.clickThroughMode) {
                ForEach(ClickThroughMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 170)
        }

        Toggle("记住拖拽位置（重启恢复）", isOn: $petSettings.rememberPosition)

        Toggle("锁定位置", isOn: $petSettings.lockPosition)
        Text("开启后不可拖拽移动小球（仍可双击）。")
            .font(.caption)
            .foregroundStyle(.secondary)

        Button("重置位置到右下角") {
            onResetBallPosition()
        }

        Divider()

        Text("球始终跟随 Harness 状态变色；下面的颜色可在默认契约基础上自定义。")
            .font(.caption)
            .foregroundStyle(.secondary)

        ForEach(moodColorConfigs) { cfg in
            HStack {
                Text(cfg.label)
                    .frame(width: 72, alignment: .leading)
                Spacer()
                ColorPicker("", selection: Binding(
                    get: { petSettings.moodColors[cfg.mood] ?? Color(hex: cfg.defaultHex) },
                    set: { petSettings.setMoodColor(cfg.mood, $0) }
                ), supportsOpacity: false)
                .labelsHidden()
                Text(hexString(petSettings.moodColors[cfg.mood] ?? Color(hex: cfg.defaultHex)))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
            }
        }

        HStack {
            Text("未连接灰")
                .frame(width: 72, alignment: .leading)
            Spacer()
            ColorPicker("", selection: $petSettings.disconnectedColor, supportsOpacity: false)
                .labelsHidden()
        }

        Button("恢复默认颜色") {
            petSettings.resetMoodColors()
        }
    }

    private func hexString(_ color: Color) -> String {
        String(format: "#%06X", colorToHex(color))
    }
}
