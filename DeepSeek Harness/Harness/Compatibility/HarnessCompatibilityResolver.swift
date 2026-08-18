import Foundation

/// 语义化版本（完整 SemVer 2.0 宽松解析）：`0.0.1`、`1.2.3`、`v1.2.3`、
/// `1.2.3-beta.1`、`0.1.0-rc.7`、`1.2.3+build5` 均可解析。
///
/// - 预发布（prerelease）参与优先级比较：`0.1.0-rc.7 < 0.1.0-rc.8`，
///   `1.0.0-alpha < 1.0.0-beta < 1.0.0`；
/// - 构建元数据（build metadata）**不参与**优先级比较（SemVer 2.0 §10）。
///
/// 解析失败返回 nil（unknown version 不 crash，规格 33 验收）。
/// Phase 8 起作为 App 统一的 Version Model（`host.describe.version` /
/// npm registry `dist-tags.latest` / Managed 版本记录共用）。
struct HarnessVersion: Comparable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    /// 预发布标识符（dot 分隔，SemVer 2.0 §9），如 `["rc", "7"]`；无预发布时为空数组。
    let prerelease: [String]
    /// 构建元数据（`+build5`）；不影响比较优先级。
    let buildMetadata: String?

    init(major: Int, minor: Int, patch: Int,
         prerelease: [String] = [],
         buildMetadata: String? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
        self.buildMetadata = buildMetadata
    }

    init?(_ string: String) {
        var trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.lowercased().hasPrefix("v") {
            trimmed.removeFirst()
        }
        // SemVer 2.0 语法：MAJOR.MINOR.PATCH[-PRERELEASE][+BUILD]
        // 注意 split 必须保留空子序列（omittingEmptySubsequences: false），
        // 否则 "1.2.3-" / "1.2.3-beta..1" 这类非法版本会被误判为合法。
        let buildParts = trimmed.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
        let coreAndPrerelease = buildParts[0]
        let build = buildParts.count > 1 ? String(buildParts[1]) : nil

        let dashParts = coreAndPrerelease.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = dashParts[0]
        let prereleaseString = dashParts.count > 1 ? String(dashParts[1]) : nil

        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        let values = parts.compactMap { Int($0) }
        guard !values.isEmpty, values.count == parts.count else { return nil }
        major = values[0]
        minor = values.count > 1 ? values[1] : 0
        patch = values.count > 2 ? values[2] : 0

        if let prereleaseString {
            let identifiers = prereleaseString.split(separator: ".", omittingEmptySubsequences: false)
            guard !identifiers.isEmpty else { return nil }
            for identifier in identifiers {
                // SemVer 2.0：标识符由 [0-9A-Za-z-] 组成且非空。宽松校验。
                guard !identifier.isEmpty,
                      identifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
                else { return nil }
            }
            prerelease = identifiers.map(String.init)
        } else {
            prerelease = []
        }
        buildMetadata = build.flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: - Comparable（SemVer 2.0 §11 优先级规则）

    static func == (lhs: HarnessVersion, rhs: HarnessVersion) -> Bool {
        // 优先级相等即相等：build metadata 被忽略。
        lhs.major == rhs.major
            && lhs.minor == rhs.minor
            && lhs.patch == rhs.patch
            && lhs.prerelease == rhs.prerelease
    }

    static func < (lhs: HarnessVersion, rhs: HarnessVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        // 核心版本相同 → 按预发布规则比较。
        // 有预发布 < 无预发布（例如 1.0.0-alpha < 1.0.0）。
        if lhs.prerelease.isEmpty && !rhs.prerelease.isEmpty { return false }
        if !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty { return true }
        if lhs.prerelease.isEmpty && rhs.prerelease.isEmpty { return false }
        return comparePrerelease(lhs.prerelease, rhs.prerelease) == .orderedAscending
    }

    /// 预发布标识符逐段比较。数字标识符按数值比较；字母数字标识符按 ASCII 字典序；
    /// 数字标识符优先级低于字母数字标识符；前缀相等时字段更多者优先级更高。
    private static func comparePrerelease(_ lhs: [String], _ rhs: [String]) -> ComparisonResult {
        let count = min(lhs.count, rhs.count)
        for index in 0..<count {
            let a = lhs[index]
            let b = rhs[index]
            let aNumeric = Int(a)
            let bNumeric = Int(b)
            switch (aNumeric, bNumeric) {
            case let (x?, y?):
                if x != y { return x < y ? .orderedAscending : .orderedDescending }
            case (_?, nil):
                // 数字标识符 < 字母数字标识符
                return .orderedAscending
            case (nil, _?):
                return .orderedDescending
            case (nil, nil):
                if a != b { return a < b ? .orderedAscending : .orderedDescending }
            }
        }
        if lhs.count == rhs.count { return .orderedSame }
        // 前缀相同：字段更多者优先级更高（1.0.0-alpha < 1.0.0-alpha.1）。
        return lhs.count < rhs.count ? .orderedAscending : .orderedDescending
    }

    var description: String {
        var result = "\(major).\(minor).\(patch)"
        if !prerelease.isEmpty {
            result += "-" + prerelease.joined(separator: ".")
        }
        if let buildMetadata {
            result += "+" + buildMetadata
        }
        return result
    }
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
