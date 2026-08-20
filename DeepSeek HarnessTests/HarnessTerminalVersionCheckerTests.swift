import XCTest
@testable import DeepSeek_Harness

// MARK: - Mocks

/// 可注入终端命令执行（记录调用参数，返回预设输出；规格 §34：测试不真正起 Node / npm）。
final class MockShellCommandExecutor: ShellCommandExecuting, @unchecked Sendable {
    var result: Result<String, Error>
    private(set) var receivedArguments: [[String]] = []

    init(result: Result<String, Error>) {
        self.result = result
    }

    func run(_ executablePath: String, arguments: [String], timeout: TimeInterval) async throws -> String {
        receivedArguments.append(arguments)
        return try result.get()
    }
}

// MARK: - Tests

/// 终端命令版本检测（`npx -y @deepseek-ai/dsh --version` / `npm view ...`）与弹窗文案。
final class HarnessTerminalVersionCheckerTests: XCTestCase {

    // MARK: - parseVersionOutput

    func testParseVersionOutputSimple() throws {
        let version = try NpxInstalledVersionProvider.parseVersionOutput("0.1.0-rc.7\n")
        XCTAssertEqual(version, HarnessVersion("0.1.0-rc.7"))
    }

    func testParseVersionOutputTakesLastNonEmptyLine() throws {
        let output = "npm warn deprecated node-domexception@1.0.0\n0.1.0-rc.7\n"
        let version = try NpxInstalledVersionProvider.parseVersionOutput(output)
        XCTAssertEqual(version, HarnessVersion("0.1.0-rc.7"))
    }

    func testParseVersionOutputInvalid() {
        XCTAssertThrowsError(try NpxInstalledVersionProvider.parseVersionOutput("not a version")) { error in
            XCTAssertEqual(error as? HarnessTerminalVersionError,
                           .invalidVersionOutput("not a version"))
        }
        XCTAssertThrowsError(try NpxInstalledVersionProvider.parseVersionOutput(""))
    }

    // MARK: - popupContent（弹窗文案）

    func testPopupUpToDateWhenEqual() {
        let current = HarnessVersion("0.1.0-rc.7")!
        let content = HarnessVersionCheckPresenter.popupContent(status: .upToDate(current: current))
        XCTAssertEqual(content.title, "您使用的就是最新版本")
        XCTAssertTrue(content.detail.contains("0.1.0-rc.7"))
        XCTAssertFalse(content.detail.contains("npx -y"))
    }

    func testPopupUpToDateWhenLocalNewer() {
        let current = HarnessVersion("0.2.0")!
        let latest = HarnessVersion("0.1.0-rc.7")!
        let content = HarnessVersionCheckPresenter.popupContent(status: .aheadOfLatest(current: current, latestRelease: latest))
        XCTAssertEqual(content.title, "当前版本高于官方最新版本")
    }

    func testPopupUpdateAvailableSaysVersionCanBeInstalled() {
        let current = HarnessVersion("0.1.0-rc.7")!
        let latest = HarnessVersion("0.1.0-rc.8")!
        let content = HarnessVersionCheckPresenter.popupContent(
            status: .updateAvailable(current: current, latestRelease: latest, latestInstallable: latest)
        )
        XCTAssertEqual(content.title, "发现 DeepSeek Harness 新版本")
        XCTAssertTrue(content.detail.contains("新版本已经可以安装"))
    }

    func testPopupReleasePendingNPMDoesNotOfferInstallCommand() {
        let current = HarnessVersion("0.1.0-rc.7")!
        let release = HarnessVersion("0.1.0-rc.8")!
        let content = HarnessVersionCheckPresenter.popupContent(
            status: .releaseAvailableButNotInstallable(
                current: current,
                latestRelease: release,
                latestInstallable: current
            )
        )
        XCTAssertEqual(content.title, "发现 DeepSeek Harness 新版本")
        XCTAssertTrue(content.detail.contains("npm 尚未同步"))
        XCTAssertFalse(content.detail.contains("npx -y"))
    }

    func testPopupFailureWhenVersionUnknown() {
        let content = HarnessVersionCheckPresenter.popupContent(status: .unknown)
        XCTAssertEqual(content.title, "版本检测失败")
    }

    // MARK: - NpxInstalledVersionProvider（fake executor）

    func testNpxProviderPassesExpectedArguments() async throws {
        let executor = MockShellCommandExecutor(result: .success("0.1.0-rc.7\n"))
        var provider = NpxInstalledVersionProvider(executor: executor)
        provider.resolveExecutable = { name in
            XCTAssertEqual(name, "npx")
            return "/opt/homebrew/bin/npx"
        }
        let version = try await provider.fetchInstalledVersion()
        XCTAssertEqual(version, HarnessVersion("0.1.0-rc.7"))
        XCTAssertEqual(executor.receivedArguments, [["-y", "@deepseek-ai/dsh", "--version"]])
    }

    func testNpxProviderThrowsWhenExecutableMissing() async {
        let executor = MockShellCommandExecutor(result: .success("0.1.0-rc.7\n"))
        var provider = NpxInstalledVersionProvider(executor: executor)
        provider.resolveExecutable = { _ in nil }
        do {
            _ = try await provider.fetchInstalledVersion()
            XCTFail("应抛出 executableNotFound")
        } catch {
            XCTAssertEqual(error as? HarnessTerminalVersionError, .executableNotFound("npx"))
        }
    }

    func testNpxProviderPropagatesExecutorError() async {
        let executor = MockShellCommandExecutor(result: .failure(HarnessTerminalVersionError.commandFailed("/bin/npx", 1)))
        var provider = NpxInstalledVersionProvider(executor: executor)
        provider.resolveExecutable = { _ in "/bin/npx" }
        do {
            _ = try await provider.fetchInstalledVersion()
            XCTFail("应抛出 commandFailed")
        } catch {
            XCTAssertEqual(error as? HarnessTerminalVersionError, .commandFailed("/bin/npx", 1))
        }
    }

    // MARK: - NpmViewLatestVersionProvider（fake executor）

    func testNpmViewProviderPassesExpectedArguments() async throws {
        let executor = MockShellCommandExecutor(result: .success("0.1.0-rc.7\n"))
        var provider = NpmViewLatestVersionProvider(executor: executor)
        provider.resolveExecutable = { name in
            XCTAssertEqual(name, "npm")
            return "/opt/homebrew/bin/npm"
        }
        let version = try await provider.fetchLatestInstallableVersion()
        XCTAssertEqual(version, HarnessVersion("0.1.0-rc.7"))
        XCTAssertEqual(executor.receivedArguments, [["view", "@deepseek-ai/dsh", "version"]])
    }

    // MARK: - 真实 executor（仅 /bin/echo，不涉及 Node / npm）

    func testSystemShellCommandExecutorRunsEcho() async throws {
        let executor = SystemShellCommandExecutor()
        let output = try await executor.run("/bin/echo", arguments: ["0.1.0-rc.7"], timeout: 10)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "0.1.0-rc.7")
    }

    func testSystemShellCommandExecutorThrowsOnNonZeroExit() async {
        let executor = SystemShellCommandExecutor()
        do {
            _ = try await executor.run("/bin/sh", arguments: ["-c", "exit 3"], timeout: 10)
            XCTFail("应抛出 commandFailed")
        } catch {
            guard case .commandFailed(let path, let code) = error as? HarnessTerminalVersionError else {
                return XCTFail("错误类型不符：\(error)")
            }
            XCTAssertEqual(path, "/bin/sh")
            XCTAssertEqual(code, 3)
        }
    }
}
