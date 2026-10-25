import AppKit
import SwiftSoup

/// HTML 正文渲染管线：**清洗 → cid 内联 → CSP 包裹**，产出可直接交给 WKWebView 的完整 HTML。
///
/// 三道闸门层层收紧，任何一道不过就整体退回纯文本（调用方处理）：
/// 1. `HTMLSanitizer` 白名单清洗（结构层）
/// 2. cid: 转 data URI、远程 src 已在清洗层剥掉（资源层）
/// 3. CSP meta 断网：`default-src 'none'; img-src data:`（网络层）——
///    即使前两层漏了，WebView 也发不出任何远程请求
enum MailBodyRenderer {
    struct Prepared {
        var html = ""
        var blockedLinks = 0
        var riskyLinks = 0
        var strippedRemoteImages = 0
        var inlinedImages = 0
        /// 仍被占位的远程图片 URL（放行按钮按这份清单下载）
        var remoteImageURLs: [String] = []
        var truncated = false
    }

    /// CSP：默认全禁，只放行 data: 图片与内联样式。
    /// form-action/frame-src/base-uri 是纵深防御——清洗层已经剥了，这里再兜底
    static let contentSecurityPolicy = "default-src 'none'; img-src data:; style-src 'unsafe-inline'; " +
        "font-src data:; form-action 'none'; frame-src 'none'; base-uri 'none'"

    /// 正文字号基准档（与 `ReaderFontSize.standard` 对齐，13.5pt）。
    /// zoom 按「当前档 / 基准档」算，标准档时 zoom=1 与手写效果一致
    static let baseFontPoints: CGFloat = 13.5

    static func prepare(rawHTML: String,
                        inlineImages: [String: Data],
                        loadedRemote: [String: Data] = [:],
                        fontPoints: CGFloat,
                        dark: Bool) -> Prepared? {
        guard let sanitized = HTMLSanitizer.sanitize(rawHTML, loadedRemote: loadedRemote) else { return nil }
        guard let doc = try? SwiftSoup.parseBodyFragment(sanitized.html) else { return nil }
        guard let body = doc.body() else { return nil }

        var inlined = 0
        if let images = try? body.select("img") {
            for img in images.array() {
                let src = (try? img.attr("src")) ?? ""
                guard src.lowercased().hasPrefix("cid:") else { continue }
                let cid = String(src.dropFirst(4))
                if let data = inlineImages[cid], let mime = HTMLSanitizer.imageMIMEType(data) {
                    _ = try? img.attr("src", "data:\(mime);base64,\(data.base64EncodedString())")
                    inlined += 1
                } else {
                    // Content-ID 对不上（或不是支持的图片格式）：同样换占位，
                    // 绝不能留一个解析不了的 src 让 WebView 自己去猜
                    let alt = (try? img.attr("alt")) ?? ""
                    _ = try? img.removeAttr("src")
                    _ = try? img.text(alt.isEmpty ? "[图片缺失]" : "[图片缺失] \(alt)")
                    let existing = (try? img.attr("class")) ?? ""
                    _ = try? img.attr("class", (existing + " mp-remote-img").trimmingCharacters(in: .whitespaces))
                }
            }
        }

        let inner = (try? body.html()) ?? ""
        guard !inner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        return Prepared(
            html: wrap(inner, fontPoints: fontPoints, dark: dark),
            blockedLinks: sanitized.blockedLinks,
            riskyLinks: sanitized.riskyLinks,
            strippedRemoteImages: sanitized.strippedRemoteImages,
            inlinedImages: inlined,
            remoteImageURLs: sanitized.remoteImageURLs,
            truncated: sanitized.truncated
        )
    }

    // MARK: - 文档包装

    /// pt → px（CSS px = 1/96in，pt = 1/72in）
    static func cssPixels(points: CGFloat) -> String {
        String(format: "%.1f", points.doubleValue * 4.0 / 3.0)
    }

    private static func wrap(_ bodyHTML: String, fontPoints: CGFloat, dark: Bool) -> String {
        let textColor = dark ? "#e8e8ed" : "#1d1d1f"
        let linkColor = dark ? "#7cc0ff" : "#0a68c6"
        let muted = dark ? "#9a9aa0" : "#8a8a8e"
        // 字号联动：邮件正文普遍把字号写死成 px（14px/22px…），body 的 font-size 管不动它们。
        // 用 zoom 整体缩放（WebKit 支持，会参与重新布局）；max-width 用 calc 补偿，防止放大后横向溢出。
        // body 基准字号固定按「标准」档算，缩放全部交给 zoom——否则基准和 zoom 会双重放大
        let zoom = min(2.5, max(0.6, fontPoints / Self.baseFontPoints))
        let zoomText = String(format: "%.3f", zoom.doubleValue)

        return """
        <!DOCTYPE html>
        <html><head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)">
        <meta name="color-scheme" content="\(dark ? "dark" : "light")">
        <style>
        :root { color-scheme: \(dark ? "dark" : "light"); }
        html, body { margin: 0; padding: 0; background: transparent; }
        body {
          font: -apple-system-body, -apple-system, "PingFang SC", "Helvetica Neue", sans-serif;
          font-size: \(cssPixels(points: Self.baseFontPoints))px; line-height: 1.55; color: \(textColor);
          word-break: break-word; -webkit-text-size-adjust: none;
        }
        .mp-body { zoom: \(zoomText); max-width: calc(760px / \(zoomText)); margin: 0 auto; }
        img { max-width: 100%; height: auto; }
        pre { white-space: pre-wrap; }
        a { color: \(linkColor); }
        .mp-blocked-link {
          color: \(muted); text-decoration: none; border-bottom: 1px dotted \(muted); cursor: default;
        }
        .mp-remote-img {
          display: inline-block; padding: 0 6px; border: 1px dashed \(muted); border-radius: 4px;
          color: \(muted); font-size: 0.85em; opacity: 0.7;
        }
        .mp-risky-link { border-bottom: 1px dashed #d97706; }
        </style>
        </head>
        <body><div class="mp-body">\(bodyHTML)</div></body></html>
        """
    }
}

private extension CGFloat {
    var doubleValue: Double { Double(self) }
}
