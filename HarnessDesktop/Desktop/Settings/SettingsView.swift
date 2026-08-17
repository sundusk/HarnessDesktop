import SwiftUI

/// 基础设置页（规格 26 极简设置项）。
///
/// V1 生效项：Harness Address / Harness Port / Launch Main Window at App Start /
/// Enable Notifications。
struct SettingsView: View {
    let settings: AppSettings
    let onSettingsChanged: () -> Void

    @State private var host: String
    @State private var portText: String
    @State private var launchAtStart: Bool
    @State private var notificationsEnabled: Bool
    @State private var errorMessage: String?

    init(settings: AppSettings, onSettingsChanged: @escaping () -> Void = {}) {
        self.settings = settings
        self.onSettingsChanged = onSettingsChanged
        _host = State(initialValue: settings.host)
        _portText = State(initialValue: String(settings.port))
        _launchAtStart = State(initialValue: settings.launchMainWindowAtStart)
        _notificationsEnabled = State(initialValue: settings.notificationsEnabled)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField("Harness 地址", text: $host)
                TextField("Harness 端口", text: $portText)
                Toggle("启动时显示主窗口", isOn: $launchAtStart)
                Toggle("启用通知", isOn: $notificationsEnabled)
            }
            .formStyle(.grouped)

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }

            HStack {
                Spacer()
                Button("取消") {
                    resetFields()
                }
                Button("保存") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 460)
    }

    private func resetFields() {
        host = settings.host
        portText = String(settings.port)
        launchAtStart = settings.launchMainWindowAtStart
        notificationsEnabled = settings.notificationsEnabled
        errorMessage = nil
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
}
