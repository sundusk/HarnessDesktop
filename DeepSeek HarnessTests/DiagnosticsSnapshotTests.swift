import XCTest
@testable import DeepSeek_Harness

/// fake 诊断数据提供者。
@MainActor
struct FakeDiagnosticsProvider: DiagnosticsProviding {
    var settingsHost = "127.0.0.1"
    var settingsPort = 3080
    var connectionState: HarnessConnectionState = .connected
    var harnessVersion: String? = "0.1.0-rc.7"
    var connectionStateDescription = "已连接"
    var nativeIntegrationDescription = "正常（handshake + 事件流）"
    var managedRuntimeDescription = "已就绪"
    var managedVersion: HarnessVersion? = HarnessVersion("0.1.0-rc.7")
    var latestVersion: HarnessVersion? = HarnessVersion("0.1.0-rc.8")
    var lastConnectionError: String? = nil
}

/// Phase 13：诊断快照（文档 §28：非敏感导出）。
@MainActor
final class DiagnosticsSnapshotTests: XCTestCase {

    func testTextContainsNonSensitiveFields() {
        let snapshot = DiagnosticsFactory.make(coordinator: FakeDiagnosticsProvider())
        let text = snapshot.text

        XCTAssertTrue(text.contains("App 版本"))
        XCTAssertTrue(text.contains("macOS"))
        XCTAssertTrue(text.contains("Harness 端点：127.0.0.1:3080"))
        XCTAssertTrue(text.contains("Harness 版本：0.1.0-rc.7"))
        XCTAssertTrue(text.contains("连接状态：已连接"))
        XCTAssertTrue(text.contains("Managed Runtime：已就绪"))
        XCTAssertTrue(text.contains("Managed 版本：0.1.0-rc.7"))
        XCTAssertTrue(text.contains("最新版本：0.1.0-rc.8"))
    }

    func testUnknownVersionRendersAsUnknown() {
        var provider = FakeDiagnosticsProvider()
        provider.harnessVersion = nil
        provider.latestVersion = nil
        let text = DiagnosticsFactory.make(coordinator: provider).text
        XCTAssertTrue(text.contains("Harness 版本：unknown"))
        XCTAssertTrue(text.contains("最新版本：unknown"))
    }

    func testManagedVersionNilRendersAsNone() {
        var provider = FakeDiagnosticsProvider()
        provider.managedVersion = nil
        let text = DiagnosticsFactory.make(coordinator: provider).text
        XCTAssertTrue(text.contains("Managed 版本：无"))
    }

    func testLastConnectionErrorIncludedWhenPresent() {
        var provider = FakeDiagnosticsProvider()
        provider.lastConnectionError = "握手失败"
        let text = DiagnosticsFactory.make(coordinator: provider).text
        XCTAssertTrue(text.contains("最近连接错误：握手失败"))
    }
}
