import AppKit
import SwiftUI

/// 有提示语才挂 `.help()`，没有就不挂——空字符串会弹出一个空白气泡
private struct OptionalHelp: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text, !text.isEmpty {
            content.help(text)
        } else {
            content
        }
    }
}

/// 阅读区自己的临时状态（不进 UserDefaults：折叠只是当下想多看几行正文）
final class ReaderUIState: ObservableObject {
    @Published var aiCollapsed = false
}

struct ReaderView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var prefs: AIPreferencesStore
    @StateObject private var ui = ReaderUIState()

    var body: some View {
        ZStack {
            if let message = model.selected {
                detail(message)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassPanel()
        .overlay(alignment: .topTrailing) {
            if model.selected != nil {
                expandButton
                    .padding(10)
            }
        }
        .alert(
            "移入废纸篓？",
            isPresented: $model.showDeleteConfirm,
            presenting: model.pendingDelete
        ) { _ in
            Button("移入废纸篓", role: .destructive) {
                Task { await model.confirmDelete() }
            }
            Button("取消", role: .cancel) { model.pendingDelete = nil }
        } message: { message in
            Text(model.isDemo
                 ? "「\(message.subject)」\n\n当前是演示数据，只会从列表移除，不会动真实邮件。"
                 : "「\(message.subject)」\n\n将在「邮件」App 中移入该账户的废纸篓，可在邮件 App 里恢复。")
        }
        .alert(
            "确认发送这封回复？",
            isPresented: Binding(
                get: { model.pendingAISend != nil },
                set: { presented in if !presented { model.pendingAISend = nil } }
            )
        ) {
            Button("发送", role: .destructive) {
                guard let text = model.pendingAISend else { return }
                model.pendingAISend = nil
                Task { await model.deliverAIOutput(text, asDraft: false) }
            }
            Button("取消", role: .cancel) { model.pendingAISend = nil }
        } message: {
            Text(sendConfirmMessage)
        }
        .alert(
            "确认发送到第三方模型？",
            isPresented: Binding(
                get: { model.pendingAI != nil },
                set: { presented in if !presented { model.pendingAI = nil } }
            )
        ) {
            // 内容还没脱敏时才给这个选项：用户往往是看到确认框才想起这封邮件敏感，
            // 不该逼他去设置里改永久策略
            if model.pendingAI?.mappings.isEmpty == true {
                Button("脱敏后发送") {
                    model.confirmPendingAI(redacting: true)
                }
            }
            Button("发送", role: .destructive) {
                model.confirmPendingAI()
            }
            Button("取消", role: .cancel) { model.pendingAI = nil }
        } message: {
            VStack(alignment: .leading, spacing: 8) {
                Text(pendingAIMessage)

                if let request = model.pendingAI {
                    DisclosureGroup("查看实际发送的内容") {
                        ScrollView {
                            Text(request.outboundPreview)
                                .font(.app(10.5, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .hoverScrollIndicators()
                        .frame(maxHeight: 200)
                        .padding(8)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                    }
                    .font(.app(11))
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "envelope.open")
                .font(.app(26, weight: .light))
                .foregroundStyle(.tertiary)
            Text("选择一封邮件")
                .font(.app(12.5))
                .foregroundStyle(.secondary)
        }
    }

    private func detail(_ message: Message) -> some View {
        VStack(spacing: 0) {
            if message.htmlBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // 纯文本邮件：单滚动布局（原有行为，正文和头部一起滚）
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        messageHeader(message)

                        if message.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("（这封邮件没有正文）")
                                .font(.app(12.5))
                                .foregroundStyle(.tertiary)
                        } else {
                            Text(message.body)
                                .font(.app(UIState.readerFontSize))
                                .lineSpacing(UIState.readerLineSpacing)
                                .textSelection(.enabled)
                                .frame(maxWidth: 760, alignment: .leading)
                        }

                        attachmentsRow(message)
                    }
                    .padding(.horizontal, 26)
                    .padding(.top, 22)
                    .padding(.bottom, 20)
                }
                .hoverScrollIndicators()
            } else {
                // HTML 邮件：头部信息按内容实际高度（不套 ScrollView——ScrollView 是贪心的，
                // 会把 maxHeight 全额吃掉，头部内容短时下面空一大片），WebView 自适应填充（内部自己滚）
                VStack(alignment: .leading, spacing: 0) {
                    messageHeader(message)
                    attachmentsRow(message)
                }
                .padding(.horizontal, 26)
                .padding(.top, 22)
                .padding(.bottom, 16)

                MailBodyView(message: message)
            }

            aiBar
        }
    }

    /// 主题 / 发件人 / 收件人行 / 标签 + 底部分隔线。两种布局共用
    @ViewBuilder
    private func messageHeader(_ message: Message) -> some View {
        Text(message.subject)
            .font(.app(19, weight: .semibold))
            .lineSpacing(2)
            .textSelection(.enabled)
            .padding(.bottom, 10)

        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(message.displaySender)
                .font(.app(13.5, weight: .semibold))
                .foregroundStyle(.primary)
                .textSelection(.enabled)

            if !message.senderEmail.isEmpty {
                Text(message.senderEmail)
                    .font(.app(12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                Button {
                    copyToPasteboard(message.senderEmail)
                    model.showToast("已复制邮箱地址")
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.app(9.5))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("复制发件人邮箱")
            }

            Spacer(minLength: 10)

            Text(dateText(message.date))
                .font(.app(11.5))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .contextMenu {
            Button("复制发件人") {
                copyToPasteboard(message.displaySender)
                model.showToast("已复制发件人")
            }
            Button("复制邮箱地址") {
                copyToPasteboard(message.senderEmail)
                model.showToast("已复制邮箱地址")
            }
            Button("复制主题") {
                copyToPasteboard(message.subject)
                model.showToast("已复制主题")
            }
            Divider()
            Button("复制邮件全文") {
                let header = "\(message.subject)\n\(message.displaySender) <\(message.senderEmail)>\n\(dateText(message.date))\n\n"
                copyToPasteboard(header + message.body)
                model.showToast("已复制邮件全文")
            }
        }

        addressRow("收件人", message.recipients)
        addressRow("抄送", message.cc)
        addressRow("密送", message.bcc)

        HStack(spacing: 6) {
            if message.needsReply { Chip(text: "待回复") }
            if message.flagged { Chip(text: "已标记") }
            if !message.threadID.isEmpty { Chip(text: "会话") }
        }
        .padding(.top, 9)

        Divider().opacity(0.5).padding(.vertical, 14)
    }

    /// 附件列表。两种布局共用；空列表整块不渲染
    @ViewBuilder
    private func attachmentsRow(_ message: Message) -> some View {
        if !message.attachments.isEmpty {
            HStack(spacing: 7) {
                ForEach(message.attachments) { att in
                    HStack(spacing: 5) {
                        Image(systemName: "paperclip")
                            .font(.app(10))
                        Text(att.filename)
                            .font(.app(11.5))
                        if !att.sizeText.isEmpty {
                            Text(att.sizeText)
                                .font(.app(10.5))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 26)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                }
            }
            .padding(.top, 16)
        }
    }

    /// 右上角角落里的「正文最大化」按钮。浮在内容上，不参与正文排版
    private var expandButton: some View {
        Button {
            model.readerExpanded.toggle()
        } label: {
            Image(systemName: model.readerExpanded
                  ? "arrow.down.right.and.arrow.up.left"
                  : "arrow.up.left.and.arrow.down.right")
                .font(.app(10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(.plain)
        .help(model.readerExpanded ? "还原三栏" : "正文最大化（隐藏侧边栏与列表）")
    }

    private var aiBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            if prefs.prefs.quickRepliesEnabled {
                HStack(spacing: 6) {
                    Text("快速回复")
                        .font(.app(10.5))
                        .foregroundStyle(.tertiary)
                    ForEach(prefs.prefs.quickReplies, id: \.self) { text in
                        Button {
                            model.draftReply(instruction: text)
                        } label: {
                            Text(text)
                                .font(.app(11.5))
                                .padding(.horizontal, 9)
                                .frame(height: 24)
                                .background(Color.primary.opacity(0.05), in: Capsule())
                                .overlay(Capsule().stroke(Color.primary.opacity(0.07), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
            }

            HStack(spacing: 8) {
                // 删除放在最前：它跟右边一串「生成内容」的动作不是一类，靠右反而容易误点
                if model.deleting {
                    ProgressView().controlSize(.small)
                } else if let message = model.selected {
                    Button {
                        model.requestDelete(message)
                    } label: {
                        Image(systemName: "trash")
                            .font(.app(11, weight: .medium))
                            .foregroundStyle(Theme.brick)
                            .frame(width: 28, height: 28)
                            .glassEffect(.regular.interactive(), in: .circle)
                    }
                    .buttonStyle(.plain)
                    .help("移入「邮件」App 的废纸篓")
                }

                if let message = model.selected {
                    exemptionToggle(message)
                }

                aiButton("AI 摘要", icon: "sparkles") { model.summarize() }
                aiButton("草拟回复", icon: "arrowshape.turn.up.left") { model.draftReply() }
                aiButton("分类", icon: "tag") { model.classify() }
                if prefs.prefs.translateEnabled {
                    aiButton("翻译",
                             icon: "character.bubble",
                             help: "翻译模型：\(model.translationModelLabel)") {
                        model.translate()
                    }
                }
                Spacer()
                if model.aiBusy {
                    ProgressView().controlSize(.small)
                }
                // 折叠按钮只在有结果、且不在编辑态时出现。
                // 收起 = 整块结果（含脱敏明细、按钮）都不渲染，回到「没点摘要之前」的样子；
                // 但 model.aiOutput 一个字都不清，展开立刻原样回来，方便和正文比对
                if model.aiOutput != nil, !model.aiEditing {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            ui.aiCollapsed.toggle()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: ui.aiCollapsed ? "chevron.up" : "chevron.down")
                                .font(.app(9.5, weight: .semibold))
                            Text(ui.aiCollapsed ? "展开" : "收起")
                                .font(.app(10.5))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .frame(height: 26)
                        .background(Color.primary.opacity(0.05), in: Capsule())
                        .overlay(Capsule().stroke(Color.primary.opacity(0.07), lineWidth: 0.5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(ui.aiCollapsed ? "展开 AI 结果" : "收起 AI 结果，腾出正文空间（内容不丢）")
                }
            }

            if let output = model.aiOutput, !ui.aiCollapsed {
                VStack(alignment: .leading, spacing: 9) {
                    // 豁免是显式动作，但结果区必须再提醒一次：这次真的没脱敏
                    if model.aiExempted {
                        HStack(spacing: 4) {
                            Image(systemName: "shield.slash.fill")
                                .font(.app(9))
                            Text("本次未脱敏：这封邮件已标记为不敏感，内容原样发送")
                                .font(.app(10.5))
                        }
                        .foregroundStyle(Theme.gold)
                    }

                    if !model.aiOutputTrusted {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.shield.fill")
                                .font(.app(9))
                            Text("由不可信模型生成 · 邮件内容已发送到该服务商")
                                .font(.app(10.5))
                        }
                        .foregroundStyle(Theme.gold)
                    }

                    // 命中的敏感信息必须可见，否则用户根本不知道脱敏改了什么
                    if !model.aiRedactions.isEmpty {
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(model.aiRedactions, id: \.placeholder) { mapping in
                                    HStack(spacing: 6) {
                                        Text(mapping.placeholder)
                                            .font(.app(10.5, design: .monospaced))
                                            .foregroundStyle(Theme.gold)
                                        Image(systemName: "arrow.left")
                                            .font(.app(8))
                                            .foregroundStyle(.tertiary)
                                        Text(mapping.original)
                                            .font(.app(10.5, design: .monospaced))
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                            .padding(9)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                        } label: {
                            Text("已脱敏 \(model.aiRedactions.count) 处：\(Redactor.summary(model.aiRedactions))")
                                .font(.app(10.5))
                        }
                        .font(.app(10.5))
                        .foregroundStyle(Theme.gold)
                    }
                    if model.aiEditing {
                        TextEditor(text: $model.aiDraftText)
                            .font(.app(12.5))
                            .scrollContentBackground(.hidden)
                            .frame(height: 150)
                            .padding(9)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
                    } else {
                        ScrollView {
                            Text(output)
                                .font(.app(12.5))
                                .lineSpacing(4)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .hoverScrollIndicators()
                        .frame(maxHeight: 150)
                        .padding(11)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
                    }

                    HStack(spacing: 8) {
                        if model.aiEditing {
                            resultButton("完成", icon: "checkmark", tint: Theme.moss) {
                                model.finishEditingAI()
                            }
                        } else {
                            // 复制对所有动作通用
                            resultButton("复制", icon: "doc.on.doc", tint: .secondary) {
                                copyToPasteboard(output)
                                model.showToast("已复制")
                            }
                            // 只有回复草稿需要编辑
                            if model.aiAction == .reply {
                                resultButton("编辑", icon: "pencil", tint: .secondary) {
                                    model.beginEditingAI()
                                }
                            }
                        }

                        // 存草稿 / 发送只对回复有意义，摘要与分类没有收件人概念
                        if model.aiAction == .reply {
                            resultButton("存草稿", icon: "tray.and.arrow.down", tint: .secondary) {
                                let text = model.aiDeliverableText
                                Task { await model.deliverAIOutput(text, asDraft: true) }
                            }
                            resultButton("发送", icon: "paperplane.fill", tint: Theme.moss) {
                                model.pendingAISend = model.aiDeliverableText
                            }
                        }

                        Spacer()
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1)
        }
    }

    /// 单封邮件的安全开关。
    ///
    /// 只有三种状态，**当前生效的是哪一种永远显示在按钮上**——这是防止「绕晕」的关键：
    /// 模型可信 / 按策略脱敏 / 本封已豁免。切模型时这个按钮的文案会跟着变，
    /// 用户不用去设置里翻自己上次设了什么。
    private func exemptionToggle(_ message: Message) -> some View {
        let exempt = model.isExempt(message)
        let trusted = model.mainModelTrusted

        let label: String
        let icon: String
        let tint: Color
        if trusted {
            label = "模型可信"
            icon = "checkmark.shield.fill"
            tint = Theme.moss
        } else if exempt {
            label = "本封不脱敏"
            icon = "shield.slash.fill"
            tint = Theme.gold
        } else {
            label = "按策略脱敏"
            icon = "shield.lefthalf.filled"
            tint = .secondary
        }

        return Button {
            guard !trusted else { return }
            model.setExempt(!exempt, for: message)
        } label: {
            Image(systemName: icon)
                .font(.app(11, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(exempt ? 0.15 : 0.06), in: Circle())
                .overlay(Circle().stroke(tint.opacity(exempt ? 0.45 : 0.14), lineWidth: 0.7))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("\(label)\n\(exemptionHelp(trusted: trusted, exempt: exempt))")
    }

    private func exemptionHelp(trusted: Bool, exempt: Bool) -> String {
        if trusted {
            return "当前模型可信，本来就不脱敏。换成不可信模型时，这里会变成可点的开关。"
        }
        if exempt {
            return "这封邮件已标记为不敏感：在不可信模型上也原样发送，不脱敏、不弹确认。再点一次恢复。"
        }
        return "不可信模型下会按策略脱敏 / 弹确认。点一下把这封邮件标记为不敏感，内容原样发送。"
    }

    private func aiButton(_ title: String,
                          icon: String,
                          help: String? = nil,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                // 图标用高饱和渐变，文字保持正文色：背景换成浅色图时按钮不会糊成一片
                Image(systemName: icon)
                    .font(.app(10.5, weight: .semibold))
                    .foregroundStyle(Theme.aiButtonGradient)
                Text(title)
                    .font(.app(12, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 11)
            .frame(height: 27)
            .overlay(Capsule().stroke(Theme.aiButtonGradient.opacity(0.35), lineWidth: 0.7))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .modifier(OptionalHelp(text: help))
        .disabled(model.selected == nil)
    }

    /// AI 结果下方的操作按钮（复制 / 存草稿 / 发送）
    private func resultButton(_ title: String,
                              icon: String,
                              tint: Color,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.app(10.5))
                Text(title).font(.app(12))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 11)
            .frame(height: 27)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 复制与日期

    /// 发送确认框里说明收件人与主题，避免发错人
    private var sendConfirmMessage: String {
        guard let message = model.selected else { return "" }
        let subject = message.subject.lowercased().hasPrefix("re:")
            ? message.subject
            : "Re: \(message.subject)"
        return "收件人：\(message.displaySender) <\(message.senderEmail)>\n主题：\(subject)\n\n发送后无法撤回。"
    }

    /// 外发确认框：写清楚发给谁、发了多少、有没有脱敏
    private var pendingAIMessage: String {
        guard let request = model.pendingAI else { return "" }
        let actionName: String
        switch request.action {
        case .summarize: actionName = "摘要"
        case .reply: actionName = "草拟回复"
        case .classify: actionName = "分类"
        case .translate: actionName = "翻译"
        }
        var text = "动作：\(actionName)\n"
        if let provider = request.provider {
            text += "发送到：\(provider.name)（\(provider.baseURL)）\n"
        } else {
            text += "发送到：演示模式，不会真的发出去\n"
        }
        text += "内容量：\(request.charCount) 字符\n"
        if request.mappings.isEmpty {
            text += "未脱敏：邮件内容将原样发送。想先脱敏就点「脱敏后发送」。"
        } else {
            text += "已脱敏 \(request.mappings.count) 处：\(Redactor.summary(request.mappings))"
        }
        return text
    }

    /// 收件人 / 抄送 / 密送 统一行：标签固定宽度让三行对齐，空列表整行不渲染
    @ViewBuilder
    private func addressRow(_ label: String, _ addresses: [String]) -> some View {
        if !addresses.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(label)
                    .font(.app(10.5))
                    .foregroundStyle(.tertiary)
                    .frame(width: 34, alignment: .leading)

                Text(addresses.joined(separator: "、"))
                    .font(.app(12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(addresses.joined(separator: "\n"))

                if addresses.count > 1 {
                    Text("共 \(addresses.count) 人")
                        .font(.app(10.5))
                        .foregroundStyle(.tertiary)
                }

                Button {
                    copyToPasteboard(addresses.joined(separator: ", "))
                    model.showToast("已复制\(label)")
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.app(9.5))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("复制\(label)")

                Spacer(minLength: 0)
            }
            .padding(.top, 4)
        }
    }

    private func copyToPasteboard(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    /// 完整日期。解析失败的旧数据可能落在 1970 之前，明确写「日期未知」而不是显示「1年1月1日」
    private func dateText(_ date: Date) -> String {
        guard date.timeIntervalSince1970 > 0 else { return "日期未知" }
        return date.formatted(.dateTime.year().month().day().hour().minute())
    }
}
