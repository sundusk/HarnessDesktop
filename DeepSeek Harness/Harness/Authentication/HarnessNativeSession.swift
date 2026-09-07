import Foundation

/// Native HTTP 与 WebSocket 共用的 Harness 会话。
///
/// HarnessDesktop 不生成 token、读取 credentials 或构造 Cookie；只让 Harness 官方
/// authenticated URL 完成一次 GET/redirect/cookie 交换。
final class HarnessNativeSession: @unchecked Sendable {
    let session: URLSession
    private let cookieStorage: HTTPCookieStorage

    init(session: URLSession) {
        self.session = session
        self.cookieStorage = session.configuration.httpCookieStorage ?? HTTPCookieStorage()
    }

    init(configuration: URLSessionConfiguration = .default) {
        var configuration = configuration
        let cookieStorage = configuration.httpCookieStorage ?? HTTPCookieStorage()
        configuration.httpCookieStorage = cookieStorage
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        self.cookieStorage = cookieStorage
        self.session = URLSession(configuration: configuration)
    }

    /// Copy WebKit-owned cookies into this Native session without constructing
    /// or interpreting Harness credentials.
    func setCookies(_ cookies: [HTTPCookie]) {
        // Do not call setCookies(_:for:mainDocumentURL:) with a nil URL. On
        // current macOS that path dereferences a null CFURL even for an empty
        // cookie list, which would crash during ordinary unauthenticated attach.
        for cookie in cookies {
            cookieStorage.setCookie(cookie)
        }
    }

    /// Return cookies that the official Harness URLSession received for this
    /// loopback endpoint, so WebView can use the same authenticated session.
    func cookies(for endpoint: HarnessEndpoint) -> [HTTPCookie] {
        cookieStorage.cookies(for: endpoint.baseURL) ?? []
    }

    func authenticate(authenticatedURL: URL?) async throws {
        guard let authenticatedURL else { return }

        var request = URLRequest(url: authenticatedURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HarnessAuthenticationError.invalidResponse
        }
        guard (200..<400).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw HarnessAuthenticationError.authenticationRequired
            }
            throw HarnessAuthenticationError.unexpectedStatus(http.statusCode)
        }
    }
}

enum HarnessAuthenticationError: Error, Equatable, Sendable {
    case authenticationRequired
    case unexpectedStatus(Int)
    case invalidResponse
}
