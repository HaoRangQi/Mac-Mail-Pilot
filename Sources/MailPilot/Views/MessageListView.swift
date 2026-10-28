import SwiftUI

struct MessageListView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.threadGroups) { group in
                        row(group.latest, threadCount: group.count)
                        Divider().opacity(0.35).padding(.leading, 24)
                    }
                    if model.canLoadMore {
                        loadMoreRow
                    }
                }
            }
            .hoverScrollIndicators()
            if model.selectMode {
                selectionBar
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .glassPanel()
        .alert("移入废纸篓？", isPresented: $model.showBatchDeleteConfirm) {
            Button("移入废纸篓", role: .destructive) {
                Task { await model.confirmBatchDelete() }
            }
            Button("取消", role: .cancel) { model.pendingBatchDelete = [] }
        } message: {
            Text(model.isDemo
                 ? "选中的 \(model.pendingBatchDelete.count) 封（演示数据）只会从列表移除。"
                 : "选中的 \(model.pendingBatchDelete.count) 封将在「邮件」App 中移入各自账户的废纸篓，可在那里恢复。")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(model.query.isEmpty ? model.selectionTitle : "搜索结果")
                .font(.app(12.5, weight: .semibold))
            Spacer()
            Text("\(model.messages.count) 封")
                .font(.app(11))
                .foregroundStyle(.tertiary)
            // 多选是「批量删除」的入口。搜索态也允许用——搜出来一批再一起删很常见
            Button(model.selectMode ? "完成" : "选择") {
                model.toggleSelectMode()
            }
            .buttonStyle(.plain)
            .font(.app(11))
            .foregroundStyle(model.selectMode ? Theme.accent : Color.secondary)
        }
        .padding(.horizontal, 16)
        .frame(height: 34)
    }

    /// 一页 200 封，翻到底再翻倍。不自动无限拉：那是拿启动时间和内存换一个很少用到的深度
    private var loadMoreRow: some View {
        Button {
            Task { await model.loadMoreMessages() }
        } label: {
            Text("加载更多（已显示 \(model.messages.count) 封）")
                .font(.app(11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var selectionBar: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.5)
            HStack(spacing: 12) {
                Button("全选") { model.selectAllVisible() }
                    .buttonStyle(.plain)
                    .font(.app(11))
                    .foregroundStyle(.secondary)

                Button("清空") { model.multiSelected.removeAll() }
                    .buttonStyle(.plain)
                    .font(.app(11))
                    .foregroundStyle(.secondary)
                    .disabled(model.multiSelected.isEmpty)

                Spacer()

                Text("已选 \(model.multiSelected.count) 封")
                    .font(.app(11))
                    .foregroundStyle(.tertiary)

                Button {
                    model.requestBatchDelete()
                } label: {
                    Text("删除")
                        .font(.app(11.5, weight: .medium))
                        .foregroundStyle(model.multiSelected.isEmpty ? Color.secondary : Color.white)
                        .padding(.horizontal, 12)
                        .frame(height: 24)
                        .background(model.multiSelected.isEmpty
                                    ? AnyShapeStyle(Color.primary.opacity(0.06))
                                    : AnyShapeStyle(Theme.brick),
                                    in: Capsule())
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.multiSelected.isEmpty)

                // 批量上锁：所选全部已锁时按钮变成解锁，方便原地反悔
                Button {
                    model.lockSelected(!allSelectedLocked)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: allSelectedLocked ? "lock.open" : "lock")
                            .font(.app(9.5, weight: .semibold))
                        Text(allSelectedLocked ? "解锁" : "上锁")
                            .font(.app(11.5, weight: .medium))
                    }
                    .foregroundStyle(model.multiSelected.isEmpty ? Color.secondary : Color.primary)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(Color.primary.opacity(0.05), in: Capsule())
                    .overlay(Capsule().stroke(Color.primary.opacity(0.07), lineWidth: 0.5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.multiSelected.isEmpty)
                .help(allSelectedLocked
                      ? "解锁所选邮件"
                      : "上锁所选邮件：不可信模型看不到，也不参与问答检索与历史回放")
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
        }
    }

    private var allSelectedLocked: Bool {
        let targets = model.multiSelectedMessages
        return !targets.isEmpty && targets.allSatisfy { model.isLocked($0) }
    }

    @ViewBuilder
    private func row(_ message: Message, threadCount: Int = 1) -> some View {
        let active = model.selected?.id == message.id
        let picked = model.multiSelected.contains(message.id)
        let locked = model.isLocked(message)
        Button {
            Task { await model.open(message) }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                if model.selectMode {
                    Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                        .font(.app(12))
                        .foregroundStyle(picked ? Theme.accent : Color.secondary.opacity(0.5))
                        .padding(.top, 2)
                } else {
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 6, height: 6)
                        .padding(.top, 6)
                        .opacity(message.unread ? 1 : 0)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(message.displaySender)
                            .font(.app(12.5, weight: message.unread ? .semibold : .regular))
                            .lineLimit(1)
                        if message.flagged {
                            Image(systemName: "flag.fill")
                                .font(.app(9))
                                .foregroundStyle(.orange)
                        }
                        // 上锁必须一眼看得出来：账号级锁也走同一个判定
                        if locked {
                            Image(systemName: "lock.fill")
                                .font(.app(9))
                                .foregroundStyle(Theme.brick)
                                .help("已上锁：不可信模型看不到这封邮件")
                        }
                        Spacer(minLength: 4)
                        // 会话角标：同一线程的其余几封不在列表里重复出现
                        if threadCount > 1 {
                            Text("\(threadCount)")
                                .font(.app(9.5, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .frame(minWidth: 16, minHeight: 15)
                                .background(Color.primary.opacity(0.07), in: Capsule())
                        }
                        Text(Self.dateText(message.date))
                            .font(.app(10.5))
                            .foregroundStyle(.tertiary)
                    }
                    Text(message.subject)
                        .font(.app(12.5, weight: message.unread ? .medium : .regular))
                        .foregroundStyle(message.unread ? .primary : .secondary)
                        .lineLimit(1)
                    Text(message.preview)
                        .font(.app(11.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(UIState.previewLines)
                        .padding(.top, 1)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, UIState.rowPadding)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(active || (model.selectMode && picked)
                          ? Theme.accent.opacity(0.12)
                          : Color.clear)
            )
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                model.setLocked(!locked, for: message)
            } label: {
                Label(locked ? "解锁这封邮件" : "上锁（不可信模型不可见）",
                      systemImage: locked ? "lock.open" : "lock")
            }
        }
    }

    static func dateText(_ date: Date) -> String {
        // 解析失败的历史数据可能落在 1970 之前，别显示成「1/1/1」
        guard date.timeIntervalSince1970 > 0 else { return "—" }
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
