import Foundation

/// 链接风险分类。
///
/// 策略（2026-10-25 用户定稿）：**普通链接直接开浏览器，只有带危险特征的才弹确认**——
/// 不打断正常阅读，但钓鱼链接必须拦。危险特征四条：
/// D1 链接可见文字是域名、与实际目标不符（含 `brand.com@evil.com` 的 @ 伪装）
/// D2 host 是 punycode（xn--）或西里尔/希腊字母与拉丁字母混用（同形字仿冒）
/// D3 host 是裸 IP
/// D4 非 http/https/mailto/tel 协议（调用方在 HTMLSanitizer 里已降级为不可点文本）
///
/// **必须从 href 原文解析 host**：Foundation 的 `URL.host` 会把中文域名规范化成
/// punycode（`淘宝网.com` → `xn--0trm3n5j.com`），拿规范化结果判断会把所有中文域名
/// 误判成「易混淆编码」。这是实测踩出来的坑。
enum LinkPolicy {
    enum Risk {
        case normal
        case suspicious(String)
    }

    static func classify(href: String, visibleText: String?) -> Risk {
        let trimmed = href.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()

        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else {
            if lower.hasPrefix("mailto:") || lower.hasPrefix("tel:") { return .normal }
            return .suspicious("链接使用了危险协议")
        }

        // authority = "://" 到第一个 / ? # 之间的部分（含 userinfo）
        var authority = trimmed
        if let range = authority.range(of: "://") {
            authority = String(authority[range.upperBound...])
        }
        if let end = authority.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            authority = String(authority[..<end])
        }
        guard !authority.isEmpty else {
            return .suspicious("链接没有有效域名")
        }

        // @ 伪装：`https://paypal.com@evil.com/` 的真实域名是 evil.com
        if let at = authority.firstIndex(of: "@") {
            let realHost = String(authority[authority.index(after: at)...]).lowercased()
            return .suspicious("链接地址内嵌了「\(authority[..<at])@」伪装，真实域名是 \(realHost)")
        }

        let host = authority.lowercased()

        // D3 裸 IP
        if isIPLiteral(host) {
            return .suspicious("链接直接使用 IP 地址，不是正常网站域名")
        }

        // D2 同形字
        if let reason = homographReason(host: host) {
            return .suspicious(reason)
        }

        // D1 文字与目标不符
        if let text = visibleText, !text.trimmingCharacters(in: .whitespaces).isEmpty,
           let reason = mismatchReason(visibleText: text, host: host) {
            return .suspicious(reason)
        }

        return .normal
    }

    // MARK: - 细节

    private static func isIPLiteral(_ host: String) -> Bool {
        if host.contains(":") { return true } // IPv6
        let parts = host.components(separatedBy: ".")
        guard parts.count == 4 else { return false }
        // 注意：本工具链标准库拼写是 allSatisfy（项目现有代码同款），不是 allSatisfies
        return parts.allSatisfy({ part in
            guard let value = Int(part), value >= 0, value <= 255 else { return false }
            return part.count <= 3
        })
    }

    /// 西里尔/希腊与拉丁混用 = 经典同形字攻击（`аррӏе.com`）。
    /// 中文域名不误伤：Han 与拉丁混排是正常中文站点的常态，只查西里尔/希腊。
    private static func homographReason(host: String) -> String? {
        if host.contains("xn--") {
            return "域名使用了易混淆的编码（punycode，xn-- 开头）"
        }
        var hasConfusableScript = false
        var hasLatin = false
        for scalar in host.unicodeScalars {
            let value = scalar.value
            if (0x0400...0x04FF).contains(value) || (0x0370...0x03FF).contains(value) {
                hasConfusableScript = true
            }
            if (0x61...0x7A).contains(value) || (0x41...0x5A).contains(value) {
                hasLatin = true
            }
        }
        if hasConfusableScript, hasLatin {
            return "域名混用了西里尔/希腊字母与拉丁字母，可能是同形字仿冒"
        }
        return nil
    }

    /// 可见文字里出现「像域名的片段」但和实际 host 对不上 → 钓鱼特征。
    /// 例：文字是 paypal.com，实际指向 paypa1.com。
    private static func mismatchReason(visibleText: String, host: String) -> String? {
        guard let token = firstDomainToken(in: visibleText)?.lowercased() else { return nil }
        if token == host { return nil }
        if host.hasSuffix("." + token) || token.hasSuffix("." + host) { return nil }
        if host.contains(token) { return nil }
        return "链接显示的是「\(token)」，实际指向 \(host)"
    }

    /// 从可见文字里找第一个「像域名」的片段（至少含一个点的 ASCII/中文标签序列）
    static func firstDomainToken(in text: String) -> String? {
        let pattern = "[A-Za-z0-9\\u4e00-\\u9fff][A-Za-z0-9\\u4e00-\\u9fff-]*(?:\\.[A-Za-z0-9\\u4e00-\\u9fff-]+)+"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let tokenRange = Range(match.range, in: text) else { return nil }
        let token = String(text[tokenRange])
        // 纯数字+点（版本号、日期）不算域名
        if token.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" }) { return nil }
        return token
    }
}
