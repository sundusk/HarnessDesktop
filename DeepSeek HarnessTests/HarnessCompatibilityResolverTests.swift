import XCTest
@testable import DeepSeek_Harness

final class HarnessCompatibilityResolverTests: XCTestCase {

    func testVersionParsing() {
        XCTAssertEqual(HarnessVersion("0.0.1"), HarnessVersion(major: 0, minor: 0, patch: 1))
        XCTAssertEqual(HarnessVersion("1.2.3"), HarnessVersion(major: 1, minor: 2, patch: 3))
        XCTAssertEqual(HarnessVersion("v1.2.3"), HarnessVersion(major: 1, minor: 2, patch: 3))
        XCTAssertEqual(HarnessVersion("2"), HarnessVersion(major: 2, minor: 0, patch: 0))
        XCTAssertNil(HarnessVersion("garbage"))
        XCTAssertNil(HarnessVersion(""))
        XCTAssertNil(HarnessVersion("a.b.c"))
        XCTAssertNil(HarnessVersion("1.2.3.4"))
        XCTAssertNil(HarnessVersion("1.2.3-"))
        XCTAssertNil(HarnessVersion("1.2.3-beta..1"))
    }

    /// Phase 8：预发布后缀不再是可忽略部分，而是版本模型的一部分（0.1.0-rc.7）。
    func testPrereleaseParsing() {
        XCTAssertEqual(
            HarnessVersion("1.2.3-beta.1"),
            HarnessVersion(major: 1, minor: 2, patch: 3, prerelease: ["beta", "1"])
        )
        XCTAssertEqual(
            HarnessVersion("0.1.0-rc.7"),
            HarnessVersion(major: 0, minor: 1, patch: 0, prerelease: ["rc", "7"])
        )
        XCTAssertEqual(HarnessVersion("1.2.3-beta.1")?.description, "1.2.3-beta.1")
        XCTAssertEqual(HarnessVersion("0.1.0-rc.7")?.description, "0.1.0-rc.7")
    }

    /// Phase 8：build metadata 被解析但忽略优先级。
    func testBuildMetadataParsing() {
        let withBuild = HarnessVersion("1.2.3+build5")
        XCTAssertEqual(withBuild?.buildMetadata, "build5")
        XCTAssertEqual(withBuild, HarnessVersion("1.2.3"))
        XCTAssertEqual(withBuild?.description, "1.2.3+build5")
        XCTAssertEqual(HarnessVersion("1.2.3+build5"), HarnessVersion("1.2.3+build99"))
    }

    func testVersionComparison() {
        XCTAssertLessThan(HarnessVersion("1.2.3")!, HarnessVersion("1.2.4")!)
        XCTAssertLessThan(HarnessVersion("1.2.9")!, HarnessVersion("1.10.0")!)
        XCTAssertLessThan(HarnessVersion("0.9.9")!, HarnessVersion("1.0.0")!)
        XCTAssertEqual(HarnessVersion("1.2.3")!, HarnessVersion("1.2.3")!)
    }

    // MARK: - Phase 8：semver / prerelease 比较（规格 11：0.1.0-rc.7 < 0.1.0-rc.8）

    func testPrereleaseComparison() {
        XCTAssertLessThan(HarnessVersion("0.1.0-rc.7")!, HarnessVersion("0.1.0-rc.8")!)
        XCTAssertLessThan(HarnessVersion("1.0.0-alpha")!, HarnessVersion("1.0.0-beta")!)
        XCTAssertLessThan(HarnessVersion("1.0.0-alpha")!, HarnessVersion("1.0.0")!)
        XCTAssertGreaterThan(HarnessVersion("1.0.0")!, HarnessVersion("1.0.0-rc.1")!)
        XCTAssertLessThan(HarnessVersion("1.0.0-alpha")!, HarnessVersion("1.0.0-alpha.1")!)
        XCTAssertLessThan(HarnessVersion("1.0.0-alpha.1")!, HarnessVersion("1.0.0-alpha.beta")!)
        XCTAssertLessThan(HarnessVersion("1.0.0-alpha.beta")!, HarnessVersion("1.0.0-beta")!)
        XCTAssertLessThan(HarnessVersion("1.0.0-beta.2")!, HarnessVersion("1.0.0-beta.11")!)
        XCTAssertLessThan(HarnessVersion("1.0.0-rc.1")!, HarnessVersion("1.0.0")!)
        XCTAssertLessThan(HarnessVersion("0.1.0-rc.7")!, HarnessVersion("0.1.0")!)
    }

    func testPrereleaseEquality() {
        XCTAssertEqual(HarnessVersion("1.0.0-rc.1")!, HarnessVersion("1.0.0-rc.1")!)
        XCTAssertNotEqual(HarnessVersion("1.0.0-rc.1")!, HarnessVersion("1.0.0-rc.2")!)
        XCTAssertNotEqual(HarnessVersion("1.0.0-rc.1")!, HarnessVersion("1.0.0")!)
    }

    /// supportedRange 未限定：任何合法版本 → supported。
    func testUnboundedRangeIsSupported() {
        let resolver = HarnessCompatibilityResolver()
        XCTAssertEqual(resolver.verdict(for: "0.0.1"), .supported)
        XCTAssertEqual(resolver.verdict(for: "9.9.9"), .supported)
    }

    func testUnknownVersion() {
        let resolver = HarnessCompatibilityResolver()
        XCTAssertEqual(resolver.verdict(for: nil), .unknown)
        XCTAssertEqual(resolver.verdict(for: "garbage"), .unknown)
        XCTAssertEqual(resolver.verdict(for: ""), .unknown)
    }

    func testBoundedRangeSupported() {
        let resolver = HarnessCompatibilityResolver(
            supportedRange: HarnessVersion("1.0.0")!...HarnessVersion("1.9.9")!
        )
        XCTAssertEqual(resolver.verdict(for: "1.0.0"), .supported)
        XCTAssertEqual(resolver.verdict(for: "1.5.0"), .supported)
        XCTAssertEqual(resolver.verdict(for: "1.9.9"), .supported)
    }

    func testBoundedRangeUnsupported() {
        let resolver = HarnessCompatibilityResolver(
            supportedRange: HarnessVersion("1.0.0")!...HarnessVersion("1.9.9")!
        )
        XCTAssertEqual(resolver.verdict(for: "0.9.0"), .unsupported)
        XCTAssertEqual(resolver.verdict(for: "2.0.0"), .unsupported)
    }
}
