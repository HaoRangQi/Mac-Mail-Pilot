import SwiftUI

final class AskBarUI: ObservableObject {
    @Published var showScope = false
    @Published var showClearConfirm = false
}

struct AskBar: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var focused: Bool
    @StateObject private var ui = AskBarUI()

    private var border: LinearGradient { Theme.aiGradient }

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            topRow

            if !model.askHistory.isEmpty {
                historyView
            }
            if model.askBusy && model.askHistory.isEmpty {
                busyCard
            }
            suggestions
            scopeBar
            inputRow
        }
        .padding(10)
        .frame(width: 580)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(border, lineWidth: 1.2)
        )
        .shadow(color: .black.opacity(0.12), radius: 18, y: 6)
        .onExitCommand { model.closeAsk() }
        .onAppear { focused = true }
        .alert(
            "确认执行这个操作？",
            isPresented: Binding(
                get: { model.pendingToolCall != nil },
                set: { presented in if !presented { model.resolveToolConfirmation(false) } }
            )
        ) {
            Button("确认执行", role: .destructive) {
                model.resolveToolConfirmation(true)
            }
            Button("取消", role: .cancel) {
                model.resolveToolConfirmation(false)
            }
        } message: {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.pendingToolCall?.humanSummary ?? "")
                if model.pendingToolCall?.tool == .moveToTrash {
                    Text("只是移入「邮件」App 的废纸篓，可以在那里恢复。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .confirmationDialog("清空全部对话记录？", isPresented: $ui.showClearConfirm) {
            Button("清空", role: .destructive) { model.clearAskHistory() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("\(model.askHistory.count) 条记录会被删除，此操作不可恢复。")
        }
    }

    // MARK: - 顶部

    private var topRow: some View {
        HStack(spacing: 8) {
            Button {
                model.closeAsk()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .background(Color.primary.opacity(0.07), in: Circle())
            }
            .buttonStyle(.plain)
            .help("关闭（Esc）")

            Spacer(minLength: 4)

            if !model.askHistory.isEmpty {
                if model.askSelectMode {
                    Button {
                        model.deleteSelectedAsks()
                    } label: {
                        Text(model.askSelected.isEmpty ? "删除" : "删除（\(model.askSelected.count)）")
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.askSelected.isEmpty)

                    Button("完成") {
                        model.askSelectMode = false
                        model.askSelected = []
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                } else {
                    Button("选择") {
                        model.askSelectMode = true
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))

                    Button("清空") {
                        ui.showClearConfirm = true
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                }
            }
        }
        .padding(.leading, 2)
    }

    // MARK: - 历史

    private var historyView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.askHistory) { turn in
                        turnView(turn)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
            }
            .hoverScrollIndicators()
            .frame(maxHeight: 280)
            .onChange(of: model.askHistory.count) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    private func turnView(_ turn: AskTurn) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Spacer(minLength: 24)

                if model.askSelectMode {
                    Image(systemName: model.askSelected.contains(turn.id) ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 11))
                        .foregroundStyle(model.askSelected.contains(turn.id) ? Theme.accent : Color.secondary.opacity(0.5))
                }

                Text(turn.question)
                    .font(.system(size: 11.5))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if model.askSelectMode { model.toggleAskSelect(turn.id) }
            }

            if turn.answer.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("正在读你的邮箱…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10))
                        .foregroundStyle(border)
                        .padding(.top, 3)
                    Text(turn.answer)
                        .font(.system(size: 12))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "at")
                    .font(.system(size: 9))
                Text(turn.accounts.joined(separator: "、"))
                    .font(.system(size: 10.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(stamp(turn.date))
                    .font(.system(size: 10.5))
                    .monospacedDigit()

                if model.askSelectMode {
                    Button {
                        model.toggleAskSelect(turn.id)
                    } label: {
                        Text(model.askSelected.contains(turn.id) ? "已选" : "选择")
                            .font(.system(size: 10.5))
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        model.deleteAskTurn(turn.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: 18)
                            .background(Color.primary.opacity(0.10), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("删除这条记录")
                }
            }
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func stamp(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(date: .numeric, time: .shortened)
    }

    // MARK: - 建议

    private var suggestions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.askSuggestions, id: \.self) { text in
                    Button {
                        model.askText = text
                        model.ask()
                    } label: {
                        Text(text)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color(red: 0.45, green: 0.42, blue: 0.85))
                            .padding(.horizontal, 12)
                            .frame(height: 26)
                            .background(.thinMaterial, in: Capsule())
                            .overlay(Capsule().stroke(border.opacity(0.55), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
        }
        .padding(.leading, 2)
    }

    // MARK: - 操作范围

    private var scopeBar: some View {
        HStack {
            Button {
                ui.showScope.toggle()
            } label: {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: model.askAllAccounts ? "tray.full" : "person.crop.circle")
                        .font(.system(size: 10))
                        .padding(.top, 1)

                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(model.askScopeNames.prefix(4)), id: \.self) { name in
                            Text(name)
                                .font(.system(size: 11))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        if model.askScopeNames.count > 4 {
                            Text("等 \(model.askScopeNames.count) 个")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 7))
                        .padding(.top, 2)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(border.opacity(0.35), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .popover(isPresented: $ui.showScope, arrowEdge: .bottom) {
                scopePanel
            }

            Spacer()
        }
        .padding(.leading, 2)
    }

    private var scopePanel: some View {
        VStack(spacing: 0) {
            Button {
                model.toggleAllAccounts()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: model.askAllAccounts ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 11))
                        .foregroundStyle(model.askAllAccounts ? Theme.accent : Color.secondary.opacity(0.5))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("所有账号").font(.system(size: 12))
                        Text("\(model.accounts.count) 个账号的邮件")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 10)
                .frame(height: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider().opacity(0.4)

            ScrollView {
                LazyVStack(spacing: 0) {
                    if model.accounts.isEmpty {
                        Text("没有可用账号")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 18)
                    }
                    ForEach(model.accounts) { account in
                        accountRow(account)
                    }
                }
            }
            .frame(height: 240)
            .hoverScrollIndicators()
        }
        .frame(width: 300)
    }

    private func accountRow(_ account: Account) -> some View {
        let dimmed = model.askAllAccounts
        let picked = !dimmed && model.askAccounts.contains(account.id)
        return Button {
            model.toggleAskAccount(account.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11))
                    .foregroundStyle(picked ? Theme.accent : Color.secondary.opacity(0.5))
                Text(account.name)
                    .font(.system(size: 11.5))
                    .foregroundStyle(dimmed ? Color.secondary : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .opacity(dimmed ? 0.55 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 输入

    /// 走带工具的问答：AI 可以调 searchMessages / getMessage / listMailboxes 查邮件
    private func submit() {
        let text = model.askText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.askText = ""
        Task { await model.askWithTools(text) }
    }

    private var inputRow: some View {        HStack(spacing: 9) {
            Image(systemName: "sparkles")
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(border)

            TextField("随便问问…", text: $model.askText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onSubmit { submit() }

            if model.askBusy {
                ProgressView().controlSize(.mini)
            } else if !model.askText.isEmpty {
                Button {
                    submit()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            } else if !model.askHistory.isEmpty {
                Button {
                    model.closeAsk()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("关闭（Esc）")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(Color.primary.opacity(0.04), in: Capsule())
        .overlay(Capsule().stroke(border, lineWidth: 1.2))
    }

    private var busyCard: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("正在读你的邮箱…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }
}
