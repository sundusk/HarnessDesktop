import Foundation

/// 语义化版本（宽松解析）：`0.0.1`、`1.2.3-beta.1`、`v1.2.3` 均可解析。
///
/// 解析失败返回 nil（unknown version 不 crash，规格 33 验收）。
struct HarnessVersion: Comparable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    init?(_ string: String) {
        var trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("v") {
            trimmed.removeFirst()
        }
        // 去掉预发布/构建元数据后缀（"-beta.1"、"+build"）
        let pieces = trimmed.split(separator: "-", maxSplits: 1)
        guard let first = pieces.first, !first.isEmpty else { return nil }
        let core = first.split(separator: "+", maxSplits: 1)[0]
        let parts = core.split(separator: ".")
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        let values = parts.compactMap { Int($0) }
        guard !values.isEmpty, values.count == parts.count else { return nil }
        major = values[0]
        minor = values.count > 1 ? values[1] : 0
        patch = values.count > 2 ? values[2] : 0
    }

    static func < (lhs: HarnessVersion, rhs: HarnessVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }

    var description: String { "\(major).\(minor).\(patch)" }
}

/// 兼容性判定结果。
enum HarnessCompatibility: Equatable, Sendable {
    case supported
    case unsupported
    case unknown
}

/// Compatibility Resolver（规格 17 / 30.1）。
///
/// 判定规则：
/// - 版本缺失或无法解析 → `.unknown`（不 crash）；
/// - `supportedRange == nil`（未限定）→ 任何合法版本 `.supported`；
/// - 否则按版本范围判定 `.supported` / `.unsupported`。
///
/// Phase 3 默认未限定范围：未知版本的策略是「允许 Native（宽容前向兼容）」，
/// 网络 / 解析失败才进入 Degraded Mode。
struct HarnessCompatibilityResolver: Sendable {
    var supportedRange: ClosedRange<HarnessVersion>?

    func verdict(for versionString: String?) -> HarnessCompatibility {
        guard let versionString, let version = HarnessVersion(versionString) else {
            return .unknown
        }
        guard let supportedRange else { return .supported }
        return supportedRange.contains(version) ? .supported : .unsupported
    }
}
