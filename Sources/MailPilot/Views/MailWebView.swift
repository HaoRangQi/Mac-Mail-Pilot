import AppKit
import SwiftUI
import WebKit

/// 邮件正文 WebView。**只加载本地 HTML 字符串，永不出网**：
/// 远程资源已被清洗层剥掉 + CSP `default-src 'none'` 双保险。
///
/// 链接策略（2026-10-25 定稿）：普通 http/https 链接直接开系统浏览器；
/// 带钓鱼特征的链接在清洗层被改写成 `mplink://` 内部协议，到这里弹确认。
struct MailWebView: NSViewRepresentable {
    let html: String
    /// (真实地址, 风险原因)。由调用方弹确认框
    let onSuspiciousLink: (URL, String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // nonPersistent：不落任何盘，WebView 关掉即焚
        config.websiteDataStore = .nonPersistent()
        // 注意：macOS 的 WKPreferences 没有 javaScriptCanOpenWindows（那是 iOS 独有）。
        // macOS 上阻断 window.open 靠下面的 WKUIDelegate.createWebViewWith 返回 nil

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        // 透明背景，融入外面的玻璃面板
        webView.setValue(false, forKey: "drawsBackground")

        // 第二层消毒：DOMPurify 在文档解析前注入，DOMContentLoaded 时整体再过一遍。
        // Swift 清洗层管「能看什么」，这一层管「万一漏了也执行不了」
        if let url = Bundle.module.url(forResource: "purify", withExtension: "min.js"),
           let source = try? String(contentsOf: url, encoding: .utf8) {
            webView.configuration.userContentController.addUserScript(
                WKUserScript(
                    source: source + "\n" + Self.dompurifyHook,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true
                )
            )
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if context.coordinator.loadedHTML != html {
            context.coordinator.loadedHTML = html
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    /// 注入 DOMPurify 后的调用钩子。配置刻意收紧：只要 HTML 档、禁 data-* 属性。
    /// 失败静默——这一层是兜底，真出事还有 CSP 和 Swift 清洗层
    static let dompurifyHook = """
    (function(){
      function mpPurify(){
        try{
          if (window.DOMPurify && document.documentElement) {
            document.documentElement.innerHTML = DOMPurify.sanitize(
              document.documentElement.innerHTML,
              { USE_PROFILES: { html: true }, ALLOW_DATA_ATTR: false, ALLOW_ARIA_ATTR: true }
            );
          }
        }catch(e){}
      }
      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', mpPurify);
      } else { mpPurify(); }
    })();
    """

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: MailWebView
        var loadedHTML: String?

        init(parent: MailWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // loadHTMLString 的主文档加载：request.url 为 nil（或 about:blank），放行
            guard let url = navigationAction.request.url,
                  url.scheme != "about" else {
                decisionHandler(.allow)
                return
            }

            switch url.scheme?.lowercased() ?? "" {
            case "mplink":
                // 清洗层标记的钓鱼特征链接：解出真实地址，交 App 弹确认
                if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                   let encoded = components.queryItems?.first(where: { $0.name == "u" })?.value,
                   let target = encoded.removingPercentEncoding,
                   let realURL = URL(string: target) {
                    let reason = components.queryItems?.first(where: { $0.name == "r" })?.value?
                        .removingPercentEncoding ?? "该链接存在风险"
                    parent.onSuspiciousLink(realURL, reason)
                }
                decisionHandler(.cancel)

            case "http", "https":
                // 普通链接：直接开系统浏览器。WebView 自身永不导航
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)

            case "mailto", "tel":
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)

            default:
                // 理论上前端已剥干净（javascript:/data: 等），这里兜底
                decisionHandler(.cancel)
            }
        }

        // MARK: - 弹窗全部掐死
        // 邮件 HTML 伪造的系统对话框（"重新登录"）是经典钓鱼手段，
        // 而 javaScriptCanOpenWindows=false 已经挡住 window.open，这里再收口

        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            nil
        }

        func webView(_ webView: WKWebView,
                     runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping () -> Void) {
            completionHandler()
        }

        func webView(_ webView: WKWebView,
                     runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping (Bool) -> Void) {
            completionHandler(false)
        }

        func webView(_ webView: WKWebView,
                     runJavaScriptTextInputPanelWithPrompt prompt: String,
                     defaultText: String?,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping (String?) -> Void) {
            completionHandler(nil)
        }
    }
}
