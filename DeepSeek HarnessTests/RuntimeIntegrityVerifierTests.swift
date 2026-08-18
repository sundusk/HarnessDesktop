import XCTest
import CommonCrypto
@testable import DeepSeek_Harness

/// Phase 14：Runtime 二进制完整性校验（文档 §47）。
final class RuntimeIntegrityVerifierTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("integrity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private var binDir: URL { tempDir.appendingPathComponent("bin") }

    private func writeManifest(_ content: String) throws {
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try content.write(to: binDir.appendingPathComponent("sha256.txt"), atomically: true, encoding: .utf8)
    }

    private func sha256Hex(of url: URL) -> String {
        let data = try! Data(contentsOf: url)
        return data.withUnsafeBytes { bytes in
            var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            CC_SHA256(bytes.baseAddress, CC_LONG(data.count), &hash)
            return hash.map { String(format: "%02x", $0) }.joined()
        }
    }

    func testVerifyPassesWhenHashMatches() throws {
        let binary = binDir.appendingPathComponent("node")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try Data("node-binary-content".utf8).write(to: binary)
        try writeManifest(sha256Hex(of: binary))

        XCTAssertNil(RuntimeIntegrityVerifier.verify(nodeBinary: binary))
    }

    func testVerifyFailsOnHashMismatch() throws {
        let binary = binDir.appendingPathComponent("node")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try Data("node-binary-content".utf8).write(to: binary)
        try writeManifest(String(repeating: "0", count: 64))

        let error = RuntimeIntegrityVerifier.verify(nodeBinary: binary)
        if case .hashMismatch = error {
            XCTAssertTrue(true)
        } else {
            XCTFail("应返回 hashMismatch，实际 \(String(describing: error))")
        }
    }

    func testVerifySkipsWhenManifestMissing() throws {
        // 开发构建未跑 fetch 脚本 → 清单缺失 → 跳过（不阻断）
        let binary = binDir.appendingPathComponent("node")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try Data("node-binary-content".utf8).write(to: binary)

        let error = RuntimeIntegrityVerifier.verify(nodeBinary: binary)
        XCTAssertEqual(error, .manifestMissing)
    }

    func testVerifyFailsOnUnreadableBinary() throws {
        try writeManifest(String(repeating: "a", count: 64))
        let missing = binDir.appendingPathComponent("node")
        let error = RuntimeIntegrityVerifier.verify(nodeBinary: missing)
        XCTAssertEqual(error, .unreadableBinary)
    }
}
