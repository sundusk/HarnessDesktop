import Foundation

/// App-owned Runtime 目录布局（文档 §7.2 / §8.2 / §32）。
///
/// 结构：
/// ```text
/// <Application Support>/dev.deepseekharness.DeepSeekHarness/
/// ├── Runtime/
/// │   ├── node/            # App-owned Node Runtime（Release 携带，分架构）
/// │   ├── npm-cache/       # 私有 npm cache（npm_config_cache 指向这里）
/// │   └── state/
/// │       └── managed-runtime.json
/// └── ManagedHarnessHome/  # 隔离的 Harness 数据目录（DSH_HOME 指向这里）
/// ```
///
/// 安全要求（文档 §32）：
/// - App-owned Runtime 必须限制在固定根目录内；
/// - 禁止写 `/usr/local`、`/opt/homebrew`、`~/.npm`、`~/.nvm` 等系统 / 用户全局路径。
struct ManagedRuntimePaths: Equatable, Sendable {
    /// App 自己的 Application Support 根目录。
    let rootURL: URL

    /// 从 Application Support 根目录构造（目录不存在时由调用方创建）。
    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    /// 默认根目录：`Application Support/dev.deepseekharness.DeepSeekHarness/`。
    /// 沙盒容器下取容器内的 Application Support；取不到返回 nil。
    static func makeDefault() -> ManagedRuntimePaths? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return ManagedRuntimePaths(rootURL: base.appendingPathComponent("dev.deepseekharness.DeepSeekHarness", isDirectory: true))
    }

    // MARK: - 子目录

    /// `Runtime/` 根。
    var runtimeDir: URL { rootURL.appendingPathComponent("Runtime", isDirectory: true) }

    /// App-owned Node Runtime（Release 内嵌或已解包的 Node 二进制所在目录）。
    var nodeDir: URL { runtimeDir.appendingPathComponent("node", isDirectory: true) }

    /// 私有 npm cache（`npm_config_cache`）。
    var npmCacheDir: URL { runtimeDir.appendingPathComponent("npm-cache", isDirectory: true) }

    /// 状态文件（managedVersion / previousManagedVersion 等）。
    var stateFile: URL { runtimeDir.appendingPathComponent("state/managed-runtime.json") }

    /// 隔离的 Harness 数据目录（`DSH_HOME`）。
    var managedHarnessHome: URL { rootURL.appendingPathComponent("ManagedHarnessHome", isDirectory: true) }

    // MARK: - 根目录限制（文档 §32）

    /// 候选路径是否位于 App-owned 根目录之内。
    ///
    /// 使用字符串规范化前缀比较；`..` / 软链等逃逸（无法解析时）一律视为越界。
    static func isInsideRoot(_ candidate: URL, root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return candidatePath.hasPrefix(prefix)
    }

    /// 子路径安全解析：只允许落在根目录内的相对路径（防路径穿越）。
    /// - Returns: nil = 相对路径包含 `..` / 绝对路径 / 越界。
    func child(relativePath: String, isDirectory: Bool) -> URL? {
        let cleaned = relativePath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !relativePath.hasPrefix("/"), !cleaned.isEmpty, !cleaned.contains("..") else { return nil }
        let url = cleaned.reduce(rootURL) { $0.appendingPathComponent($1, isDirectory: isDirectory) }
        guard Self.isInsideRoot(url, root: rootURL) else { return nil }
        return url
    }
}

/// 定位 App-owned Node Runtime（Release 携带，分架构；文档 §7.3）。
///
/// 布局（由 `Scripts/fetch-node-runtime.sh` 在 Release 构建时解包）：
/// ```text
/// <bundle>/Contents/Resources/Runtime/node/<arch>/bin/node
/// ```
enum BundledNodeRuntimeLocator {
    /// 当前架构名（与官方 Node 发布 tarball 目录一致）。
    static var currentArch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x64"
        #endif
    }

    /// 在 App bundle 中定位 Node 可执行文件（未携带 → nil）。
    static func bundledNodeURL(in bundle: Bundle = .main) -> URL? {
        guard let resources = bundle.resourceURL else { return nil }
        let node = resources
            .appendingPathComponent("Runtime/node/\(currentArch)/bin/node", isDirectory: false)
        return FileManager.default.isExecutableFile(atPath: node.path) ? node : nil
    }
}
