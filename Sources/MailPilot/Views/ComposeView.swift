import SwiftUI

/// CLT 环境缺少 SwiftUIMacros，@State 不可用，这里用 ObservableObject 承载表单状态。
final class ComposeForm: ObservableObject {
    @Published var fromAccountID = ""
    @Published var to = ""
    @Published var cc = ""
    @Published var bcc = ""
    @Published var subject = ""
    @Published var bodyText = ""
    @Published var sendNow = false
    @Published var sending = false
    @Published var scriptError: String?
    /// 抄送 / 密送默认折叠：多数邮件用不到，常驻两行只是占地方
    @Published var showCC = false
    /// 正文 AI 起草
    @Published var intent = ""
    /// 上次提交给 AI 的意图。生成后输入框清空，这段以灰色占位显示，
    /// 既能回看上一句要求，又不会被当成新输入误发
    @Published var lastIntent = ""
    @Published var drafting = false
    @Published var aiError: String?
}

struct ComposeView: View {
    /// 转发时带进来的初始内容；普通新建为 nil
    var prefill: ComposePrefill?
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var form = ComposeForm()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.5)

            VStack(spacing: 0) {
                senderRow
                rowDivider
                recipientRow
                rowDivider
                if form.showCC {
                    field("抄送", text: $form.cc, placeholder: "可选")
                    rowDivider
                    field("密送", text: $form.bcc, placeholder: "可选")
                    rowDivider
                }
                field("主题", text: $form.subject, placeholder: "邮件主题")
                rowDivider
                aiDraftBar
                rowDivider
                bodyEditor
            }
            .padding(.vertical, 4)

            if let aiError = form.aiError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.app(10))
                        .padding(.top, 1)
                    Text(aiError)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.app(11))
                .foregroundStyle(Theme.brick)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }

            if let scriptError = form.scriptError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.app(10))
                        .padding(.top, 1)
                    Text(scriptError)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.app(11))
                .foregroundStyle(Theme.brick)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }

            Divider().opacity(0.5)
            footer
        }
        .frame(width: 640)
        .background(.regularMaterial)
        .onAppear {
            // 转发：只在窗口还是空的时候灌入，避免和用户已经输入的内容打架
            if let prefill, form.subject.isEmpty, form.bodyText.isEmpty {
                form.to = prefill.to
                form.cc = prefill.cc
                form.subject = prefill.subject
                form.bodyText = prefill.body
            }
            if form.fromAccountID.isEmpty {
                form.fromAccountID = model.accounts.first?.id ?? ""
            }
            // 抄送/密送里已经有内容时（比如以后从回复带入），别把它们藏起来
            if !form.cc.isEmpty || !form.bcc.isEmpty {
                form.showCC = true
            }
        }
    }

    // MARK: - 头部 / 底部

    private var header: some View {
        HStack {
            Text("写邮件")
                .font(.app(14, weight: .semibold))
            Spacer()
            Text("由「邮件」App 投递")
                .font(.app(10.5))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 20)
        .frame(height: 44)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Toggle("直接发送", isOn: $form.sendNow)
                .toggleStyle(.checkbox)
                .font(.app(11))
                .foregroundStyle(.secondary)
                .help("勾选后立即投递；不勾选只打开「邮件」的撰写窗口，由你手动点发送")

            Spacer()

            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)

            Button(form.sending ? "处理中…" : (form.sendNow ? "发送" : "打开撰写窗口")) {
                send()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(form.sending || !hasAnyRecipient)
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
    }

    // MARK: - 行

    private var senderRow: some View {
        HStack(spacing: 10) {
            label("发件人")

            if model.accounts.isEmpty {
                Text("没有可用账号")
                    .font(.app(12))
                    .foregroundStyle(.tertiary)
            } else {
                Picker("", selection: $form.fromAccountID) {
                    ForEach(model.accounts) { account in
                        Text(accountLabel(account)).tag(account.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .font(.app(12.5))
                .frame(maxWidth: 420, alignment: .leading)
            }

            Spacer()
        }
        .padding(.horizontal, 20)
        .frame(height: 38)
    }

    private func field(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 10) {
            label(title)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.app(12.5))
        }
        .padding(.horizontal, 20)
        .frame(height: 38)
    }

    /// 收件人行，右侧带「抄送 / 密送」展开开关
    private var recipientRow: some View {
        HStack(spacing: 10) {
            label("收件人")
            TextField("name@example.com，多个用逗号分隔", text: $form.to)
                .textFieldStyle(.plain)
                .font(.app(12.5))

            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    form.showCC.toggle()
                }
            } label: {
                HStack(spacing: 3) {
                    Text(form.showCC ? "收起" : "抄送/密送")
                        .font(.app(10.5))
                    Image(systemName: form.showCC ? "chevron.up" : "chevron.down")
                        .font(.app(8, weight: .semibold))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(Color.primary.opacity(0.06), in: Capsule())
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(form.showCC ? "收起抄送与密送" : "展开抄送与密送")
        }
        .padding(.horizontal, 20)
        .frame(height: 38)
    }

    /// 正文上方的 AI 条：空正文时是「起草」，已有正文时是「修稿」
    private var aiDraftBar: some View {
        HStack(spacing: 8) {
            Image(systemName: hasBody ? "wand.and.stars" : "sparkles")
                .font(.app(11.5, weight: .semibold))
                .foregroundStyle(Theme.aiButtonGradient)

            // 系统自带的 placeholder 在深色主题下偏亮，看着像已经输入的内容。
            // 这里自己画一段占位文字，颜色完全可控：
            // 初始提示最淡，「上次：…」稍亮一点但仍明显淡于正文——一眼能分清哪些是"可看不可用"
            ZStack(alignment: .leading) {
                if form.intent.isEmpty {
                    Text(intentPlaceholder)
                        .font(.app(12))
                        .foregroundStyle(form.lastIntent.isEmpty
                                         ? Color.secondary.opacity(0.48)
                                         : Color.secondary.opacity(0.68))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .allowsHitTesting(false)
                }

                TextField("", text: $form.intent)
                    .textFieldStyle(.plain)
                    .font(.app(12))
                    .onSubmit { draft() }
            }

            if form.drafting {
                ProgressView().controlSize(.small)
            }

            Button {
                draft()
            } label: {
                Text(draftButtonTitle)
                    .font(.app(11.5, weight: .medium))
                    .foregroundStyle(canDraft ? Color.white : Color.secondary)
                    .padding(.horizontal, 11)
                    .frame(height: 24)
                    .background(canDraft ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.primary.opacity(0.06)),
                                in: Capsule())
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canDraft)
            .help(draftHelp)
        }
        .padding(.horizontal, 20)
        .frame(height: 40)
    }

    /// 正文里有没有东西——决定按钮是「起草」还是「修稿」
    private var hasBody: Bool {
        !form.bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 上一句要求以灰色占位留在输入框里：看得见，但不会被当成新输入
    private var intentPlaceholder: String {
        let last = form.lastIntent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !last.isEmpty {
            return "上次：\(last)"
        }
        return hasBody
            // 留空也能改：直接点「AI 修稿」就是润色，写一句就按你的要求改
            ? "可选：说说要改什么；留空直接润色"
            : "说说这封邮件要写什么，例如：确认周三评审时间，并要一下排期表"
    }

    private var draftButtonTitle: String {
        if form.drafting { return hasBody ? "修改中…" : "起草中…" }
        return hasBody ? "AI 修稿" : "AI 起草"
    }

    private var draftHelp: String {
        let base = hasBody
            ? "用 \(model.aiDraftModelLabel) 改写当前正文（正文会一起发出去）。不写要求就是润色：更简洁、更礼貌、修语病，不删信息"
            : "用 \(model.aiDraftModelLabel) 根据意图生成正文"
        let subject = form.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return subject.isEmpty
            ? base + "。没填主题，只按意图写"
            : base + "。会紧扣主题「\(subject)」，防止跑偏"
    }

    /// 正文已有内容时，不写要求也允许点——那就是「润色」
    private var canDraft: Bool {
        guard !form.drafting else { return false }
        return hasBody || !form.intent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 一键润色的默认要求。只改表达，不动信息——
    /// 「改写」类指令最容易顺手加戏或删掉承诺，这里把边界写死
    private static let polishInstruction = """
    在不改变原意和信息量的前提下润色这封邮件：更简洁、更礼貌，修正语病与标点，\
    保留原有的称呼、数字、日期和承诺，不要新增内容，也不要省略任何要点。
    """

    private func draft() {
        guard canDraft else { return }
        form.aiError = nil
        form.drafting = true
        // 先把这次的要求存下来，再把输入框清空——
        // 清空后 placeholder 会显示「上次：…」，用户一眼能回看刚才要了什么
        let typed = form.intent.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasText = hasBody
        let intent = typed.isEmpty ? Self.polishInstruction : typed
        let subject = form.subject
        let currentBody = form.bodyText
        // 一键润色不算「上次的要求」，别把整段润色提示词塞进占位行
        form.lastIntent = typed
        form.intent = ""

        Task { @MainActor in
            do {
                let text = try await model.draftComposeBody(
                    intent: intent,
                    subject: subject,
                    currentBody: currentBody
                )
                form.bodyText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !hasText {
                    model.showToast("已生成正文，可直接修改")
                } else {
                    model.showToast(typed.isEmpty ? "已润色正文" : "已按你的要求改好")
                }
            } catch {
                form.aiError = error.localizedDescription
                // 失败时把要求放回输入框，省得重打
                form.intent = typed
                form.lastIntent = ""
            }
            form.drafting = false
        }
    }

    private var bodyEditor: some View {
        TextEditor(text: $form.bodyText)
            .font(.app(13))
            .scrollContentBackground(.hidden)
            .frame(height: 230)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .overlay(alignment: .topLeading) {
                if form.bodyText.isEmpty {
                    Text("正文")
                        .font(.app(13))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 19)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
            }
    }

    private var rowDivider: some View {
        Divider().opacity(0.4).padding(.leading, 64)
    }

    private func label(_ title: String) -> some View {
        Text(title)
            .font(.app(12))
            .foregroundStyle(.secondary)
            .frame(width: 44, alignment: .leading)
    }

    // MARK: - 发送

    private var hasAnyRecipient: Bool {
        ![form.to, form.cc, form.bcc]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .allSatisfy(\.isEmpty)
    }

    private func accountLabel(_ account: Account) -> String {
        account.email.isEmpty ? account.name : "\(account.name) · \(account.email)"
    }

    private func splitRecipients(_ raw: String) -> [String] {
        raw.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private func send() {
        let account = model.accounts.first { $0.id == form.fromAccountID }
        let from = account?.email ?? ""
        let to = splitRecipients(form.to)
        let cc = splitRecipients(form.cc)
        let bcc = splitRecipients(form.bcc)
        let subject = form.subject
        let body = form.bodyText
        let sendNow = form.sendNow

        form.scriptError = nil
        form.sending = true

        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try MailSender.compose(
                        from: from, to: to, cc: cc, bcc: bcc,
                        subject: subject, body: body,
                        delivery: sendNow ? .sendNow : .openWindow
                    )
                }.value
                form.sending = false
                model.showToast(sendNow ? "已交给「邮件」发送" : "已在「邮件」中打开撰写窗口")
                dismiss()
            } catch {
                form.sending = false
                form.scriptError = error.localizedDescription
            }
        }
    }
}
