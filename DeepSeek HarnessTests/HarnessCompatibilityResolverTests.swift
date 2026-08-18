import XCTest
@testable import DeepSeek_Harness

final class HarnessCompatibilityResolverTests: XCTestCase {

    func testVersionParsing() {
        XCTAssertEqual(HarnessVersion("0.0.1"), HarnessVersion(major: 0, minor: 0, patch: 1))
        XCTAssertEqual(HarnessVersion("1.2.3"), HarnessVersion(major: 1, minor: 2, patch: 3))
        XCTAssertEqual(HarnessVersion("v1.2.3"), HarnessVersion(major: 1, minor: 2, patch: 3))
        XCTAssertEqual(HarnessVersion("1.2.3-beta.1"), HarnessVersion(major: 1, minor: 2, patch: 3))
        XCTAssertEqual(HarnessVersion("1.2.3+build5"), HarnessVersion(major: 1, minor: 2, patch: 3))
        XCTAssertEqual(HarnessVersion("2"), HarnessVersion(major: 2, minor: 0, patch: 0))
        XCTAssertNil(HarnessVersion("garbage"))
        XCTAssertNil(HarnessVersion(""))
        XCTAssertNil(HarnessVersion("a.b.c"))
        XCTAssertNil(HarnessVersion("1.2.3.4"))
    }

    func testVersionComparison() {
        XCTAssertLessThan(HarnessVersion("1.2.3")!, HarnessVersion("1.2.4")!)
        XCTAssertLessThan(HarnessVersion("1.2.9")!, HarnessVersion("1.10.0")!)
        XCTAssertLessThan(HarnessVersion("0.9.9")!, HarnessVersion("1.0.0")!)
        XCTAssertEqual(HarnessVersion("1.2.3")!, HarnessVersion("1.2.3")!)
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
