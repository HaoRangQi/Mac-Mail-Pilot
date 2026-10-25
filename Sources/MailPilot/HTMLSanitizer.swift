import Foundation
import SwiftSoup

/// 邮件 HTML 白名单清洗器（设计移植自 K-9 Mail / Thunderbird Android 的 HtmlSanitizer，Apache-2.0）。
///
/// 与 DOMPurify 的分工：本层在 Swift 侧做「结构化改造」——剥危险标签/属性、
/// 把危险链接降级、把远程图片换成占位、过滤 style；DOMPurify 在 WebView 里做
/// 浏览器真解析后的第二层消毒（防 mXSS 与解析差异）。两层互不替代：
/// 本层决定「能给用户看什么」，DOMPurify 决定「万一漏了也执行不了」。
///
/// 任何一步解析失败都返回 nil——调用方退回纯文本，绝不给用户看原始 HTML。
enum HTMLSanitizer {
    struct Result {
        var html = ""
        /// 危险协议（javascript: 等）被剥成不可点文本的数量
        var blockedLinks = 0
        /// 带钓鱼特征被改写成「需确认」内部链接的数量
        var riskyLinks = 0
        /// 远程图片被换成占位的数量
        var strippedRemoteImages = 0
        /// 被剥成占位的远程图片 URL（去重、按文档序）。远程图片放行时按这份清单代理下载
        var remoteImageURLs: [String] = []
        var truncated = false
    }

    static let maxHTMLBytes = 2_000_000
    static let maxElements = 4_000
    static let maxStyleLength = 2_000
    /// 远程图片放行清单上限。超过的保留占位，不进下载队列
    static let maxRemoteImages = 30

    /// 邮件排版需要的标签。表单/脚本/框架/元信息类一律不要——
    /// `<form>` + `<input type=password>` 是邮件里最常见的钓鱼道具。
    static let allowedTags: Set<String> = [
        "a", "p", "div", "span", "br", "hr", "blockquote", "pre", "code",
        "b", "strong", "i", "em", "u", "s", "strike", "sub", "sup", "small", "big",
        "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "dl", "dt", "dd",
        "table", "thead", "tbody", "tfoot", "tr", "td", "th", "caption", "colgroup", "col",
        "img", "figure", "figcaption", "center", "font", "abbr", "address", "wbr",
    ]

    /// 排版属性白名单。`background` 这类 URL 属性故意不收——它是远程图片的后门。
    private static let layoutAttributes = [
        "align", "valign", "bgcolor", "width", "height", "border",
        "cellpadding", "cellspacing", "colspan", "rowspan",
        "style", "class", "id", "dir", "lang", "title",
    ]

    /// style 声明里必须删掉的性质：行为绑定与表达式注入
    private static let blockedStyleProperties: Set<String> = [
        "behavior", "-moz-binding", "expression",
    ]

    static func sanitize(_ raw: String, loadedRemote: [String: Data] = [:]) -> Result? {
        var source = raw
        var truncated = false
        if source.utf8.count > maxHTMLBytes {
            source = String(source.prefix(maxHTMLBytes))
            truncated = true
        }
        // rawtext 必须整块先删：script/style 的「内容」不是标签，
        // 交给 HTML 解析器可能被当正文保留（老 stripHTML 踩过的坑）
        source = removeRawtext(source)

        guard let fragment = try? SwiftSoup.parseBodyFragment(source) else { return nil }

        let safelist: Whitelist
        do {
            safelist = try buildSafelist()
        } catch {
            return nil
        }

        let clean: Document
        do {
            clean = try Cleaner(headWhitelist: safelist, bodyWhitelist: safelist).clean(fragment)
        } catch {
            return nil
        }

        guard let body = clean.body() else { return nil }
        guard let elements = try? body.select("*") else { return nil }
        if elements.size() > maxElements { return nil }

        var result = Result(truncated: truncated)

        for element in elements.array() {
            let tag = element.tagName()

            // 1) style 属性值过滤（邮件全靠内联样式，属性要留、值要洗）
            if let style = try? element.attr("style"), !style.isEmpty {
                let filtered = filterStyle(style)
                if filtered.isEmpty {
                    _ = try? element.removeAttr("style")
                } else {
                    _ = try? element.attr("style", filtered)
                }
            }

            // 2) 链接：协议白名单 → 钓鱼特征改写 → 危险协议降级。
            //    D1（文字域名与实际目标不符）要拿可见文字比对，必须把 element.text() 传进去
            if tag == "a", let href = try? element.attr("href"), !href.isEmpty {
                switch classifyHref(href, visibleText: (try? element.text()) ?? "") {
                case .plain:
                    break // http/https/mailto/tel 原样保留，点击由导航拦截层处理
                case .risky(let reason):
                    // 改写成内部确认协议：点击时 App 弹确认框展示真实地址，
                    // 用户确认前浏览器拿不到这个 URL
                    let encoded = "mplink://open?u=\(percentEncode(href))&r=\(percentEncode(reason))"
                    _ = try? element.attr("href", encoded)
                    let existing = (try? element.attr("class")) ?? ""
                    _ = try? element.attr("class", (existing + " mp-risky-link").trimmingCharacters(in: .whitespaces))
                    result.riskyLinks += 1
                case .blocked:
                    // 危险协议 / 相对地址：剥 href 变纯文本，保留 ⚠️ 提示
                    _ = try? element.removeAttr("href")
                    _ = try? element.tagName("span")
                    let existing = (try? element.attr("class")) ?? ""
                    _ = try? element.attr("class", (existing + " mp-blocked-link").trimmingCharacters(in: .whitespaces))
                    _ = try? element.appendText(" ⚠️")
                    result.blockedLinks += 1
                }
            }

            // 3) 图片：cid 留给渲染层转 data URI，data:image 放行，其余一律占位。
            //    已被用户放行的远程图（loadedRemote）直接转 data URI——URL 清单留给没放行的
            if tag == "img" {
                let original = (try? element.attr("src")) ?? ""
                let src = original.lowercased()
                if src.hasPrefix("cid:") { continue }
                if src.hasPrefix("data:image/") { continue }
                if src.hasPrefix("http://") || src.hasPrefix("https://") {
                    if let data = loadedRemote[original], let mime = imageMIMEType(data) {
                        _ = try? element.attr("src", "data:\(mime);base64,\(data.base64EncodedString())")
                        continue
                    }
                    if result.remoteImageURLs.count < maxRemoteImages, !result.remoteImageURLs.contains(original) {
                        result.remoteImageURLs.append(original)
                    }
                }
                _ = try? element.removeAttr("src")
                let alt = (try? element.attr("alt")) ?? ""
                _ = try? element.text(alt.isEmpty ? "[远程图片]" : "[远程图片] \(alt)")
                let existing = (try? element.attr("class")) ?? ""
                _ = try? element.attr("class", (existing + " mp-remote-img").trimmingCharacters(in: .whitespaces))
                result.strippedRemoteImages += 1
            }
        }

        let html = (try? body.html()) ?? ""
        guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        result.html = html
        return result
    }

    // MARK: - 白名单构建

    private static func buildSafelist() throws -> Whitelist {
        var safelist = Whitelist.none()
        for tag in allowedTags {
            safelist = try safelist.addTags(tag)
            for attribute in layoutAttributes {
                safelist = try safelist.addAttributes(tag, attribute)
            }
        }
        safelist = try safelist.addAttributes("a", "href")
        safelist = try safelist.addAttributes("img", "src", "alt")
        // href 只放行这四个协议。
        // img 的 src 放行 cid/data/http/https——http(s) 不是漏放：下面的遍历会
        // **确定性地**把每个非 cid/data 的 img 换成占位并记下 URL（远程图片放行清单）。
        // 白名单若在这里就剥掉 src，遍历时就拿不到原始 URL 了
        safelist = try safelist.addProtocols("a", "href", "http", "https", "mailto", "tel")
        safelist = try safelist.addProtocols("img", "src", "cid", "data", "http", "https")
        return safelist
    }

    // MARK: - 链接分类

    enum HrefClass {
        case plain
        case risky(String)
        case blocked
    }

    /// href 三级判定：plain 保留 / risky 改写为确认链接 / blocked 降级为文本
    static func classifyHref(_ href: String, visibleText: String? = nil) -> HrefClass {
        let trimmed = href.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()

        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            switch LinkPolicy.classify(href: trimmed, visibleText: visibleText) {
            case .normal:
                return .plain
            case .suspicious(let reason):
                return .risky(reason)
            }
        }
        if lower.hasPrefix("mailto:") || lower.hasPrefix("tel:") {
            return .plain
        }
        // javascript: / data: / file: / vbscript: / 相对地址……
        return .blocked
    }

    // MARK: - 工具

    private static func removeRawtext(_ html: String) -> String {
        var text = html
        for pattern in [
            "(?is)<script[^>]*>.*?</script>",
            "(?is)<style[^>]*>.*?</style>",
            "(?is)<head[^>]*>.*?</head>",
            "(?is)<title[^>]*>.*?</title>",
            "(?is)<!--.*?-->",
        ] {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return text
    }

    /// 过滤 style 声明：删行为绑定、表达式注入、非 data: 的 url()、fixed 定位
    /// （fixed 覆盖层可以伪造 App 界面，是邮件里少见的危险货）
    static func filterStyle(_ style: String) -> String {
        guard style.count <= maxStyleLength * 4 else { return "" }
        var kept: [String] = []
        for declaration in style.components(separatedBy: ";") {
            let decl = declaration.trimmingCharacters(in: .whitespaces)
            guard !decl.isEmpty, let colon = decl.firstIndex(of: ":") else { continue }
            let property = decl[decl.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = decl[decl.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !property.isEmpty, !value.isEmpty else { continue }
            if blockedStyleProperties.contains(property) { continue }
            if property == "position", value.lowercased().hasPrefix("fixed") { continue }
            if value.lowercased().contains("expression(") { continue }
            if let urlValue = firstURLValue(in: value), !urlValue.lowercased().hasPrefix("data:image/") { continue }
            kept.append("\(property): \(value)")
        }
        return kept.joined(separator: "; ")
    }

    /// 取出 url(...) 里的地址；没有 url() 返回 nil
    private static func firstURLValue(in value: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "(?i)url\\(\\s*['\"]?([^'\")]+)") else {
            return nil
        }
        let range = NSRange(value.startIndex..., in: value)
        guard let match = regex.firstMatch(in: value, range: range), match.numberOfRanges > 1,
              let groupRange = Range(match.range(at: 1), in: value) else {
            return nil
        }
        return String(value[groupRange])
    }

    static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove("&")
        allowed.remove("+")
        allowed.remove("#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    // MARK: - 图片格式嗅探

    /// 只认常见位图。SVG 一律不认——SVG 里可以塞脚本，邮件场景没有非用 SVG 不可的。
    /// 服务端声明 Content-Type 可能是假的，魔法字节才是唯一依据
    static func imageMIMEType(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        if bytes.count >= 4, bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47 {
            return "image/png"
        }
        if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF {
            return "image/jpeg"
        }
        if bytes.count >= 4, bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x38 {
            return "image/gif"
        }
        if bytes.count >= 12, bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46,
           bytes[8] == 0x57, bytes[9] == 0x45, bytes[10] == 0x42, bytes[11] == 0x50 {
            return "image/webp"
        }
        return nil
    }
}
