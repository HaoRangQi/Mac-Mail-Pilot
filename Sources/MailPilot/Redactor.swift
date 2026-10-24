import Foundation

/// 外发内容脱敏。
///
/// 思路是「占位符替换 + 映射还原」而不是简单抹掉：
/// 把敏感值换成 `⟨类型序号⟩`，模型看到的是模板；返回结果再用内存里的映射表还原成真实值。
/// 映射表**只在内存中存活一次请求**，不落盘、不进日志。
///
/// 已知局限（必须承认）：
/// - 防不住语义泄露（"张三下周三签合同"这种，规则看不出敏感）
/// - 会误伤（16 位订单号会被当银行卡）
/// - 模型可能改写或吃掉占位符，此时还原失败但不会报错，宁留占位符不搞坏内容
struct Redactor {

    struct Mapping {
        let placeholder: String
        let original: String
    }

    /// 供设置页展示的规则信息（内部 Rule 结构不外泄）
    struct RuleInfo: Identifiable {
        let name: String
        let hint: String
        let pattern: String
        var id: String { name }
    }

    private struct Rule {
        let name: String
        let pattern: String
        let hint: String
    }

    /// 规则表按「长模式优先」排列：18 位身份证必须比 16 位银行卡先匹配，
    /// 否则身份证会被截成两段，前 16 位当卡号、后 2 位单独剩下。
    ///
    /// 全部用前后断言而不是 `\b`：`\b` 是 ASCII 词边界，
    /// 「电话13800138000」这种前后紧贴汉字的情况 `\b` 根本匹配不上。
    private static let rules: [Rule] = [
        Rule(name: "身份证", pattern: "(?<![0-9])[0-9]{17}[0-9Xx](?![0-9])|(?<![0-9])[0-9]{15}(?![0-9])", hint: "18 位或 15 位身份证号"),
        Rule(name: "银行卡", pattern: "(?<![0-9])[0-9](?:[ -]?[0-9]){15,18}(?![0-9])", hint: "16-19 位卡号，允许空格或连字符分组；长订单号可能被误伤"),
        Rule(name: "手机号", pattern: "(?<![0-9])1[3-9][0-9]{9}(?![0-9])", hint: "11 位手机号"),
        Rule(name: "电话", pattern: "(?<![0-9])(?:400[0-9]{7}|0[0-9](?:[ -]?[0-9]){8,10})(?![0-9])", hint: "客服号与带区号固话"),
        Rule(name: "IP", pattern: "(?<![0-9.])[0-9]{1,3}(?:\\.[0-9]{1,3}){3}(?![0-9.])", hint: "IPv4 地址"),
        Rule(name: "邮箱", pattern: "[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)+", hint: "电子邮箱地址"),
        Rule(name: "金额", pattern: "[¥￥$]\\s?[0-9][0-9,.]*|[0-9][0-9,.]{1,}\\s?(?:万元|元|块)", hint: "带货币符号或中文单位的金额"),
    ]

    static var ruleInfos: [RuleInfo] {
        rules.map { RuleInfo(name: $0.name, hint: $0.hint, pattern: $0.pattern) }
    }

    // MARK: - 脱敏

    /// 脱敏入口。
    ///
    /// 顺序：先关键字（纯文本，最可靠），再内置正则，最后自定义正则。
    /// 关键字按长度降序处理，避免短词先把长词切碎。
    static func redact(_ text: String,
                       disabledRules: Set<String> = [],
                       customRules: [CustomRedactionRule] = [],
                       keywords: [String] = []) -> (text: String, mappings: [Mapping]) {
        var output = text
        var mappings: [Mapping] = []
        var counters: [String: Int] = [:]

        // 1. 关键字：纯文本匹配，不依赖正则，最可靠
        let sorted = keywords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }

        for keyword in sorted {
            var cursor = output.startIndex
            while let found = output.range(of: keyword, range: cursor..<output.endIndex) {
                let original = String(output[found])
                let placeholder: String
                if let existing = mappings.first(where: { $0.original == original }) {
                    placeholder = existing.placeholder
                } else {
                    let index = (counters["关键字"] ?? 0) + 1
                    counters["关键字"] = index
                    placeholder = "⟨关键字\(index)⟩"
                    mappings.append(Mapping(placeholder: placeholder, original: original))
                }
                output.replaceSubrange(found, with: placeholder)
                // 从占位符之后继续，避免占位符自身被再次命中导致死循环
                cursor = output.index(found.lowerBound, offsetBy: placeholder.count)
            }
        }

        // 2. 内置规则（长模式优先）
        for rule in rules where !disabledRules.contains(rule.name) {
            apply(pattern: rule.pattern, type: rule.name,
                  to: &output, mappings: &mappings, counters: &counters)
        }

        // 3. 用户自定义正则
        for rule in customRules where rule.enabled && !disabledRules.contains(rule.name) {
            apply(pattern: rule.pattern, type: rule.name,
                  to: &output, mappings: &mappings, counters: &counters)
        }

        return (output, mappings)
    }

    /// 单条正则规则：正序分配编号（保证序号与出现顺序一致），倒序替换内容（避免 range 错位）
    private static func apply(pattern: String,
                              type: String,
                              to output: inout String,
                              mappings: inout [Mapping],
                              counters: inout [String: Int]) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let matches = regex.matches(in: output, range: NSRange(output.startIndex..., in: output))

        var assigned: [(range: Range<String.Index>, placeholder: String)] = []
        for match in matches {
            guard let range = Range(match.range, in: output) else { continue }
            let original = String(output[range])

            // 同一实体多次出现复用同一个占位符
            if let existing = mappings.first(where: { $0.original == original }) {
                assigned.append((range, existing.placeholder))
                continue
            }

            let index = (counters[type] ?? 0) + 1
            counters[type] = index
            let placeholder = "⟨\(type)\(index)⟩"
            mappings.append(Mapping(placeholder: placeholder, original: original))
            assigned.append((range, placeholder))
        }

        for item in assigned.reversed() {
            output.replaceSubrange(item.range, with: item.placeholder)
        }
    }

    // MARK: - 还原

    /// 宽容匹配：模型经常把 ⟨邮箱1⟩ 写成 <邮箱1> / [邮箱 1] / 【邮箱1】，
    /// 所以两边的符号放宽，类型名与编号之间也允许插空格。
    static func restore(_ text: String, _ mappings: [Mapping]) -> String {
        var output = text
        for mapping in mappings {
            let core = String(mapping.placeholder.dropFirst().dropLast())
            let name = String(core.prefix(while: { !$0.isNumber }))
            let number = String(core.suffix(core.count - name.count))
            let pattern = "[⟨<\\[【(〔]\\s*\(NSRegularExpression.escapedPattern(for: name))\\s*\(number)\\s*[⟩>\\]】)〕]"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            output = regex.stringByReplacingMatches(
                in: output,
                range: NSRange(output.startIndex..., in: output),
                withTemplate: NSRegularExpression.escapedTemplate(for: mapping.original)
            )
        }
        return output
    }

    // MARK: - 统计

    /// 这次替换了几个、各多少，用于发送前告知用户
    static func summary(_ mappings: [Mapping]) -> String {
        guard !mappings.isEmpty else { return "" }
        let grouped = Dictionary(grouping: mappings) { String($0.placeholder.dropFirst().dropLast().prefix(while: { !$0.isNumber })) }
        return grouped.map { type, rows in "\(type)×\(rows.count)" }.joined(separator: "、")
    }
}
