import Foundation

/// 统一完成官方 token URL → Native Cookie 会话的启动鉴权。
struct HarnessAuthenticationCoordinator: Sendable {
    let sessionFactory: @Sendable () -> HarnessNativeSession

    init(sessionFactory: @escaping @Sendable () -> HarnessNativeSession = { HarnessNativeSession() }) {
        self.sessionFactory = sessionFactory
    }

    func authenticate(_ context: HarnessLaunchContext) async throws -> HarnessNativeSession {
        let session = sessionFactory()
        try await session.authenticate(authenticatedURL: context.authenticatedURL)
        return session
    }
}
