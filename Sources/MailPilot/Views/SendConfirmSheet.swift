import SwiftUI

/// 发送确认。
///
/// 为什么用 sheet 而不是 alert：正文可能很长，alert 能显示的空间不够，
/// 而「确认发送」的全部意义就在**让人逐字看见到底要发什么出去**。
/// 这是模型唯一能把读到的内容送出本机的通道。
struct SendConfirmSheet: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let info = model.pendingSendInfo {
            VStack(alignment: .leading, spacing: 0) {
                header(info)
                Divider().opacity(0.4)

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        labeled("收件人") {
                            TextField("收件人邮箱，多个用逗号分隔", text: $model.pendingSendTo)
                                .textFieldStyle(.roundedBorder)
                                .font(.app(12.5))
                        }

                        if !info.cc.isEmpty {
                            labeled("抄送") {
                                Text(info.cc.joined(separator: ", "))
                                    .font(.app(12))
                                    .textSelection(.enabled)
                            }
                        }
                        if !info.bcc.isEmpty {
                            labeled("密送") {
                                Text(info.bcc.joined(separator: ", "))
                                    .font(.app(12))
                                    .textSelection(.enabled)
                            }
                        }

                        labeled("主题") {
                            Text(info.subject)
                                .font(.app(12.5, weight: .medium))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if let warning = info.warning {
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.app(10))
                                    .foregroundStyle(Theme.gold)
                                Text(warning)
                                    .font(.app(11.5))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.gold.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                        }

                        labeled("正文") {
                            Text(info.body)
                                .font(.app(12))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .padding(18)
                }
                .hoverScrollIndicators()

                Divider().opacity(0.4)
                footer
            }
            .frame(width: 580, height: 560)
        }
    }

    private func header(_ info: AppModel.PendingSendInfo) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "paperplane.fill")
                .font(.app(13))
                .foregroundStyle(Theme.brick)
            VStack(alignment: .leading, spacing: 2) {
                Text("确认发送这封邮件？")
                    .font(.app(14, weight: .semibold))
                Text(info.restricted
                     ? "由不可信模型起草 · 发送后无法撤回"
                     : "发送后无法撤回")
                    .font(.app(11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("收件人可在上方直接修改")
                .font(.app(11))
                .foregroundStyle(.tertiary)
            Spacer()
            Button("取消") {
                model.resolveSendConfirmation(false)
            }
            .keyboardShortcut(.cancelAction)
            Button("发送") {
                model.resolveSendConfirmation(true)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.brick)
            .disabled(model.pendingSendTo.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func labeled<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.app(11, weight: .medium))
                .foregroundStyle(.secondary)
            content()
        }
    }
}
