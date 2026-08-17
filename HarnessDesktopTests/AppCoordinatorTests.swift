import XCTest
@testable import HarnessDesktop

/// AppCoordinator 接线测试：默认 Discovery 必须使用用户配置的 host/port。
@MainActor
final class AppCoordinatorTests: XCTestCase {

    private let suiteName = "AppCoordinatorTests-\(UUID().uuidString)"

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeSettings(host: String = "localhost", port: Int = 9999) -> AppSettings {
        let defaults = UserDefaults(suiteName: suiteName)!
        var store = SettingsStore(defaults: defaults)
        store.host = host
        store.port = port
        return AppSettings(store: store)
    }

    func testDefaultDiscoveryUsesSettingsPort() {
        let coordinator = AppCoordinator(settings: makeSettings(port: 9999))
        let discovery = coordinator.discovery as? LocalHarnessDiscovery
        XCTAssertEqual(discovery?.host, "localhost")
        XCTAssertEqual(discovery?.port, 9999)
    }

    func testDefaultDiscoveryUsesSettingsHost() {
        let coordinator = AppCoordinator(settings: makeSettings(host: "127.0.0.1", port: 3080))
        let discovery = coordinator.discovery as? LocalHarnessDiscovery
        XCTAssertEqual(discovery?.host, "127.0.0.1")
        XCTAssertEqual(discovery?.port, 3080)
    }

    func testInjectedDiscoveryIsPreserved() {
        let custom = LocalHarnessDiscovery(host: "localhost", port: 1234)
        let coordinator = AppCoordinator(settings: makeSettings(), discovery: custom)
        let discovery = coordinator.discovery as? LocalHarnessDiscovery
        XCTAssertEqual(discovery?.host, custom.host)
        XCTAssertEqual(discovery?.port, custom.port)
    }
}
