import SwiftUI
import WebKit

/// `WKWebView` 的 SwiftUI 包装。
///
/// 直接承载官方 Harness Web UI，不做中间 Web 前端。
@MainActor
struct HarnessWebView: NSViewRepresentable {
    let model: HarnessWebViewModel

    func makeNSView(context: Context) -> WKWebView {
        model.webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // WebView 生命周期由 ViewModel 管理。
    }
}
