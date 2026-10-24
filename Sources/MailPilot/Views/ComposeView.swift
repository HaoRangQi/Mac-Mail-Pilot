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
}

struct ComposeView: View {
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
                field("收件人", text: $form.to, placeholder: "name@example.com，多个用逗号分隔")
                rowDivider
                field("抄送", text: $form.cc, placeholder: "可选")
                rowDivider
                field("密送", text: $form.bcc, placeholder: "可选")
                rowDivider
                field("主题", text: $form.subject, placeholder: "邮件主题")
                rowDivider
                bodyEditor
            }
            .padding(.vertical, 4)

            if let scriptError = form.scriptError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .padding(.top, 1)
                    Text(scriptError)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 11))
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
            if form.fromAccountID.isEmpty {
                form.fromAccountID = model.accounts.first?.id ?? ""
            }
        }
    }

    // MARK: - 头部 / 底部

    private var header: some View {
        HStack {
            Text("写邮件")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Text("由「邮件」App 投递")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 20)
        .frame(height: 44)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Toggle("直接发送", isOn: $form.sendNow)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
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
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            } else {
                Picker("", selection: $form.fromAccountID) {
                    ForEach(model.accounts) { account in
                        Text(accountLabel(account)).tag(account.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .font(.system(size: 12.5))
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
                .font(.system(size: 12.5))
        }
        .padding(.horizontal, 20)
        .frame(height: 38)
    }

    private var bodyEditor: some View {
        TextEditor(text: $form.bodyText)
            .font(.system(size: 13))
            .scrollContentBackground(.hidden)
            .frame(height: 230)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .overlay(alignment: .topLeading) {
                if form.bodyText.isEmpty {
                    Text("正文")
                        .font(.system(size: 13))
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
            .font(.system(size: 12))
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
