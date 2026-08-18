import Foundation

/// 私有 npm cache 布局与环境变量（文档 §7.2 / §15 / §32）。
///
/// - Managed npm 必须设置自己的 cache：`npm_config_cache=<AppSupport>/Runtime/npm-cache`；
/// - 不得修改全局 npm config（不写 `~/.npmrc`）；
/// - Harness 本体不全局安装（禁止 `npm install -g`）。
enum ManagedPackageCache {
    /// 子进程环境：私有 cache + 隔离 HOME，避免污染用户环境。
    static func environment(for paths: ManagedRuntimePaths, extra: [String: String] = [:]) -> [String: String] {
        var env: [String: String] = [
            "npm_config_cache": paths.npmCacheDir.path,
            "npm_config_update_notifier": "false",
            "npm_config_fund": "false",
            "NO_UPDATE_NOTIFIER": "1",
        ]
        for (key, value) in extra {
            env[key] = value
        }
        return env
    }

    /// npm 拉取 exact 版本包的安装前缀目录（`Runtime/packages/<version>/`）。
    /// 版本字符串经长度 / 字符校验，防止路径穿越（文档 §32：版本字符串必须有长度限制）。
    static func packageDir(for paths: ManagedRuntimePaths, version: String) -> URL? {
        guard Self.isSafeVersionComponent(version) else { return nil }
        return paths.runtimeDir.appendingPathComponent("packages/\(version)", isDirectory: true)
    }

    /// 版本字符串安全校验：只允许 semver 字符（数字 / 点 / 短横线 / 加号），长度 ≤ 64。
    static func isSafeVersionComponent(_ version: String) -> Bool {
        guard !version.isEmpty, version.count <= 64 else { return false }
        return version.allSatisfy { $0.isASCII && ($0.isNumber || $0.isLetter || $0 == "." || $0 == "-" || $0 == "+") }
    }
}
