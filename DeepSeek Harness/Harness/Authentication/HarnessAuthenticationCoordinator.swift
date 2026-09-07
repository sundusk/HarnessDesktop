import Foundation

/// 统一完成官方 token URL → Native Cookie 会话的启动鉴权。
struct HarnessAuthenticationCoordinator: Sendable {
    let sessionFactory: @Sendable () -> HarnessNativeSession

    init(sessionFactory: @escaping @Sendable () -> HarnessNativeSession = { HarnessNativeSession() }) {
        self.sessionFactory = sessionFactory
    }

    func authenticate(_ context: HarnessLaunchContext) async throws -> HarnessNativeSession {
        let session = sessionFactory()
        return try await authenticate(context, using: session)
    }

    /// Authenticate a caller-owned session after any existing WebView cookies
    /// have been copied into it. This keeps Web and Native on one auth state.
    func authenticate(_ context: HarnessLaunchContext,
                      using session: HarnessNativeSession) async throws -> HarnessNativeSession {
        try await session.authenticate(authenticatedURL: context.authenticatedURL)
        return session
    }
}
