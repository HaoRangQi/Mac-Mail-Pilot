import CoreFoundation
import Foundation

/// 轻量 MIME 解析：只处理邮件场景需要的那部分（头部、text/plain、text/html、base64/QP）。
enum EmlxParser {
    struct Parsed {
        var subject = ""
        var senderName = ""
        var senderEmail = ""
        var to: [String] = []
        var date: Date?
        var body = ""
        var hasAttachments = false
        var messageID = ""
        var deliveredTo = ""
    }

    static func parse(url: URL, includeBody: Bool) -> Parsed? {
        let limit = includeBody ? 800_000 : 24_000
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

        let raw = String(decoding: bytes, as: UTF8.self)
        let (headerText, bodyText) = splitHeaderBody(raw)
        let headers = parseHeaders(headerText)

        var parsed = Parsed()
        parsed.subject = decodeHeader(headers["subject"] ?? "").trimmingCharacters(in: .whitespaces)
        if parsed.subject.isEmpty { parsed.subject = "(无主题)" }

        let from = decodeHeader(headers["from"] ?? "")
        (parsed.senderName, parsed.senderEmail) = splitAddress(from)

        parsed.to = (headers["to"] ?? "")
            .components(separatedBy: ",")
            .map { splitAddress(decodeHeader($0)).1 }
            .filter { !$0.isEmpty }
        parsed.date = parseDate(headers["date"] ?? "")
        parsed.messageID = (headers["message-id"] ?? "").trimmingCharacters(in: .whitespaces)
        parsed.deliveredTo = (headers["delivered-to"] ?? headers["x-original-to"] ?? "")
            .trimmingCharacters(in: .whitespaces)

        let body = extractBody(headers: headers, body: bodyText)
        parsed.body = includeBody ? body : String(body.prefix(400))
        parsed.hasAttachments = (headers["content-type"] ?? "").lowercased().contains("multipart/mixed")
        return parsed
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

    private static func extractBody(headers: [String: String], body: String) -> String {
        let contentType = headers["content-type"] ?? "text/plain"
        let lower = contentType.lowercased()

        if lower.contains("multipart/"), let boundary = boundaryValue(from: contentType) {
            var htmlFallback = ""
            let parts = body.components(separatedBy: "--" + boundary)
            for part in parts {
                let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty || trimmed == "--" || trimmed.hasPrefix("--") { continue }
                let (partHeaders, partBody) = splitHeaderBody(part)
                let parsed = parseHeaders(partHeaders)
                let partType = (parsed["content-type"] ?? "text/plain").lowercased()

                if partType.contains("multipart/") {
                    let nested = extractBody(headers: parsed, body: partBody)
                    if !nested.isEmpty { return nested }
                    continue
                }
                if partType.contains("text/plain") {
                    let text = decodeSingle(headers: parsed, body: partBody)
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
                }
                if partType.contains("text/html"), htmlFallback.isEmpty {
                    htmlFallback = decodeSingle(headers: parsed, body: partBody)
                }
            }
            return htmlFallback.isEmpty ? "" : stripHTML(htmlFallback)
        }

        let text = decodeSingle(headers: headers, body: body)
        return lower.contains("text/html") ? stripHTML(text) : text
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

    private static func stripHTML(_ html: String) -> String {
        var text = html
        text = text.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)</p>", with: "\n\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"]
        for (key, value) in entities {
            text = text.replacingOccurrences(of: key, with: value)
        }
        return text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

    private static func parseDate(_ raw: String) -> Date? {
        guard !raw.isEmpty else { return nil }
        let formats = [
            "EEE, d MMM yyyy HH:mm:ss Z",
            "d MMM yyyy HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm Z",
            "yyyy-MM-dd HH:mm:ss Z",
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }
}
