import AppKit
import SwiftUI

struct ReaderView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var prefs: AIPreferencesStore

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
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "envelope.open")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text("选择一封邮件")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
        }
    }

    private func detail(_ message: Message) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(message.subject)
                        .font(.system(size: 19, weight: .semibold))
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .padding(.bottom, 10)

                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(message.displaySender)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)

                        if !message.senderEmail.isEmpty {
                            Text(message.senderEmail)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)

                            Button {
                                copyToPasteboard(message.senderEmail)
                                model.showToast("已复制邮箱地址")
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .help("复制发件人邮箱")
                        }

                        Spacer(minLength: 10)

                        Text(dateText(message.date))
                            .font(.system(size: 11.5))
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

                    HStack(spacing: 6) {
                        if message.needsReply { Chip(text: "待回复") }
                        if message.flagged { Chip(text: "已标记") }
                        if !message.threadID.isEmpty { Chip(text: "会话") }
                    }
                    .padding(.top, 9)

                    Divider().opacity(0.5).padding(.vertical, 14)

                    if message.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("（这封邮件没有正文）")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.tertiary)
                    } else {
                        Text(message.body)
                            .font(.system(size: 13.5))
                            .lineSpacing(6)
                            .textSelection(.enabled)
                            .frame(maxWidth: 760, alignment: .leading)
                    }

                    if !message.attachments.isEmpty {
                        HStack(spacing: 7) {
                            ForEach(message.attachments) { att in
                                HStack(spacing: 5) {
                                    Image(systemName: "paperclip")
                                        .font(.system(size: 10))
                                    Text(att.filename)
                                        .font(.system(size: 11.5))
                                    if !att.sizeText.isEmpty {
                                        Text(att.sizeText)
                                            .font(.system(size: 10.5))
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
                .padding(.horizontal, 26)
                .padding(.top, 22)
                .padding(.bottom, 20)
            }
            .scrollIndicators(.visible)

            aiBar
        }
    }

    private var aiBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            if prefs.prefs.quickRepliesEnabled {
                HStack(spacing: 6) {
                    Text("快速回复")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                    ForEach(prefs.prefs.quickReplies, id: \.self) { text in
                        Button {
                            model.draftReply(instruction: text)
                        } label: {
                            Text(text)
                                .font(.system(size: 11.5))
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
                aiButton("AI 摘要", icon: "sparkles") { model.summarize() }
                aiButton("草拟回复", icon: "arrowshape.turn.up.left") { model.draftReply() }
                aiButton("分类", icon: "tag") { model.classify() }
                if prefs.prefs.translateEnabled {
                    aiButton("翻译", icon: "character.bubble") { model.translate() }
                }
                Spacer()
                if model.aiBusy {
                    ProgressView().controlSize(.small)
                }
                if model.deleting {
                    ProgressView().controlSize(.small)
                } else if let message = model.selected {
                    Button {
                        model.requestDelete(message)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.brick)
                            .frame(width: 27, height: 27)
                            .background(Theme.brick.opacity(0.10), in: Circle())
                            .overlay(Circle().stroke(Theme.brick.opacity(0.20), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .help("移入「邮件」App 的废纸篓")
                }
            }

            if let output = model.aiOutput {
                ScrollView {
                    Text(output)
                        .font(.system(size: 12.5))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 150)
                .padding(11)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
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

    private func aiButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10.5))
                Text(title).font(.system(size: 12))
            }
            .padding(.horizontal, 11)
            .frame(height: 27)
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(0.05), in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.07), lineWidth: 0.5))
        .disabled(model.selected == nil)
    }

    // MARK: - 复制与日期

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
