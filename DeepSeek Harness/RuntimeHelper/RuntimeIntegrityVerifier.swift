import Foundation
import CryptoKit

/// App-owned Node Runtime 二进制完整性校验（文档 §47：Runtime binary integrity verification）。
///
/// 机制：`Scripts/fetch-node-runtime.sh` 下载后在同一目录写入 `sha256.txt`
/// （`bin/node` 的 SHA-256）。准备 / 启动前校验二进制哈希与清单一致，
/// 防止发布包被篡改 / 损坏。
///
/// - 清单缺失（开发构建未跑 fetch 脚本）→ 跳过校验（视为未验证，记录日志）；
/// - 清单存在但哈希不匹配 → 校验失败（`runtimeIncompatible`，拒绝使用）。
enum RuntimeIntegrityVerifier {
    static let manifestName = "sha256.txt"

    /// 校验 Node 二进制。返回 nil = 通过（或清单缺失跳过）；返回错误说明 = 不通过。
    static func verify(nodeBinary: URL) -> IntegrityError? {
        let manifest = nodeBinary.deletingLastPathComponent().appendingPathComponent(manifestName)
        guard let expected = (try? String(contentsOf: manifest, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !expected.isEmpty else {
            return .manifestMissing
        }
        guard let data = try? Data(contentsOf: nodeBinary) else {
            return .unreadableBinary
        }
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        guard digest == expected else {
            return .hashMismatch(expected: expected, actual: digest)
        }
        return nil
    }

    enum IntegrityError: Equatable, Sendable {
        /// 清单缺失（开发构建）——不阻断，但记录。
        case manifestMissing
        case unreadableBinary
        case hashMismatch(expected: String, actual: String)
    }
}
