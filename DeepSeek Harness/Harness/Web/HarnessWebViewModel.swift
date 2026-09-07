import AppKit
import Foundation
import Observation
import WebKit

/// Harness Web UI 的视图模型。
///
/// 只负责：加载页面、reload、页面加载状态、导航控制、错误信息、外部链接处理。
/// 不参与 Harness 业务状态：不修改 DOM/CSS，不 hook fetch/WebSocket，不按 DOM 推断状态。
/// 仅在页面脚本启动前安装引擎兼容垫片，修复 WebKit 与 Chromium 对原生函数源码
/// 格式化不同导致的官方历史回放校验失败。
@MainActor
@Observable
final class HarnessWebViewModel {
    let endpoint: HarnessEndpoint
    /// 仅用于首次加载；认证完成后的 reload 永远回到 endpoint.baseURL。
    let launchURL: URL?
    let webView: WKWebView

    var isLoading = false
    var canGoBack = false
    var canGoForward = false
    var pageTitle: String?
    var navigationError: String?

    private let coordinator: NavigationCoordinator

    init(endpoint: HarnessEndpoint, launchURL: URL? = nil) {
        self.endpoint = endpoint
        self.launchURL = launchURL
        let configuration = WKWebViewConfiguration()
        // 持久化数据存储：保留 Harness Web UI 自己的合法浏览器状态（Cookie / LocalStorage / IndexedDB / Cache）。
        configuration.websiteDataStore = .default()
        HarnessWebKitCompatibility.install(in: configuration)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        self.webView = webView
        let coordinator = NavigationCoordinator(policy: HarnessNavigationPolicy(endpoint: endpoint))
        self.coordinator = coordinator
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        coordinator.model = self
    }

    /// 加载初始页面。
    ///
    /// 认证入口由启动层提供。WebView 不解析 stdout、读取 credentials 或生成 Cookie。
    ///
    /// When Native has already exchanged the official launch URL, install the
    /// returned cookies first and load the clean origin. This avoids making
    /// WebView and URLSession race over the launch URL while keeping both
    /// transports on the same server-issued session.
    func loadInitial(authenticatedCookies: [HTTPCookie] = []) {
        navigationError = nil
        if !authenticatedCookies.isEmpty {
            loadBaseURL(afterInstalling: authenticatedCookies)
            return
        }
        load(URL: launchURL ?? endpoint.baseURL)
    }

    /// Reuse a previously authenticated WebView session for Native requests.
    /// This is needed when attaching to a Harness that was started elsewhere.
    func transferStoredCookies(to nativeSession: HarnessNativeSession) async {
        let endpoint = endpoint
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let cookies = await withCheckedContinuation { continuation in
            store.getAllCookies { cookies in
                continuation.resume(returning: cookies.filter {
                    Self.cookie($0, matches: endpoint)
                })
            }
        }
        nativeSession.setCookies(cookies)
    }

    func reload() {
        navigationError = nil
        webView.reloadFromOrigin()
    }

    /// 在默认浏览器中打开 Harness。
    func openInBrowser() {
        NSWorkspace.shared.open(endpoint.baseURL)
    }

    func goBack() {
        webView.goBack()
    }

    func goForward() {
        webView.goForward()
    }

    fileprivate func refreshNavigationState() {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        pageTitle = webView.title
    }

    private func loadBaseURL(afterInstalling cookies: [HTTPCookie]) {
        let webView = webView
        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        let baseURL = endpoint.baseURL
        Task { @MainActor in
            for cookie in cookies {
                await withCheckedContinuation { continuation in
                    cookieStore.setCookie(cookie) {
                        continuation.resume()
                    }
                }
            }
            load(URL: baseURL)
        }
    }

    private func load(URL url: URL) {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        webView.load(request)
    }

    private static func cookie(_ cookie: HTTPCookie, matches endpoint: HarnessEndpoint) -> Bool {
        guard let host = endpoint.baseURL.host?.lowercased() else {
            return false
        }
        if let expires = cookie.expiresDate, expires <= Date() {
            return false
        }
        let domain = cookie.domain
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        let hostMatches = host == domain || host.hasSuffix(".\(domain)")
        let schemeMatches = !cookie.isSecure || endpoint.baseURL.scheme?.lowercased() == "https"
        return hostMatches && schemeMatches
    }
}

/// WebKit-only compatibility for the official Harness Web UI.
///
/// The current upstream client validates streamed history records as lossless
/// JSON and identifies each realm's intrinsic Object/Array prototype by the
/// exact source string returned by `Function.prototype.toString`. Chromium
/// returns the expected one-line form, while WebKit may insert newlines and
/// indentation around `[native code]`. The resulting false negative aborts
/// the session event feed before assistant history is assembled.
///
/// This is deliberately limited to the page's JavaScript world and runs before
/// the official bundle. It does not read, rewrite, or synthesize Harness data.
enum HarnessWebKitCompatibility {
    static let nativeFunctionToStringNormalizationScript = #"""
(() => {
    const expectedObjectSource = 'function Object() { [native code] }'
    const originalToString = Function.prototype.toString
    if (originalToString.call(Object) === expectedObjectSource) return

    const marker = Symbol.for('dsh.webkit.nativeFunctionToStringNormalized')
    if (globalThis[marker]) return

    const normalizedToString = function () {
        const rendered = originalToString.call(this)
        return rendered.includes('[native code]')
            ? rendered.replace(/\s+/g, ' ')
            : rendered
    }
    Object.defineProperty(normalizedToString, 'name', { value: 'toString' })
    Object.defineProperty(normalizedToString, 'length', { value: 0 })
    Object.defineProperty(Function.prototype, 'toString', {
        configurable: true,
        enumerable: false,
        writable: true,
        value: normalizedToString,
    })
    globalThis[marker] = true
})()
"""#

    static func install(in configuration: WKWebViewConfiguration) {
        let userScript = WKUserScript(
            source: nativeFunctionToStringNormalizationScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .page
        )
        configuration.userContentController.addUserScript(userScript)
    }
}

/// WKNavigationDelegate / WKUIDelegate。通过 weak model 回写状态，避免保留环。
@MainActor
private final class NavigationCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    private let policy: HarnessNavigationPolicy
    weak var model: HarnessWebViewModel?

    init(policy: HarnessNavigationPolicy) {
        self.policy = policy
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        switch policy.decision(for: url) {
        case .allow:
            return .allow
        case .external(let externalURL):
            AppLogger.webview.info("外部链接交给默认浏览器：\(externalURL.absoluteString, privacy: .public)")
            NSWorkspace.shared.open(externalURL)
            return .cancel
        }
    }

    /// target=_blank 处理：内部地址在当前 WebView 加载，外部地址交给默认浏览器。
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            switch policy.decision(for: url) {
            case .allow:
                webView.load(URLRequest(url: url))
            case .external(let externalURL):
                NSWorkspace.shared.open(externalURL)
            }
        }
        return nil
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
        model?.isLoading = true
        model?.navigationError = nil
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation?) {
        model?.refreshNavigationState()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        model?.isLoading = false
        model?.refreshNavigationState()
        AppLogger.webview.info("Harness Web UI 页面加载完成")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) {
        handleFailure(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
        handleFailure(error)
    }

    private func handleFailure(_ error: Error) {
        // reload 等操作产生的取消错误不应作为失败展示。
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        model?.isLoading = false
        model?.navigationError = Self.describe(error)
        AppLogger.webview.error("页面加载失败：\(String(describing: error), privacy: .public)")
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        switch nsError.code {
        case NSURLErrorCannotConnectToHost,
             NSURLErrorCannotFindHost,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorNotConnectedToInternet:
            return "无法连接到 Harness"
        default:
            return nsError.localizedDescription
        }
    }
}
