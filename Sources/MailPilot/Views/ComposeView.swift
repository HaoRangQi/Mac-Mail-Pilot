import SwiftUI

/// CLT 环境缺少 SwiftUIMacros，@State 不可用，这里用 ObservableObject 承载表单状态。
final class ComposeForm: ObservableObject {
    @Published var to = ""
    @Published var subject = ""
    @Published var bodyText = ""
    @Published var sendNow = false
    @Published var scriptError: String?
}

struct ComposeView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var form = ComposeForm()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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

            Divider().opacity(0.5)

            VStack(spacing: 0) {
                field("收件人", text: $form.to, placeholder: "name@example.com")
                Divider().opacity(0.4)
                field("主题", text: $form.subject, placeholder: "邮件主题")
                Divider().opacity(0.4)

                TextEditor(text: $form.bodyText)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .frame(height: 220)
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
            .padding(.vertical, 6)

            if let scriptError = form.scriptError {
                Text(scriptError)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 6)
            }

            Divider().opacity(0.5)

            HStack(spacing: 10) {
                Toggle("脚本直接发送", isOn: $form.sendNow)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help("关闭时只打开撰写窗口，由你手动点发送")

                Spacer()

                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button("mailto 打开") {
                    MailSender.viaMailto(to: form.to, subject: form.subject, body: form.bodyText)
                    dismiss()
                }
                .disabled(form.to.trimmingCharacters(in: .whitespaces).isEmpty)

                Button("AppleScript 打开") {
                    do {
                        try MailSender.viaAppleScript(
                            to: splitRecipients(form.to),
                            subject: form.subject,
                            body: form.bodyText,
                            sendNow: form.sendNow
                        )
                        dismiss()
                    } catch {
                        form.scriptError = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(form.to.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 20)
            .frame(height: 52)
        }
        .frame(width: 600)
        .background(.regularMaterial)
    }

    private func splitRecipients(_ raw: String) -> [String] {
        raw.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
        }
        .padding(.horizontal, 20)
        .frame(height: 38)
    }
}
