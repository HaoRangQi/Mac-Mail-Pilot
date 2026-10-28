import SwiftUI

/// 轻量 Markdown 渲染。
///
/// 不引第三方库：AI 回答里高频出现的只有标题、列表、代码块、引用、粗体、行内代码这几样，
/// 自己按行切块 + `AttributedString(markdown:)` 处理行内样式就够了。
///
/// 之前是把回答当纯文本丢给 `Text`，`**加粗**`、`- 列表`、```代码块``` 全都原样露出来，
/// 读起来像在看源码——这是「对话不像对话」的主要原因。
struct MarkdownText: View {
    let text: String
    var baseSize: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(Self.parse(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    // MARK: - 块

    enum Block {
        case paragraph(String)
        case heading(Int, String)
        case bullets([String])
        case ordered([(String, String)])
        case code(String)
        case quote(String)
        case rule
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .paragraph(let text):
            inline(text)

        case .heading(let level, let text):
            inline(text)
                .font(.app(baseSize + (level == 1 ? 4 : level == 2 ? 2.5 : 1.5), weight: .semibold))
                .padding(.top, 2)

        case .bullets(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                            .font(.app(baseSize))
                            .foregroundStyle(.secondary)
                        inline(item)
                    }
                }
            }

        case .ordered(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(item.0).")
                            .font(.app(baseSize, design: .monospaced))
                            .foregroundStyle(.secondary)
                        inline(item.1)
                    }
                }
            }

        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.app(baseSize - 1, design: .monospaced))
                    .padding(9)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))

        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: 2)
                inline(text)
                    .foregroundStyle(.secondary)
            }

        case .rule:
            Divider().opacity(0.3)
        }
    }

    private func inline(_ string: String) -> some View {
        let text: Text
        if let attributed = try? AttributedString(
            markdown: string,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            text = Text(Self.safeLinks(in: attributed))
        } else {
            text = Text(string)
        }
        // 逐段启用选择：只在外层容器上挂 textSelection 时，
        // 鼠标拖选在某些容器（LazyVStack / ScrollView 组合）里会失效
        return text.textSelection(.enabled)
    }

    /// 模型输出里的链接也要过一遍 `LinkPolicy`。
    ///
    /// 邮件正文那条防线（`HTMLSanitizer`）管不到 AI 回答，而 SwiftUI 的 `Text`
    /// 会把 markdown 链接直接渲染成可点的——一封恶意邮件只要诱导模型输出
    /// `[点这里](file:///Applications/xxx.app)`，用户一点就启动了本地程序。
    /// 这里把「危险特征」的链接降级成不可点文本，和邮件正文同一套判定。
    private static func safeLinks(in attributed: AttributedString) -> AttributedString {
        var output = attributed
        var doomed: [Range<AttributedString.Index>] = []

        for run in attributed.runs {
            guard let url = run.link else { continue }
            let visible = String(attributed[run.range].characters)
            if case .suspicious = LinkPolicy.classify(href: url.absoluteString, visibleText: visible) {
                doomed.append(run.range)
            }
        }

        for range in doomed {
            output[range].link = nil
        }
        return output
    }

    // MARK: - 解析

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var ordered: [(String, String)] = []
        var codeLines: [String] = []
        var inCode = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph = []
        }
        func flushBullets() {
            guard !bullets.isEmpty else { return }
            blocks.append(.bullets(bullets))
            bullets = []
        }
        func flushOrdered() {
            guard !ordered.isEmpty else { return }
            blocks.append(.ordered(ordered))
            ordered = []
        }
        func flushText() {
            flushParagraph()
            flushBullets()
            flushOrdered()
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if inCode {
                    blocks.append(.code(codeLines.joined(separator: "\n")))
                    codeLines = []
                    inCode = false
                } else {
                    flushText()
                    inCode = true
                }
                continue
            }
            if inCode {
                codeLines.append(rawLine)
                continue
            }

            if trimmed.isEmpty {
                flushText()
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushText()
                blocks.append(.rule)
                continue
            }

            if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix { $0 == "#" }.count
                let title = String(trimmed.dropFirst(hashes)).trimmingCharacters(in: .whitespaces)
                if hashes <= 6, !title.isEmpty {
                    flushText()
                    blocks.append(.heading(hashes, title))
                    continue
                }
            }

            if trimmed.hasPrefix("> ") || trimmed == ">" {
                flushText()
                blocks.append(.quote(String(trimmed.dropFirst(1)).trimmingCharacters(in: .whitespaces)))
                continue
            }

            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
                flushParagraph()
                flushOrdered()
                bullets.append(String(trimmed.dropFirst(2)))
                continue
            }

            if let item = orderedItem(trimmed) {
                flushParagraph()
                flushBullets()
                ordered.append(item)
                continue
            }

            flushBullets()
            flushOrdered()
            paragraph.append(rawLine)
        }

        if inCode, !codeLines.isEmpty {
            blocks.append(.code(codeLines.joined(separator: "\n")))
        }
        flushText()
        return blocks
    }

    /// 识别 `1. 内容` / `12) 内容`
    private static func orderedItem(_ line: String) -> (String, String)? {
        var digits = ""
        var rest = Substring(line)
        while let first = rest.first, first.isNumber {
            digits.append(first)
            rest = rest.dropFirst()
        }
        guard !digits.isEmpty, let separator = rest.first, separator == "." || separator == ")" else {
            return nil
        }
        let content = rest.dropFirst().trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { return nil }
        return (digits, content)
    }
}
