import AppKit
import SwiftUI

/// 可跨行、跨块选择的富文本视图。
///
/// SwiftUI 的 `Text` 是「一个 Text 一个可选区」：Markdown 回答里的每一条列表项
/// 都是独立的 `Text`，鼠标拖到行尾就断，整段复制做不到。
/// `NSTextView` 天生是一个连续的文本容器，选中范围可以横跨全部段落，
/// 顺带把 ⌘C / 双击选词 / 三击选段这些系统行为一起接回来。
struct SelectableTextView: NSViewRepresentable {
    let blocks: [MarkdownText.Block]
    var baseSize: CGFloat

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView(frame: .zero)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        let rendered = MarkdownRenderer.render(blocks: blocks, baseSize: baseSize)
        if view.textStorage?.isEqual(to: rendered) != true {
            view.textStorage?.setAttributedString(rendered)
        }
        // 宽度跟着 SwiftUI 给的 frame 走；高度由 sizeThatFits 算
        if view.bounds.width > 0 {
            view.textContainer?.containerSize = NSSize(width: view.bounds.width,
                                                       height: .greatestFiniteMagnitude)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize,
                      nsView: NSTextView,
                      context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0,
              let container = nsView.textContainer,
              let layout = nsView.layoutManager else { return nil }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(layout.usedRect(for: container).height))
    }
}

// MARK: - Markdown → NSAttributedString

/// 把 `MarkdownText.parse` 出来的块渲染成一份连续的富文本。
/// 只做一套渲染，不要在别处再拼第二套——两套样式早晚会走样。
enum MarkdownRenderer {

    private enum Indent {
        case none
        /// 项目符号：首行顶格，换行对齐到给定位置
        case hanging(CGFloat)
        /// 整段缩进（代码块、引用）
        case block(CGFloat)
    }

    private struct Line {
        var content: NSAttributedString
        var spacingAfter: CGFloat
        var indent: Indent = .none
    }

    static func render(blocks: [MarkdownText.Block], baseSize: CGFloat) -> NSAttributedString {
        let lines = flatten(blocks, baseSize: baseSize)
        let output = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            let styled = NSMutableAttributedString(attributedString: line.content)
            styled.addAttribute(.paragraphStyle,
                                value: paragraph(indent: line.indent, spacingAfter: line.spacingAfter),
                                range: NSRange(location: 0, length: styled.length))
            output.append(styled)
            if index < lines.count - 1 {
                output.append(NSAttributedString(string: "\n"))
            }
        }
        return output
    }

    // MARK: 块 → 行

    private static func flatten(_ blocks: [MarkdownText.Block], baseSize: CGFloat) -> [Line] {
        let blockGap = baseSize * 0.62
        let itemGap = baseSize * 0.3
        var lines: [Line] = []

        for (blockIndex, block) in blocks.enumerated() {
            let isLastBlock = blockIndex == blocks.count - 1
            let gap = isLastBlock ? 0 : blockGap

            switch block {
            case .paragraph(let text):
                let parts = text.components(separatedBy: "\n")
                for (index, part) in parts.enumerated() {
                    lines.append(Line(
                        content: inline(part, size: baseSize, color: .labelColor),
                        spacingAfter: index == parts.count - 1 ? gap : 0
                    ))
                }

            case .heading(let level, let text):
                let size = baseSize + (level == 1 ? 4 : level == 2 ? 2.5 : 1.5)
                lines.append(Line(
                    content: inline(text, size: size, weight: .semibold, color: .labelColor),
                    spacingAfter: gap
                ))

            case .bullets(let items):
                for (index, item) in items.enumerated() {
                    let content = NSMutableAttributedString(
                        string: "•\t",
                        attributes: [
                            .font: font(baseSize),
                            .foregroundColor: NSColor.secondaryLabelColor
                        ]
                    )
                    content.append(inline(item, size: baseSize, color: .labelColor))
                    lines.append(Line(
                        content: content,
                        spacingAfter: index == items.count - 1 ? gap : itemGap,
                        indent: .hanging(baseSize * 1.25)
                    ))
                }

            case .ordered(let items):
                for (index, item) in items.enumerated() {
                    let content = NSMutableAttributedString(
                        string: "\(item.0).\t",
                        attributes: [
                            .font: font(baseSize, monospaced: true),
                            .foregroundColor: NSColor.secondaryLabelColor
                        ]
                    )
                    content.append(inline(item.1, size: baseSize, color: .labelColor))
                    lines.append(Line(
                        content: content,
                        spacingAfter: index == items.count - 1 ? gap : itemGap,
                        indent: .hanging(baseSize * 1.7)
                    ))
                }

            case .code(let code):
                let parts = code.components(separatedBy: "\n")
                for (index, part) in parts.enumerated() {
                    lines.append(Line(
                        // 空行也要占一个字符，否则背景色和行高都会塌掉
                        content: NSAttributedString(
                            string: part.isEmpty ? " " : part,
                            attributes: [
                                .font: font(baseSize - 1, monospaced: true),
                                .foregroundColor: NSColor.labelColor,
                                .backgroundColor: NSColor.labelColor.withAlphaComponent(0.07)
                            ]
                        ),
                        spacingAfter: index == parts.count - 1 ? gap : 0,
                        indent: .block(baseSize * 0.6)
                    ))
                }

            case .quote(let text):
                let parts = text.components(separatedBy: "\n")
                for (index, part) in parts.enumerated() {
                    let content = NSMutableAttributedString(
                        string: "▍\t",
                        attributes: [
                            .font: font(baseSize),
                            .foregroundColor: NSColor.tertiaryLabelColor
                        ]
                    )
                    content.append(inline(part, size: baseSize, color: .secondaryLabelColor))
                    lines.append(Line(
                        content: content,
                        spacingAfter: index == parts.count - 1 ? gap : 0,
                        indent: .hanging(baseSize * 1.1)
                    ))
                }

            case .rule:
                lines.append(Line(
                    content: NSAttributedString(
                        string: String(repeating: "─", count: 28),
                        attributes: [
                            .font: font(baseSize - 1),
                            .foregroundColor: NSColor.tertiaryLabelColor
                        ]
                    ),
                    spacingAfter: gap
                ))
            }
        }
        return lines
    }

    // MARK: 行内样式

    private static func inline(_ string: String,
                               size: CGFloat,
                               weight: NSFont.Weight = .regular,
                               color: NSColor) -> NSAttributedString {
        guard !string.isEmpty else { return NSAttributedString() }

        let parsed = (try? AttributedString(
            markdown: string,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )).map(MarkdownText.safeLinks) ?? AttributedString(string)

        let output = NSMutableAttributedString()
        for run in parsed.runs {
            let text = String(parsed[run.range].characters)
            guard !text.isEmpty else { continue }

            let intent = run.inlinePresentationIntent
            var runFont = font(size, weight: weight)
            if intent?.contains(.stronglyEmphasized) == true {
                runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .boldFontMask)
            }
            if intent?.contains(.emphasized) == true {
                runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .italicFontMask)
            }
            if intent?.contains(.code) == true {
                runFont = font(size - 0.5, weight: weight, monospaced: true)
            }

            var attributes: [NSAttributedString.Key: Any] = [
                .font: runFont,
                .foregroundColor: color
            ]
            if intent?.contains(.strikethrough) == true {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link = run.link {
                attributes[.link] = link
                attributes[.foregroundColor] = NSColor.linkColor
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            output.append(NSAttributedString(string: text, attributes: attributes))
        }
        return output
    }

    // MARK: 排印

    private static func paragraph(indent: Indent, spacingAfter: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = spacingAfter
        style.lineSpacing = 2
        switch indent {
        case .none:
            break
        case .hanging(let value):
            style.headIndent = value
            style.tabStops = [NSTextTab(textAlignment: .left, location: value)]
        case .block(let value):
            style.firstLineHeadIndent = value
            style.headIndent = value
        }
        return style
    }

    /// 字号必须走全局缩放与字体族设置，否则「整体字号」对 AI 回答无效
    private static func font(_ size: CGFloat,
                             weight: NSFont.Weight = .regular,
                             monospaced: Bool = false) -> NSFont {
        let scaled = size * UIState.scale
        if monospaced {
            return .monospacedSystemFont(ofSize: scaled, weight: weight)
        }
        let base = NSFont.systemFont(ofSize: scaled, weight: weight)
        guard let design = systemDesign,
              let descriptor = base.fontDescriptor.withDesign(design) else { return base }
        return NSFont(descriptor: descriptor, size: scaled) ?? base
    }

    private static var systemDesign: NSFontDescriptor.SystemDesign? {
        switch UIState.current.fontFamily {
        case .system: return nil
        case .rounded: return .rounded
        case .serif: return .serif
        case .mono: return .monospaced
        }
    }
}
