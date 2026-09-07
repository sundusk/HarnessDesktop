import AppKit
import Foundation
import Observation
import WebKit

/// Harness Web UI 的视图模型。
///
/// 只负责：加载页面、reload、页面加载状态、导航控制、错误信息、外部链接处理。
/// 禁止：注入状态监听 JavaScript、修改 Harness DOM/CSS、hook fetch/WebSocket、按 DOM 推断状态。
@MainActor
@Observable
final class HarnessWebViewModel {
    let endpoint: HarnessEndpoint
    let webView: WKWebView

    var isLoading = false
    var canGoBack = false
    var canGoForward = false
    var pageTitle: String?
    var navigationError: String?

    private let coordinator: NavigationCoordinator

    init(endpoint: HarnessEndpoint) {
        self.endpoint = endpoint
        let configuration = WKWebViewConfiguration()
        // 持久化数据存储：保留 Harness Web UI 自己的合法浏览器状态（Cookie / LocalStorage / IndexedDB / Cache）。
        configuration.websiteDataStore = .default()
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
    /// 认证策略：
    /// - endpoint 带一次性认证入口（本 App 启动的 source/npm 实例捕获了 `dsh web: ...?token=`）
    ///   → 直接加载该 URL，由 Harness 完成 token→cookie 交换；
    /// - 否则（**外部启动**：手动 `dsh web` / 终端 / 源码）→ 尝试读取 `~/.dsh` 的持久化
    ///   browser-session secret，为当前 endpoint 构造合法 `dsh-auth-*` cookie 并先注入
    ///   WKWebView，再加载干净 URL。注入失败不阻塞加载（不崩溃），只回退到裸 URL。
    func loadInitial() {
        navigationError = nil
        guard endpoint.authenticatedURL == nil else {
            webView.load(URLRequest(url: endpoint.browserURL))
            return
        }
        let targetURL = endpoint.browserURL
        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        Task { [webView] in
            guard let cookie = Self.makeSessionCookie(for: endpoint) else {
                AppLogger.webview.info("浏览器会话认证不可用（无持久化 secret），按裸 URL 加载")
                await MainActor.run { webView.load(URLRequest(url: targetURL)) }
                return
            }
            guard let httpCookie = cookie.makeHTTPCookie(endpoint: endpoint) else {
                await MainActor.run { webView.load(URLRequest(url: targetURL)) }
                return
            }
            // 先注入 cookie 再加载：确保首个请求与 WebSocket 握手都带认证。
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                cookieStore.setCookie(httpCookie) { cont.resume() }
            }
            AppLogger.webview.info("已注入浏览器会话 cookie（authority \(cookie.authority, privacy: .public)）")
            await MainActor.run { webView.load(URLRequest(url: targetURL)) }
        }
    }

    /// 构造可注入的浏览器会话 cookie；失败返回 nil（读取 `~/.dsh` 只读，绝不破坏）。
    @MainActor
    static func makeSessionCookie(for endpoint: HarnessEndpoint) -> HarnessBrowserSessionCookie? {
        do {
            return try HarnessBrowserSessionAuth.makeCookie(endpoint: endpoint)
        } catch let error as HarnessBrowserSessionAuthError {
            AppLogger.webview.debug("浏览器会话认证构造失败：\(String(describing: error), privacy: .public)")
            return nil
        } catch {
            AppLogger.webview.debug("浏览器会话认证读取失败：\(String(describing: error), privacy: .public)")
            return nil
        }
    }

    func reload() {
        navigationError = nil
        webView.reload()
    }

    /// 在默认浏览器中打开 Harness。
    func openInBrowser() {
        NSWorkspace.shared.open(endpoint.browserURL)
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
