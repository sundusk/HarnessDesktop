import Foundation

/// Native HTTP 与 WebSocket 共用的 Harness 会话。
///
/// HarnessDesktop 不生成 token、读取 credentials 或构造 Cookie；只让 Harness 官方
/// authenticated URL 完成一次 GET/redirect/cookie 交换。
final class HarnessNativeSession: @unchecked Sendable {
    let session: URLSession

    init(session: URLSession) {
        self.session = session
    }

    init(configuration: URLSessionConfiguration = .default) {
        let configuration = configuration
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        self.session = URLSession(configuration: configuration)
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
