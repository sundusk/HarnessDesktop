import CryptoKit
import Foundation

/// Harness 浏览器会话认证（客户端侧构造）。
///
/// 背景：新版 Harness（dsh v0.1.2 起 / 本机 0.1.3-alpha.1 源码版）在 Web 层强制
/// **进程级一次性 token + 持久签名 cookie** 的认证模型（见上游
/// `packages/client/connection/src/browser-auth.ts`）。桌面客户端 attach 一个
/// **外部启动**（手动 `dsh web` / 源码 / 终端）的 server 时，拿不到该进程的一次性
/// launch token，因此 WKWebView 加载裸 `http://127.0.0.1:<port>/` 会命中 401 认证栅栏，
/// 进而 `/api/*` 与 `/api/remote.mux`（承载思考/回答的流式增量）全部失败——
/// 表现为「会话正文空白、只有思考没有回答」。
///
/// 关键事实：**cookie 的签名密钥是持久化在磁盘的**（`~/.dsh/.credentials.yaml` 里的
/// `client-connection/browser-session` 记录），而不是那个一次性 token。因此客户端无需
/// 依赖 server 是谁启动的，也无需当前进程的 token，只要读取同一份持久化 secret，
/// 按 Harness 的算法为**当前 endpoint** 构造一个合法 `dsh-auth-*` cookie 并注入
/// WKWebView，即可通过认证栅栏。这完全符合「客户端只是显示 Web UI、不因 server
/// 启动方式而受限」的设计初衷。
///
/// 仅只读 `~/.dsh`；绝不写入、删除或修改 Harness 数据（Zero Mutation）。
struct HarnessBrowserSessionAuth: Sendable {
    /// 上游 `credentials/credentials/src/index.ts` 的 `credentialKey("client-connection","browser-session")`。
    static let credentialKey = "client-connection/browser-session"
    /// 上游 cookie 前缀：`COOKIE_PREFIX = 'dsh-auth-'`。
    static let cookiePrefix = "dsh-auth-"
    /// 上游 `COOKIE_PAYLOAD_VERSION = 1`。
    static let cookiePayloadVersion = 1
    /// 上游 `STORED_SECRET_VERSION = 1`。
    static let storedSecretVersion = 1
    /// 上游默认 `cookieMaxAgeDays`（`z.natural().min(1).default(30)`）。
    static let defaultCookieMaxAgeDays = 30
    /// 上游 `SECRET_BYTES = 32`。
    static let secretBytes = 32

    /// 构造并校验一个 `HarnessBrowserSessionCookie`。
    ///
    /// - Returns: 成功返回可注入的 cookie；失败抛出 `HarnessBrowserSessionAuthError`，绝不崩溃。
    static func makeCookie(endpoint: HarnessEndpoint,
                           credentialYAML: Data,
                           homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                           maxAgeDays: Int = HarnessBrowserSessionAuth.defaultCookieMaxAgeDays) throws -> HarnessBrowserSessionCookie {
        let authority = try requireAuthority(endpoint: endpoint)
        let secret = try requireSecret(from: credentialYAML, homeDirectory: homeDirectory)
        return try encodeCookie(authority: authority, secret: secret, maxAgeDays: maxAgeDays)
    }

    /// 从真实 `~/.dsh/.credentials.yaml` 读取 secret 并构造 cookie 的便捷入口。
    static func makeCookie(endpoint: HarnessEndpoint,
                           homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                           maxAgeDays: Int = HarnessBrowserSessionAuth.defaultCookieMaxAgeDays) throws -> HarnessBrowserSessionCookie {
        let credentialsURL = try credentialsURL(homeDirectory: homeDirectory)
        let data = try Data(contentsOf: credentialsURL)
        return try makeCookie(endpoint: endpoint, credentialYAML: data, homeDirectory: homeDirectory, maxAgeDays: maxAgeDays)
    }

    // MARK: - origin

    /// 上游 `requestAuthority`：`new URL("http://<host>").host`，即 `host[:port]`。
    /// endpooint 只允许 loopback（127.0.0.1 / localhost / ::1），此处强制 `host:port` 形式。
    static func requireAuthority(endpoint: HarnessEndpoint) throws -> String {
        let host = endpoint.baseURL.host ?? ""
        let port = endpoint.baseURL.port ?? (endpoint.baseURL.scheme == "https" ? 443 : 80)
        guard Self.isLoopbackAuthority(host: host, port: port) else {
            throw HarnessBrowserSessionAuthError.nonLoopbackAuthority
        }
        return "\(host):\(port)"
    }

    private static func isLoopbackAuthority(host: String, port: Int) -> Bool {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        return (normalized == "127.0.0.1" || normalized == "localhost" || normalized == "::1")
            && (1...65535).contains(port)
    }

    // MARK: - secret

    /// 读取 `~/.dsh/.credentials.yaml` 中 `records.client-connection/browser-session.payload.secret`，
    /// 校验为 32 字节的 base64url（`canonicalSecret`）。
    static func requireSecret(from yaml: Data, homeDirectory: URL) throws -> Data {
        guard let text = String(data: yaml, encoding: .utf8) else {
            throw HarnessBrowserSessionAuthError.unreadableCredentials
        }
        let root = try parseYAMLMappings(text)
        let key = credentialKey
        // 结构：records.<key>.payload.secret
        guard case .mapping(let records) = root["records"] else {
            throw HarnessBrowserSessionAuthError.missingCredentialRecord(key)
        }
        guard let recordValue = records[key] else {
            throw HarnessBrowserSessionAuthError.missingCredentialRecord(key)
        }
        guard case .mapping(let record) = recordValue else {
            throw HarnessBrowserSessionAuthError.malformedCredentialRecord
        }
        guard case .mapping(let payload) = record["payload"] else {
            throw HarnessBrowserSessionAuthError.malformedCredentialRecord
        }
        guard case .scalar(let secretB64URL) = payload["secret"] else {
            throw HarnessBrowserSessionAuthError.malformedCredentialRecord
        }
        guard let decoded = Self.base64URLDecode(secretB64URL), decoded.count == secretBytes else {
            throw HarnessBrowserSessionAuthError.invalidSecret
        }
        return decoded
    }

    // MARK: - cookie encode

    /// 复刻 `encodeCookie(payload, secret)`：`v1.<body>.<sig>` 其中 body = base64url(JSON(payload))，
    /// sig = base64url(HMAC-SHA256(secret, body))。使用当前时间签发。
    static func encodeCookie(authority: String, secret: Data, maxAgeDays: Int) throws -> HarnessBrowserSessionCookie {
        let now = Date.now
        let issuedAtMs = Int64(now.timeIntervalSince1970 * 1000)
        return try encodeCookie(authority: authority, secret: secret,
                                issuedAtMs: issuedAtMs, maxAgeDays: maxAgeDays)
    }

    /// 可注入固定签发时间的内部方法（测试复刻上游黄金值用）。
    static func encodeCookie(authority: String, secret: Data,
                             issuedAtMs: Int64, maxAgeDays: Int) throws -> HarnessBrowserSessionCookie {
        let maxAgeMs = Int64(maxAgeDays) * 24 * 60 * 60 * 1000
        let expiresAtMs = issuedAtMs + maxAgeMs
        guard issuedAtMs > 0, expiresAtMs > issuedAtMs else {
            throw HarnessBrowserSessionAuthError.invalidTimeRange
        }
        let payload = HarnessBrowserSessionPayload(version: cookiePayloadVersion,
                                                   authority: authority,
                                                   issuedAt: issuedAtMs,
                                                   expiresAt: expiresAtMs)
        let json = payload.stringify()
        let body = Self.base64URLEncode(Data(json.utf8))
        let sig = Self.base64URLEncode(Self.hmacSHA256(key: secret, message: Data(body.utf8)))
        let value = "v1.\(body).\(sig)"
        let name = cookiePrefix + Self.base64URLEncode(Self.sha256(Data(authority.utf8)))
        return HarnessBrowserSessionCookie(name: name, value: value, authority: authority,
                                           issuedAt: issuedAtMs, expiresAt: expiresAtMs, maxAgeSeconds: maxAgeMs / 1000)
    }

    // MARK: - crypto

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode(_ string: String) -> Data? {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = (4 - s.count % 4) % 4
        if pad > 0 { s += String(repeating: "=", count: pad) }
        return Data(base64Encoded: s)
    }

    static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    static func hmacSHA256(key: Data, message: Data) -> Data {
        let key = SymmetricKey(data: key)
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
    }

    // MARK: - credentials path

    static func credentialsURL(homeDirectory: URL) throws -> URL {
        let url = homeDirectory.appendingPathComponent(".dsh", isDirectory: true)
            .appendingPathComponent(".credentials.yaml")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw HarnessBrowserSessionAuthError.missingCredentialsFile(url.path)
        }
        return url
    }

    // MARK: - 最小 YAML 解析（仅够读取本记录结构）

    /// 纵深的映射/标量值。只解析 `key: value`、`key:`（块）、嵌套缩进、剔除行内注释；
    /// 不做 anchors/多行块标量等 YAML 全特性——`~/.dsh/.credentials.yaml` 是 credentials
    /// 专用简单结构（见 `credentials` 包的序列化器）。
    enum YAMLValue: Equatable {
        case scalar(String)
        case mapping([String: YAMLValue])
    }

    /// 把 YAML 文本解析为顶层映射（`parseYAMLMappings` 的轻量复刻）。
    static func parseYAMLMappings(_ text: String) throws -> [String: YAMLValue] {
        let lines = text.components(separatedBy: .newlines)
        let (value, _) = parseBlock(lines: lines, startIndex: 0, indent: 0)
        guard case .mapping(let result) = value else {
            throw HarnessBrowserSessionAuthError.unreadableCredentials
        }
        return result
    }

    /// 从 `startIndex` 起、以 `indent` 为基准解析一个映射块。
    ///
    /// YAML 缩进规则（最小实现）：本层键缩进 == `indent`；`key:` 的子树缩进 > `indent`，
    /// 其基准取子树首行的实际缩进；缩进 < `indent` 则本块结束。返回 (值, 消耗的行数)。
    static func parseBlock(lines: [String], startIndex: Int, indent: Int) -> (YAMLValue, Int) {
        var cursor = startIndex
        var collected: [String: YAMLValue] = [:]
        // 上一个刚落地、值为空 mapping 的键；若下一个更高缩进子树出现，则挂到它名下。
        var pendingKey: String?

        func flushPending(_ value: YAMLValue) {
            guard let key = pendingKey else { return }
            collected[key] = value
            pendingKey = nil
        }

        while cursor < lines.count {
            let raw = lines[cursor]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                cursor += 1
                continue
            }
            let lineIndent = Self.leadingSpaces(raw)

            if lineIndent > indent {
                // 属于 pendingKey 的子树：递归解析并以其为基准。
                let (child, consumed) = parseBlock(lines: lines, startIndex: cursor, indent: lineIndent)
                if consumed > 0 {
                    flushPending(child)
                    cursor += consumed
                    continue
                }
            }
            if lineIndent < indent {
                break
            }

            guard let colon = trimmed.firstIndex(of: ":") else {
                cursor += 1
                continue
            }
            let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
            let rest = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)

            if rest.isEmpty {
                collected[key] = .mapping([:])
                pendingKey = key
                cursor += 1
            } else {
                flushPending(.mapping([:]))  // 清掉残留 pending（不会发生，保险）
                collected[key] = .scalar(Self.stripInlineComment(rest))
                cursor += 1
            }
        }
        return (.mapping(collected), cursor - startIndex)
    }

    private static func leadingSpaces(_ line: String) -> Int {
        line.prefix(while: { $0 == " " }).count
    }

    private static func stripInlineComment(_ value: String) -> String {
        // 仅剔除前面有空格分隔的 `#`；避免误伤值内包含的 #。
        if let hash = value.firstIndex(of: "#"), hash != value.startIndex {
            let previous = value[value.index(before: hash)]
            if previous == " " { return String(value[..<hash]).trimmingCharacters(in: .whitespaces) }
        }
        return value
    }
}

/// 已构造并校验通过、可注入 WKWebView 的浏览器会话 cookie。
struct HarnessBrowserSessionCookie: Equatable, Sendable {
    /// 完整 cookie 名（`dsh-auth-<base64url sha256(authority)>`）。
    let name: String
    /// 完整 cookie 值（`v1.<body>.<sig>`）。
    let value: String
    /// 绑定的 authority（`host:port`）。
    let authority: String
    /// 签发时间戳（毫秒）。
    let issuedAt: Int64
    /// 过期时间戳（毫秒）。
    let expiresAt: Int64
    /// `Max-Age` 秒数。
    let maxAgeSeconds: Int64

    /// 生成 `NSHTTPCookie`（供 WKWebView 的 `httpCookieStore` 使用）。
    /// domain 取 authority 的 host（不含端口），path = "/"。
    func makeHTTPCookie(endpoint: HarnessEndpoint) -> HTTPCookie? {
        let host = endpoint.baseURL.host ?? authority
        let properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: host,
            .path: "/",
            .version: 0,
            .expires: Date(timeIntervalSince1970: Double(expiresAt) / 1000.0),
        ]
        return HTTPCookie(properties: properties)
    }
}

/// cookie payload（复刻上游 `BrowserCookiePayload`）。
///
/// 注意 JSON 键顺序必须与上游 `JSON.stringify(payload)` 一致：
/// `version → authority → issuedAt → expiresAt`。签名是对 base64url(JSON) 的 HMAC，
/// 键顺序若与上游不一致，同一输入会算出不同签名，导致 cookie 被服务端拒收。
private struct HarnessBrowserSessionPayload: Codable {
    let version: Int
    let authority: String
    let issuedAt: Int64
    let expiresAt: Int64
}

extension HarnessBrowserSessionPayload {
    /// 按上游 `JSON.stringify` 的字段顺序手工序列化（不经 KeyedContainer 的键排序）。
    func stringify() -> String {
        "{\"version\":\(version),\"authority\":\"\(authority)\",\"issuedAt\":\(issuedAt),\"expiresAt\":\(expiresAt)}"
    }
}

/// Harness 浏览器会话认证错误。
enum HarnessBrowserSessionAuthError: Error, Equatable, Sendable {
    case missingCredentialsFile(String)
    case unreadableCredentials
    case missingCredentialRecord(String)
    case malformedCredentialRecord
    case invalidSecret
    case nonLoopbackAuthority
    case invalidTimeRange
}
