import Foundation

/// 导航决策。
enum NavigationDecision: Equatable, Sendable {
    case allow
    case external(URL)
}

/// Harness 导航策略。
///
/// - 与端点同 origin 的 loopback 地址 → 在 WebView 内加载；
/// - 其余地址（GitHub / DeepSeek 官网 / 文档站 / 任意外部 HTTP(S) 地址等）→ 交给默认浏览器。
struct HarnessNavigationPolicy: Sendable {
    let allowedOrigin: URL

    init(endpoint: HarnessEndpoint) {
        self.allowedOrigin = endpoint.baseURL
    }

    func decision(for url: URL) -> NavigationDecision {
        guard let scheme = url.scheme?.lowercased() else {
            return .external(url)
        }
        switch scheme {
        case "http", "https":
            return isSameOrigin(url) ? .allow : .external(url)
        case "about":
            // about:blank 等内部页面不携带网络内容，允许在 WebView 内。
            return .allow
        default:
            return .external(url)
        }
    }

    /// 同 origin 判定：scheme + host + port 均与端点一致。
    private func isSameOrigin(_ url: URL) -> Bool {
        guard let urlScheme = url.scheme?.lowercased(),
              let urlHost = url.host?.lowercased(),
              let allowedScheme = allowedOrigin.scheme?.lowercased(),
              let allowedHost = allowedOrigin.host?.lowercased() else {
            return false
        }
        let urlPort = url.port ?? Self.defaultPort(for: urlScheme)
        let allowedPort = allowedOrigin.port ?? Self.defaultPort(for: allowedScheme)
        return urlScheme == allowedScheme
            && Self.normalizedHost(urlHost) == Self.normalizedHost(allowedHost)
            && urlPort == allowedPort
    }

    private static func defaultPort(for scheme: String) -> Int {
        scheme == "https" ? 443 : 80
    }

    /// 去除 IPv6 字面量的方括号，便于比较 host。
    private static func normalizedHost(_ host: String) -> String {
        host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }
}
