import CoreFoundation
import Foundation

/// 轻量 MIME 解析：只处理邮件场景需要的那部分（头部、text/plain、text/html、base64/QP）。
enum EmlxParser {
    struct Parsed {
        var subject = ""
        var senderName = ""
        var senderEmail = ""
        var to: [String] = []
        var cc: [String] = []
        var bcc: [String] = []
        var date: Date?
        var body = ""
        /// text/html 原文。空 = 这封邮件没有 HTML 正文（纯文本或解析不出）
        var htmlBody = ""
        /// Content-ID → 内联图片数据。WKWebView 不解析 cid: 协议，渲染前要转 data URI
        var inlineImages: [String: Data] = [:]
        var hasAttachments = false
        /// 附件元数据（不含字节）
        var attachments: [Attachment] = []
        /// 回复链（References 头，从旧到新）。Android/iOS 之外的老客户端也有，
        /// 缺失时退回 In-Reply-To
        var references: [String] = []
        var inReplyTo = ""
        var messageID = ""
        var deliveredTo = ""

        /// 线程根：`References` 的第一个（最旧）→ `In-Reply-To` → 自己的 Message-ID。
        /// References 是按时间从旧到新排的，取第一个才是整条链的根。
        /// 兜底要剥尖括号，否则同一线程里根消息和其他消息的键格式不一致，聚不到一起
        var threadRoot: String {
            if let first = references.first { return first }
            if !inReplyTo.isEmpty { return inReplyTo }
            return messageID.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n"))
        }
    }

    static func parse(url: URL, includeBody: Bool) -> Parsed? {
        // HTML 正文 + 内联图片可能撑得很大，读上限放到 2MB；
        // 只取列表预览时仍只读 24KB
        let limit = includeBody ? 2_000_000 : 24_000
        guard let raw = readRaw(url: url, limit: limit) else { return nil }
        let (headerText, bodyText) = splitHeaderBody(raw)
        let headers = parseHeaders(headerText)

        var parsed = Parsed()
        parsed.subject = decodeHeader(headers["subject"] ?? "").trimmingCharacters(in: .whitespaces)
        if parsed.subject.isEmpty { parsed.subject = "(无主题)" }

        let from = decodeHeader(headers["from"] ?? "")
        (parsed.senderName, parsed.senderEmail) = splitAddress(from)

        parsed.to = addressList(headers["to"] ?? "")
        parsed.cc = addressList(headers["cc"] ?? "")
        parsed.bcc = addressList(headers["bcc"] ?? "")
        parsed.date = parseDate(headers["date"] ?? "")
        parsed.messageID = (headers["message-id"] ?? "").trimmingCharacters(in: .whitespaces)
        parsed.inReplyTo = normalizeMessageID(headers["in-reply-to"] ?? "")
        parsed.references = (headers["references"] ?? "")
            .components(separatedBy: .whitespacesAndNewlines)
            .map(normalizeMessageID)
            .filter { !$0.isEmpty }
        parsed.deliveredTo = (headers["delivered-to"] ?? headers["x-original-to"] ?? "")
            .trimmingCharacters(in: .whitespaces)

        let content = extractContent(headers: headers, body: bodyText, includeImages: includeBody)
        parsed.body = includeBody ? content.text : String(content.text.prefix(400))
        parsed.htmlBody = includeBody ? content.html : ""
        parsed.inlineImages = includeBody ? content.images : [:]
        // 附件只留元数据，不读字节——保存时再按 partIndex 回原文件取
        parsed.attachments = content.attachments
        parsed.hasAttachments = !content.attachments.isEmpty
            || (headers["content-type"] ?? "").lowercased().contains("multipart/mixed")
        return parsed
    }

    /// Message-ID 统一成不带尖括号的形式，便于比较
    private static func normalizeMessageID(_ raw: String) -> String {
        raw.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n"))
    }

    /// 读文件正文并剥掉 `.emlx` 首行的字节数
    private static func readRaw(url: URL, limit: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit), !data.isEmpty else { return nil }

        var bytes = [UInt8](data)
        // .emlx 首行是 RFC822 的字节数
        if let newline = bytes.firstIndex(of: 0x0A) {
            let head = bytes[0..<newline]
            if !head.isEmpty, head.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) {
                bytes.removeFirst(newline + 1)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - 头 / 体

    private static func splitHeaderBody(_ text: String) -> (String, String) {
        if let range = text.range(of: "\r\n\r\n") {
            return (String(text[text.startIndex..<range.lowerBound]),
                    String(text[range.upperBound...]))
        }
        if let range = text.range(of: "\n\n") {
            return (String(text[text.startIndex..<range.lowerBound]),
                    String(text[range.upperBound...]))
        }
        return (text, "")
    }

    private static func parseHeaders(_ text: String) -> [String: String] {
        var headers: [String: String] = [:]
        var currentKey: String?
        var currentValue = ""

        func flush() {
            if let key = currentKey {
                headers[key] = currentValue.trimmingCharacters(in: .whitespaces)
            }
            currentKey = nil
            currentValue = ""
        }

        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                currentValue += " " + line.trimmingCharacters(in: .whitespaces)
                continue
            }
            flush()
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            currentKey = key
            currentValue = value
        }
        flush()
        return headers
    }

    // MARK: - 正文

    private struct BodyContent {
        var text = ""
        var html = ""
        var images: [String: Data] = [:]
        var attachments: [Attachment] = []
    }

    /// 一个叶子 MIME part。`index` 在整封信里按深度优先编号，
    /// 保存附件时按它回原文件取字节——两次解析的结果必须一致，所以编号不能用哈希
    private struct MimePart {
        var index: Int
        var headers: [String: String]
        var body: String
    }

    /// 把整封信摊平成叶子 part 列表（嵌套 multipart 递归展开）
    private static func flatten(headers: [String: String], body: String, into parts: inout [MimePart]) {
        let contentType = headers["content-type"] ?? "text/plain"
        let lower = contentType.lowercased()

        guard lower.contains("multipart/"), let boundary = boundaryValue(from: contentType) else {
            parts.append(MimePart(index: parts.count, headers: headers, body: body))
            return
        }

        for chunk in body.components(separatedBy: "--" + boundary) {
            let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == "--" || trimmed.hasPrefix("--") { continue }
            let (partHeaders, partBody) = splitHeaderBody(chunk)
            let parsed = parseHeaders(partHeaders)
            let partType = (parsed["content-type"] ?? "text/plain").lowercased()
            if partType.contains("multipart/") {
                flatten(headers: parsed, body: partBody, into: &parts)
            } else {
                parts.append(MimePart(index: parts.count, headers: parsed, body: partBody))
            }
        }
    }

    /// 一次遍历同时收集 text/plain、text/html、带 Content-ID 的内联图片和附件元数据。
    /// 旧版只返回纯文本（HTML 被剥掉），阅读页要渲染 HTML 就必须保留原文。
    private static func extractContent(headers: [String: String], body: String, includeImages: Bool) -> BodyContent {
        var content = BodyContent()
        var parts: [MimePart] = []
        flatten(headers: headers, body: body, into: &parts)

        for part in parts {
            let parsed = part.headers
            let partType = (parsed["content-type"] ?? "text/plain").lowercased()
            let cid = (parsed["content-id"] ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "<> "))

            if partType.contains("text/plain"), content.text.isEmpty {
                let text = decodeSingle(headers: parsed, body: part.body)
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { content.text = text }
            }
            if partType.contains("text/html"), content.html.isEmpty {
                content.html = decodeSingle(headers: parsed, body: part.body)
            }
            if includeImages, partType.hasPrefix("image/"), !partType.contains("svg"), !cid.isEmpty {
                if content.images.count < 30,
                   let data = decodePartData(headers: parsed, body: part.body), data.count <= 2_097_152 {
                    content.images[cid] = data
                }
            }

            // 附件判定：有 content-disposition: attachment，或者有文件名且不是正文/内联图。
            // 内联图片（有 Content-ID）不算附件——它们要进 HTML 渲染，不该出现在附件列表里
            let disposition = (parsed["content-disposition"] ?? "").lowercased()
            let name = filenameValue(from: parsed)
            let isInlinePart = !cid.isEmpty
            if !name.isEmpty, !isInlinePart,
               disposition.contains("attachment") || !partType.hasPrefix("text/") {
                content.attachments.append(Attachment(
                    filename: name,
                    mime: partType.components(separatedBy: ";").first ?? partType,
                    size: approximateSize(headers: parsed, body: part.body),
                    partIndex: part.index
                ))
            }
        }

        // 没有 text/plain 时退回「剥标签的 HTML」——AI 摘要、复制全文、搜索都依赖它
        if content.text.isEmpty, !content.html.isEmpty {
            content.text = readableText(fromHTML: content.html)
        }
        return content
    }

    /// `Content-Disposition: attachment; filename="x.pdf"` 或
    /// `Content-Type: application/pdf; name="x.pdf"`，也可能是 RFC 2231 的 `filename*=UTF-8''...`
    private static func filenameValue(from headers: [String: String]) -> String {
        func parameter(_ raw: String, _ key: String) -> String? {
            guard let range = raw.range(of: key + "=", options: .caseInsensitive) else { return nil }
            var rest = raw[range.upperBound...]
            if rest.hasPrefix("\"") {
                rest = rest.dropFirst()
                guard let end = rest.firstIndex(of: "\"") else { return nil }
                return String(rest[..<end])
            }
            return String(rest.prefix { $0 != ";" && $0 != " " })
        }

        for source in [headers["content-disposition"] ?? "", headers["content-type"] ?? ""] {
            // RFC 2231：filename*=UTF-8''%E6%8A%A5%E5%91%8A.pdf
            if let star = parameter(source, "filename*") ?? nil,
               let encoded = star.components(separatedBy: "''").last,
               let decoded = encoded.removingPercentEncoding, !decoded.isEmpty {
                return decoded
            }
            if let plain = parameter(source, "filename") ?? parameter(source, "name"),
               !plain.isEmpty {
                return decodeHeader(plain)
            }
        }
        return ""
    }

    /// 不解码，直接按编码形式估算字节数——附件列表只要个大概，
    /// 为了显示大小去解一个 20MB 的 base64 不值得
    private static func approximateSize(headers: [String: String], body: String) -> Int {
        switch (headers["content-transfer-encoding"] ?? "").lowercased() {
        case "base64":
            return body.count * 3 / 4
        default:
            return body.utf8.count
        }
    }

    /// 按 part 序号回原文件取附件字节。点击「保存」时才调用，不常驻内存
    static func attachmentData(url: URL, partIndex: Int) -> Data? {
        guard let raw = readRaw(url: url, limit: 64_000_000) else { return nil }
        let (headerText, bodyText) = splitHeaderBody(raw)
        var parts: [MimePart] = []
        flatten(headers: parseHeaders(headerText), body: bodyText, into: &parts)
        guard let part = parts.first(where: { $0.index == partIndex }) else { return nil }
        return decodePartData(headers: part.headers, body: part.body)
    }

    /// 附件 part 的原始字节（内联图片用）。不做 charset 转换——图片不是文本。
    private static func decodePartData(headers: [String: String], body: String) -> Data? {
        let encoding = (headers["content-transfer-encoding"] ?? "").lowercased()
        switch encoding {
        case "base64":
            let cleaned = body.components(separatedBy: .whitespacesAndNewlines).joined()
            return Data(base64Encoded: cleaned, options: [.ignoreUnknownCharacters])
        case "quoted-printable":
            return decodeQuotedPrintable(body)
        default:
            return Data(body.utf8)
        }
    }

    /// HTML 剥离后可能只剩空白（例如纯 CSS 排版通知），给一句明确提示而不是留白
    private static func readableText(fromHTML html: String) -> String {
        guard !html.isEmpty else { return "" }
        let stripped = stripHTML(html)
        return stripped.isEmpty ? "（这封邮件没有可显示的正文）" : stripped
    }

    private static func decodeSingle(headers: [String: String], body: String) -> String {
        let encoding = (headers["content-transfer-encoding"] ?? "").lowercased()
        let charset = charsetValue(from: headers["content-type"] ?? "")

        var data: Data
        switch encoding {
        case "base64":
            let cleaned = body.components(separatedBy: .whitespacesAndNewlines).joined()
            data = Data(base64Encoded: cleaned, options: [.ignoreUnknownCharacters]) ?? Data(body.utf8)
        case "quoted-printable":
            data = decodeQuotedPrintable(body)
        default:
            data = Data(body.utf8)
        }

        if let text = String(data: data, encoding: charset) {
            return normalize(text)
        }
        return normalize(String(decoding: data, as: UTF8.self))
    }

    private static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeQuotedPrintable(_ text: String) -> Data {
        var output = [UInt8]()
        let bytes = Array(text.utf8)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x3D { // '='
                if index + 1 < bytes.count, bytes[index + 1] == 0x0A {
                    index += 2
                    continue
                }
                if index + 2 < bytes.count, bytes[index + 1] == 0x0D, bytes[index + 2] == 0x0A {
                    index += 3
                    continue
                }
                if index + 2 < bytes.count,
                   let value = UInt8(String(bytes: bytes[(index + 1)...(index + 2)], encoding: .utf8) ?? "", radix: 16) {
                    output.append(value)
                    index += 3
                    continue
                }
            }
            output.append(byte)
            index += 1
        }
        return Data(output)
    }

    /// HTML → 纯文本。
    ///
    /// 关键：必须**整块**移除 `<style>` / `<script>` / `<head>` / 注释，
    /// 因为这些标签内部的 CSS / JS 文本不是标签，单纯剥 `<...>` 会把它们当正文留下，
    /// 正文里就会冒出 `html { -webkit-text-size-adjust:none; }` 这种 CSS 源码。
    private static func stripHTML(_ html: String) -> String {
        var text = html

        // 1. 整块移除不可见内容
        for pattern in [
            "(?is)<style[^>]*>.*?</style>",
            "(?is)<script[^>]*>.*?</script>",
            "(?is)<head[^>]*>.*?</head>",
            "(?is)<title[^>]*>.*?</title>",
            "(?is)<!--.*?-->",
        ] {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }

        // 2. 块级结构 → 换行，保留可读的分段
        text = text.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)<li[^>]*>", with: "\n· ", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)<hr[^>]*>", with: "\n———\n", options: .regularExpression)
        text = text.replacingOccurrences(
            of: "(?i)</?(p|div|tr|td|li|h[1-6]|blockquote|table|section|article|ul|ol|header|footer)[^>]*>",
            with: "\n",
            options: .regularExpression
        )

        // 3. 剥掉剩余标签
        text = text.replacingOccurrences(of: "(?i)<[^>]+>", with: "", options: .regularExpression)

        // 4. 实体解码
        text = decodeEntities(text)

        // 5. 收拾空白：行内多余空格、行首尾空格、连续空行
        text = text.replacingOccurrences(of: "[ \\t\\u{00A0}]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: " *\n *", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ input: String) -> String {
        var text = input
        let named = [
            "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&apos;": "'", "&mdash;": "—", "&ndash;": "–", "&hellip;": "…",
            "&rsquo;": "’", "&lsquo;": "‘", "&ldquo;": "“", "&rdquo;": "”",
            "&middot;": "·", "&bull;": "•", "&copy;": "©", "&reg;": "®",
            "&trade;": "™", "&times;": "×", "&laquo;": "«", "&raquo;": "»",
        ]
        for (key, value) in named {
            text = text.replacingOccurrences(of: key, with: value)
        }

        // 数字实体 &#123; 与 &#x1F600;
        for (pattern, radix) in [("&#(\\d+);", 10), ("&#[xX]([0-9A-Fa-f]+);", 16)] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in matches.reversed() {
                guard let full = Range(match.range, in: text),
                      let numberRange = Range(match.range(at: 1), in: text),
                      let code = UInt32(text[numberRange], radix: radix),
                      let scalar = Unicode.Scalar(code) else { continue }
                text.replaceSubrange(full, with: String(Character(scalar)))
            }
        }
        return text
    }

    // MARK: - 头部解码

    static func decodeHeader(_ raw: String) -> String {
        guard raw.contains("=?") else { return raw }
        let pattern = "=\\?([^?]+)\\?([BbQq])\\?([^?]*)\\?="
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return raw }

        var result = raw
        let matches = regex.matches(in: raw, range: NSRange(raw.startIndex..., in: raw))
        for match in matches.reversed() {
            guard let full = Range(match.range, in: result),
                  let charsetRange = Range(match.range(at: 1), in: result),
                  let encodingRange = Range(match.range(at: 2), in: result),
                  let textRange = Range(match.range(at: 3), in: result) else { continue }

            let charset = String(result[charsetRange])
            let encoding = String(result[encodingRange]).uppercased()
            let payload = String(result[textRange])

            let data: Data?
            if encoding == "B" {
                data = Data(base64Encoded: payload, options: [.ignoreUnknownCharacters])
            } else {
                data = decodeQuotedPrintable(payload.replacingOccurrences(of: "_", with: " "))
            }
            guard let data else { continue }
            let decoded = String(data: data, encoding: cfEncoding(charset) ?? .utf8)
                ?? String(decoding: data, as: UTF8.self)
            result.replaceSubrange(full, with: decoded)
        }
        return result
    }

    private static func cfEncoding(_ name: String) -> String.Encoding? {
        let cfName = name.trimmingCharacters(in: .whitespaces).lowercased()
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(cfName as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }

    private static func charsetValue(from contentType: String) -> String.Encoding {
        guard let range = contentType.range(of: "charset=", options: .caseInsensitive) else { return .utf8 }
        let rest = contentType[range.upperBound...]
        let value = rest.components(separatedBy: CharacterSet(charactersIn: ";\"' ")).first ?? ""
        return cfEncoding(value) ?? .utf8
    }

    private static func boundaryValue(from contentType: String) -> String? {
        guard let range = contentType.range(of: "boundary=", options: .caseInsensitive) else { return nil }
        var rest = String(contentType[range.upperBound...])
        if rest.hasPrefix("\"") {
            rest.removeFirst()
            return rest.components(separatedBy: "\"").first
        }
        return rest.components(separatedBy: CharacterSet(charactersIn: "; ")).first
    }

    private static func splitAddress(_ raw: String) -> (String, String) {
        if let open = raw.firstIndex(of: "<"), let close = raw.firstIndex(of: ">"), open < close {
            let name = raw[raw.startIndex..<open].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            let email = raw[raw.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            return (name, email)
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed, trimmed)
    }

    /// 解析 To / Cc / Bcc 的地址列表。
    ///
    /// 不能简单按逗号 split：显示名里可能带逗号（`"Doe, John" <j@x.com>`），
    /// 直接切会把它拆成两半。这里按「引号内 / 尖括号内」的层级判断，只在顶层逗号处分隔。
    private static func addressList(_ raw: String) -> [String] {
        guard !raw.isEmpty else { return [] }
        let decoded = decodeHeader(raw)

        var parts: [String] = []
        var current = ""
        var angleDepth = 0
        var inQuote = false

        for ch in decoded {
            switch ch {
            case "\"":
                inQuote.toggle()
                current.append(ch)
            case "<" where !inQuote:
                angleDepth += 1
                current.append(ch)
            case ">" where !inQuote:
                angleDepth = max(0, angleDepth - 1)
                current.append(ch)
            case "," where !inQuote && angleDepth == 0:
                parts.append(current)
                current = ""
            default:
                current.append(ch)
            }
        }
        parts.append(current)

        return parts
            .map { splitAddress($0.trimmingCharacters(in: .whitespacesAndNewlines)).1 }
            .filter { $0.contains("@") }
    }

    /// 解析 Date 头。邮件日期写法五花八门（带 `(CST)` 注释、只有 GMT、无时区、单数字日…），
    /// 任何一条不匹配就会让日期落到兜底值——之前兜底是 `.distantPast`，界面上显示成「1年1月1日」。
    private static func parseDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 去掉尾部时区注释，如 " (CST)" / " (UTC)" / " (GMT+08:00)"
        var cleaned = trimmed
        if let range = cleaned.range(of: "\\s*\\([^)]*\\)\\s*$", options: .regularExpression) {
            cleaned.removeSubrange(range)
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let formats = [
            "EEE, d MMM yyyy HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm Z",
            "EEE, d MMMM yyyy HH:mm:ss Z",
            "d MMM yyyy HH:mm:ss Z",
            "d MMM yyyy HH:mm Z",
            "d MMMM yyyy HH:mm:ss Z",
            "yyyy-MM-dd HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm:ss zzz",
            "d MMM yyyy HH:mm:ss zzz",
            "EEE, d MMM yyyy HH:mm:ss",
            "d MMM yyyy HH:mm:ss",
        ]
        for candidate in [cleaned, trimmed] where !candidate.isEmpty {
            for format in formats {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = .current
                formatter.dateFormat = format
                if let date = formatter.date(from: candidate) { return date }
            }
        }

        // 兜底：交给系统日期识别，能处理各种非标准写法
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            if let match = detector.firstMatch(in: trimmed, range: range), let date = match.date {
                return date
            }
        }
        return nil
    }
}
