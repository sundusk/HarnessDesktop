import Foundation

/// 一个 loopback-only 的 Harness 端点。
///
/// V1 只允许 loopback 地址：`127.0.0.1` / `localhost` / `::1`。
struct HarnessEndpoint: Equatable, Sendable {
    let baseURL: URL

    /// 默认端点：`http://127.0.0.1:3080/`。
    static let `default`: HarnessEndpoint = {
        // URL 是静态字面量，构造必然成功；此处 force unwrap 是静态保证的。
        let url = URL(string: "http://127.0.0.1:3080/")!
        return HarnessEndpoint(unchecked: url)
    }()

    /// 从 host / port 构造。host 必须是允许的 loopback 名称。
    init?(host: String, port: Int, scheme: String = "http") {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isAllowedLoopbackHost(trimmed) else { return nil }
        guard (1...65535).contains(port) else { return nil }
        let hostLiteral = Self.bracketedIPv6(trimmed)
        guard let url = URL(string: "\(scheme)://\(hostLiteral):\(port)/") else { return nil }
        self.baseURL = url
    }

    /// 从任意 URL 校验构造。仅接受 loopback origin。
    init?(validating url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        guard let host = url.host, Self.isAllowedLoopbackHost(host) else { return nil }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        guard (1...65535).contains(port) else { return nil }
        self.baseURL = url
    }

    private init(unchecked baseURL: URL) {
        self.baseURL = baseURL
    }

    /// 是否允许的 loopback host。
    static func isAllowedLoopbackHost(_ host: String) -> Bool {
        let normalized = host
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        return normalized == "127.0.0.1"
            || normalized == "localhost"
            || normalized == "::1"
    }

    /// IPv6 字面量构造 URL 时需要用方括号包裹。
    private static func bracketedIPv6(_ host: String) -> String {
        if host.contains(":") && !host.hasPrefix("[") {
            return "[\(host)]"
        }
        return host
    }
}
