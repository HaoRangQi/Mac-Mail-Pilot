import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel

    private let favorites: [SmartBox] = [.allInbox, .allFlagged, .allDrafts, .allSent]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                sectionHeader("个人收藏", key: "fav")
                if !model.collapsedSections.contains("fav") {
                    ForEach(favorites) { box in
                        smartRow(box)
                    }
                }

                sectionHeader("智能邮箱", key: "smart", topPadding: 12)
                if !model.collapsedSections.contains("smart") {
                    smartRow(.today)
                }

                ForEach(visibleAccounts) { account in
                    sectionHeader(
                        account.name,
                        key: account.id,
                        topPadding: 14,
                        badge: unreadCount(for: account)
                    )
                    if !model.collapsedSections.contains(account.id) {
                        ForEach(visibleBoxes(for: account)) { box in
                            mailboxRow(box)
                        }
                    }
                }
            }
            .padding(.bottom, 16)
        }
        .scrollIndicators(.hidden)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassPanel()
    }

    // MARK: - 分组头

    /// 只显示有内容的账户：14 个账户里有多个是空的（只有内部文件夹），全列出来只是噪音
    private var visibleAccounts: [Account] {
        model.accounts.filter { !visibleBoxes(for: $0).isEmpty }
    }

    /// 标准邮箱（收件箱/已发送/草稿/废纸篓/归档）始终显示；
    /// 自定义文件夹只在真的装了邮件时才显示
    private func visibleBoxes(for account: Account) -> [Mailbox] {
        model.mailboxes.filter {
            $0.accountID == account.id && ($0.role != .custom || $0.total > 0)
        }
    }

    private func sectionHeader(_ title: String, key: String, topPadding: CGFloat = 10, badge: Int = 0) -> some View {
        let collapsed = model.collapsedSections.contains(key)
        return Button {
            withAnimation(.easeInOut(duration: 0.14)) {
                model.toggleSection(key)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 9, alignment: .center)
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 11)
            .padding(.top, topPadding)
            .padding(.bottom, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func unreadCount(for account: Account) -> Int {
        model.mailboxes
            .filter { $0.accountID == account.id }
            .reduce(0) { $0 + $1.unread }
    }

    // MARK: - 行

    private func smartRow(_ box: SmartBox) -> some View {
        row(
            id: box.rawValue,
            title: box.title,
            icon: box.icon,
            badge: model.badges[box.rawValue] ?? 0
        )
    }

    private func mailboxRow(_ box: Mailbox) -> some View {
        row(
            id: box.id,
            title: box.name,
            icon: icon(for: box.role),
            badge: box.unread > 0 ? box.unread : box.total
        )
    }

    private func row(id: String, title: String, icon: String, badge: Int) -> some View {
        let active = model.selectedMailboxID == id
        return Button {
            Task { await model.selectMailbox(id) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11.5))
                    .frame(width: 16)
                    .foregroundStyle(active ? Color.white : Color.secondary)
                Text(title)
                    .font(.system(size: 12.5, weight: active ? .medium : .regular))
                    .foregroundStyle(active ? Color.white : Color.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(active ? Color.white.opacity(0.9) : Color.secondary)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 17, minHeight: 15)
                        .background(
                            active ? Color.white.opacity(0.22) : Color.primary.opacity(0.06),
                            in: Capsule()
                        )
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(active ? Theme.accent : Color.clear)
            )
            .padding(.horizontal, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func icon(for role: Mailbox.Role) -> String {
        switch role {
        case .inbox: return "tray"
        case .sent: return "paperplane"
        case .drafts: return "square.and.pencil"
        case .archive: return "archivebox"
        case .trash: return "trash"
        case .custom: return "folder"
        }
    }
}
