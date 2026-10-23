import SwiftUI

struct MessageListView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.messages) { message in
                        row(message)
                        Divider().opacity(0.35).padding(.leading, 24)
                    }
                }
            }
            .scrollIndicators(.visible)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .glassPanel()
    }

    private var header: some View {
        HStack {
            Text(model.query.isEmpty ? model.selectionTitle : "搜索结果")
                .font(.system(size: 12.5, weight: .semibold))
            Spacer()
            Text("\(model.messages.count) 封")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .frame(height: 34)
    }

    @ViewBuilder
    private func row(_ message: Message) -> some View {
        let active = model.selected?.id == message.id
        Button {
            Task { await model.open(message) }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
                    .padding(.top, 6)
                    .opacity(message.unread ? 1 : 0)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(message.displaySender)
                            .font(.system(size: 12.5, weight: message.unread ? .semibold : .regular))
                            .lineLimit(1)
                        if message.flagged {
                            Image(systemName: "flag.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.orange)
                        }
                        Spacer(minLength: 4)
                        Text(Self.dateText(message.date))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    }
                    Text(message.subject)
                        .font(.system(size: 12.5, weight: message.unread ? .medium : .regular))
                        .foregroundStyle(message.unread ? .primary : .secondary)
                        .lineLimit(1)
                    Text(message.preview)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .padding(.top, 1)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(active ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    static func dateText(_ date: Date) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        if cal.isDateInToday(date) {
            f.dateFormat = "HH:mm"
        } else if cal.isDateInYesterday(date) {
            return "昨天"
        } else if cal.component(.year, from: date) == cal.component(.year, from: Date()) {
            f.dateFormat = "M月d日"
        } else {
            f.dateFormat = "yyyy/M/d"
        }
        return f.string(from: date)
    }
}
