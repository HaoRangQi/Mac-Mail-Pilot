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

                // 三层：服务商 → 账号 → 邮箱。
                // 十几个账号平铺时根本分不清哪个是哪个，先按服务商收一层，
                // 视觉上立刻从「一堵墙」变成「六个大类」。
                ForEach(groupedAccounts) { group in
                    serviceHeader(group)
                    if !model.collapsedSections.contains(group.sectionKey) {
                        ForEach(group.accounts) { account in
                            accountHeader(account)
                            if !model.collapsedSections.contains(account.id) {
                                ForEach(visibleBoxes(for: account)) { box in
                                    mailboxRow(box, indent: 20)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.bottom, 16)
        }
        .hoverScrollIndicators()
        .frame(maxHeight: .infinity, alignment: .top)
        .glassPanel()
    }

    // MARK: - 分组

    private struct AccountGroup: Identifiable {
        let service: MailService
        let accounts: [Account]
        var id: String { service.rawValue }
        var sectionKey: String { "svc:" + service.rawValue }
    }

    /// 按服务商归组，只保留有内容的账号；顺序跟 `MailService.allCases` 一致（其他放最后）
    private var groupedAccounts: [AccountGroup] {
        let grouped = Dictionary(grouping: visibleAccounts, by: \.service)
        return MailService.allCases.compactMap { service in
            guard let list = grouped[service], !list.isEmpty else { return nil }
            return AccountGroup(
                service: service,
                accounts: list.sorted { displayName($0).localizedStandardCompare(displayName($1)) == .orderedAscending }
            )
        }
    }

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

    /// 账号名多半就是邮箱地址，显示时去掉 @ 后面那截，省宽度
    private func displayName(_ account: Account) -> String {
        let name = account.name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return account.email }
        if name.contains("@") {
            return String(name.split(separator: "@").first ?? Substring(name))
        }
        return name
    }

    private func serviceTint(_ service: MailService) -> Color {
        switch service {
        case .gmail: return Color.hex(0xD9534F)
        case .outlook: return Color.hex(0x2B7CD3)
        case .icloud: return Color.hex(0x4A90D9)
        case .yahoo: return Color.hex(0x7B4FBF)
        case .qq: return Color.hex(0x2A9BD8)
        case .netease: return Color.hex(0xD64541)
        case .other: return Color.secondary
        }
    }

    // MARK: - 分组头

    private func sectionHeader(_ title: String, key: String, topPadding: CGFloat = 10, badge: Int = 0) -> some View {
        let collapsed = model.collapsedSections.contains(key)
        return Button {
            withAnimation(.easeInOut(duration: 0.14)) {
                model.toggleSection(key)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.app(8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 9, alignment: .center)
                Text(title)
                    .font(.app(10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if badge > 0 {
                    Text("\(badge)")
                        .font(.app(9.5))
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

    /// 服务商大类。比账号头重一档：带色点、字号略大、上方留白多
    private func serviceHeader(_ group: AccountGroup) -> some View {
        let collapsed = model.collapsedSections.contains(group.sectionKey)
        let unread = group.accounts.reduce(0) { $0 + unreadCount(for: $1) }
        return Button {
            withAnimation(.easeInOut(duration: 0.14)) {
                model.toggleSection(group.sectionKey)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.app(8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 9, alignment: .center)

                Circle()
                    .fill(serviceTint(group.service))
                    .frame(width: 6, height: 6)

                Text(group.service.label)
                    .font(.app(11, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(1)

                Text("\(group.accounts.count)")
                    .font(.app(9.5))
                    .foregroundStyle(.tertiary)

                Spacer(minLength: 4)

                if unread > 0 {
                    Text("\(unread)")
                        .font(.app(9.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 11)
            .padding(.top, 13)
            .padding(.bottom, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(group.service.label)：\(group.accounts.count) 个账号")
    }

    /// 账号（二级）。可折叠，默认展开
    private func accountHeader(_ account: Account) -> some View {
        let collapsed = model.collapsedSections.contains(account.id)
        let unread = unreadCount(for: account)
        return Button {
            withAnimation(.easeInOut(duration: 0.14)) {
                model.toggleSection(account.id)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.app(7.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 8, alignment: .center)
                Text(displayName(account))
                    .font(.app(11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if unread > 0 {
                    Text("\(unread)")
                        .font(.app(9.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.leading, 22)
            .padding(.trailing, 11)
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(account.email)
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

    private func mailboxRow(_ box: Mailbox, indent: CGFloat = 0) -> some View {
        row(
            id: box.id,
            title: box.name,
            icon: icon(for: box.role),
            badge: box.unread > 0 ? box.unread : box.total,
            indent: indent
        )
    }

    private func row(id: String, title: String, icon: String, badge: Int, indent: CGFloat = 0) -> some View {
        let active = model.selectedMailboxID == id
        return Button {
            Task { await model.selectMailbox(id) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.app(11.5))
                    .frame(width: 16)
                    .foregroundStyle(active ? Color.white : Color.secondary)
                Text(title)
                    .font(.app(12.5, weight: active ? .medium : .regular))
                    .foregroundStyle(active ? Color.white : Color.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if badge > 0 {
                    Text("\(badge)")
                        .font(.app(10.5, weight: .medium))
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
            .padding(.leading, 7 + indent)
            .padding(.trailing, 7)
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
