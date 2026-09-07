import Foundation

/// Harness 的启动方式。不同启动器只负责产生进程和 stdout，后续连接流程统一。
enum HarnessLaunchMode: String, CaseIterable, Sendable {
    case npx
    case source
}

/// 启动层交给 Web / Native 层的唯一上下文。
///
/// authenticatedURL 只在当前连接生命周期内存在，不写入设置、日志或诊断数据。
struct HarnessLaunchContext: Equatable, Sendable {
    let endpoint: HarnessEndpoint
    let authenticatedURL: URL?
    let pid: Int32?

    init(endpoint: HarnessEndpoint, pid: Int32? = nil) {
        self.endpoint = endpoint
        self.authenticatedURL = endpoint.authenticatedURL
        self.pid = pid
    }

    init?(authenticatedURL: URL, pid: Int32? = nil) {
        guard let endpoint = HarnessEndpoint(authenticatedURL: authenticatedURL) else { return nil }
        self.init(endpoint: endpoint, pid: pid)
    }

    /// 首次 WebView 加载地址。认证成功后的 reload 应使用 endpoint.baseURL。
    var browserURL: URL {
        authenticatedURL ?? endpoint.baseURL
    }
}

/// 从官方 `dsh web: <url>` 输出中提取启动地址。
///
/// 解析器只验证 URL 结构和 loopback 范围，不读取 token 内容，也不记录 token。
enum HarnessLaunchURLParser {
    static let marker = "dsh web:"

    static func authenticatedURL(from line: String) -> URL? {
        guard let markerRange = line.range(of: marker) else { return nil }
        let candidate = line[markerRange.upperBound...]
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .first
            .map(String.init)
        guard let candidate,
              let url = URL(string: candidate),
              let endpoint = HarnessEndpoint(authenticatedURL: url) else {
            return nil
        }
        return endpoint.authenticatedURL
    }
}
