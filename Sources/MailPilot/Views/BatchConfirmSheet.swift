import SwiftUI

/// 批量处理确认。
///
/// 为什么要有这一层：模型逐封调用 `moveToTrash` 时，用户要点 N 次确认框，
/// 点到后面就是无脑点「确认」——那比批量更危险。把全部目标摊开、
/// 让用户勾选，才谈得上是「人做的决定」。
struct BatchConfirmSheet: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let batch = model.pendingBatch {
            VStack(alignment: .leading, spacing: 0) {
                header(batch)
                Divider().opacity(0.4)
                selectionBar(batch)
                Divider().opacity(0.3)

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(batch.messages) { message in
                            row(message, selected: batch.selected.contains(message.id))
                            Divider().opacity(0.25).padding(.leading, 34)
                        }
                    }
                }
                .hoverScrollIndicators()

                Divider().opacity(0.4)
                footer(batch)
            }
            .frame(width: 600, height: 580)
        }
    }

    // MARK: - 头部

    private func header(_ batch: AppModel.BatchProposal) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon(for: batch.action))
                .font(.app(14))
                .foregroundStyle(tint(for: batch.action))
            VStack(alignment: .leading, spacing: 3) {
                Text(title(for: batch.action))
                    .font(.app(14, weight: .semibold))
                if !batch.reason.isEmpty {
                    Text(batch.reason)
                        .font(.app(11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: - 全选

    private func selectionBar(_ batch: AppModel.BatchProposal) -> some View {
        HStack(spacing: 10) {
            Button(batch.selected.count == batch.messages.count ? "全不选" : "全选") {
                model.setBatchSelection(batch.selected.count != batch.messages.count)
            }
            .buttonStyle(.plain)
            .font(.app(11.5))
            .foregroundStyle(.secondary)

            Spacer()

            Text("已选 \(batch.selected.count) / \(batch.messages.count) 封")
                .font(.app(11.5))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
    }

    // MARK: - 行

    private func row(_ message: Message, selected: Bool) -> some View {
        Button {
            model.toggleBatchSelection(message.id)
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.app(13))
                    .foregroundStyle(selected ? Theme.accent : Color.secondary.opacity(0.5))
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(message.displaySender)
                            .font(.app(12))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(MessageListView.dateText(message.date))
                            .font(.app(10))
                            .foregroundStyle(.tertiary)
                    }
                    Text(message.subject)
                        .font(.app(12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 底部

    private func footer(_ batch: AppModel.BatchProposal) -> some View {
        HStack(spacing: 10) {
            if batch.action == "trash" {
                Text("移入「邮件」App 的废纸篓，可在那里恢复")
                    .font(.app(11))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button("取消") { model.resolveBatch(false) }
                .keyboardShortcut(.cancelAction)
            Button(batch.action == "trash" ? "移入废纸篓" : "执行") {
                model.resolveBatch(true)
            }
            .buttonStyle(.borderedProminent)
            .tint(batch.action == "trash" ? Theme.brick : Theme.accent)
            .disabled(batch.selected.isEmpty)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: - 文案

    private func title(for action: String) -> String {
        switch action {
        case "trash": return "把这些邮件移入废纸篓？"
        case "markread": return "把这些邮件标为已读？"
        case "setflag": return "给这些邮件加旗标？"
        default: return "确认批量处理？"
        }
    }

    private func icon(for action: String) -> String {
        switch action {
        case "trash": return "trash.fill"
        case "markread": return "envelope.open.fill"
        case "setflag": return "flag.fill"
        default: return "checklist"
        }
    }

    private func tint(for action: String) -> Color {
        switch action {
        case "trash": return Theme.brick
        case "setflag": return Theme.gold
        default: return Theme.accent
        }
    }
}
