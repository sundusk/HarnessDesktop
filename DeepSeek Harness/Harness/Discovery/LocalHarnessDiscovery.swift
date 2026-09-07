import Foundation

/// V0.1 实现：只检测本地 loopback 端口（默认 `127.0.0.1:3080`）。
///
/// - 使用短超时 HTTP 请求；
/// - 返回 2xx / 3xx 即认为 Web 服务存在；401 / 403 也返回端点，交给连接层展示授权状态；
/// - 不扫描本机进程、不读取 shell、不读取 `~/.dsh`、不执行任何终端命令。
struct LocalHarnessDiscovery: HarnessDiscovering {
    let host: String
    let port: Int
    let timeout: TimeInterval
    let session: URLSession
    let authenticatedEndpoint: HarnessEndpoint?
    let useAuthenticatedURL: Bool

    init(host: String = "127.0.0.1",
         port: Int = 3080,
         timeout: TimeInterval = 1.5,
         session: URLSession = .shared) {
        self.host = host
        self.port = port
        self.timeout = timeout
        self.session = session
        self.authenticatedEndpoint = nil
        self.useAuthenticatedURL = false
    }

    init(endpoint: HarnessEndpoint,
         timeout: TimeInterval = 1.5,
         session: URLSession = .shared,
         useAuthenticatedURL: Bool = true) {
        self.host = endpoint.baseURL.host ?? "127.0.0.1"
        self.port = endpoint.baseURL.port ?? 80
        self.timeout = timeout
        self.session = session
        self.authenticatedEndpoint = endpoint.authenticatedURL == nil ? nil : endpoint
        self.useAuthenticatedURL = useAuthenticatedURL
    }

    func discover() async -> HarnessEndpoint? {
        guard let endpoint = authenticatedEndpoint ?? HarnessEndpoint(host: host, port: port) else {
            return nil
        }
        let probeURL = useAuthenticatedURL ? endpoint.browserURL : endpoint.baseURL
        var request = URLRequest(url: probeURL)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            if http.statusCode == 401 || http.statusCode == 403 {
                // 服务已存在但没有可用会话：交给统一连接层转为
                // authenticationRequired，而不是把它误报为「未运行」。
                AppLogger.discovery.info("Harness 已发现但需要授权：\(endpoint.baseURL.absoluteString, privacy: .public)")
                return endpoint
            }
            guard (200..<400).contains(http.statusCode) else {
                AppLogger.discovery.debug("Harness 响应非 2xx/3xx：\(http.statusCode, privacy: .public)")
                return nil
            }
            AppLogger.discovery.info("Harness 已发现：\(endpoint.baseURL.absoluteString, privacy: .public)")
            return endpoint
        } catch {
            AppLogger.discovery.debug("Harness 未发现：\(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
