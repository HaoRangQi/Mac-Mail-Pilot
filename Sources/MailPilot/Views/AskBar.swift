import SwiftUI

final class AskBarUI: ObservableObject {
    @Published var showScope = false
    @Published var showClearConfirm = false
    /// 全屏：把浮层撑满窗口，长回答不用在 280pt 的小窗里挤
    @Published var expanded = false
    /// 正在编辑的提问（只允许改最新一条）
    @Published var editingTurnID: String?
    @Published var editingText = ""
}

struct AskBar: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var focused: Bool
    @StateObject private var ui = AskBarUI()

    private var border: LinearGradient { Theme.aiGradient }

    /// 面板底色。薄材质叠在花哨背景图上时，`.secondary` 会被稀释到几乎看不见，
    /// 所以在材质上再压一层窗口底色：玻璃感还在，但内容有了稳定的对比基准。
    private var panelWash: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color(nsColor: .windowBackgroundColor).opacity(0.46))
    }

    /// 按钮文字用「明确的深色」而不是 `.secondary`——
    /// 后者是给纯色背景设计的，在材质上会被背景色吃掉
    private var inkStrong: Color { Color.primary.opacity(0.78) }
    private var inkSoft: Color { Color.primary.opacity(0.55) }

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
        .frame(minWidth: ui.expanded ? 0 : 580,
               maxWidth: ui.expanded ? .infinity : 580,
               maxHeight: ui.expanded ? .infinity : nil)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .background(panelWash)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(border, lineWidth: 1.2)
        )
        .shadow(color: .black.opacity(0.12), radius: 18, y: 6)
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: ui.expanded)
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
                        .font(.app(11))
                        .foregroundStyle(.secondary)
                    if model.sessionTrashCount > 0 {
                        Text("本次对话已删除 \(model.sessionTrashCount) 封，单次最多 5 封。")
                            .font(.app(11))
                            .foregroundStyle(Theme.gold)
                    }
                }
            }
        }
        .alert(
            "把问题发送给不可信模型？",
            isPresented: Binding(
                get: { model.pendingAskConfirm != nil },
                set: { presented in if !presented { model.resolveAskConfirmation(false) } }
            )
        ) {
            Button("发送") { model.resolveAskConfirmation(true) }
            Button("取消", role: .cancel) { model.resolveAskConfirmation(false) }
        } message: {
            Text("目标：\(model.pendingAskConfirm?.providerName ?? "") / \(model.pendingAskConfirm?.model ?? "")\n\n工具读到的邮件内容会先脱敏。但脱敏防不住语义信息，重要内容请换成本地模型。")
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
        HStack(spacing: 10) {
            chromeButton(icon: "xmark", help: "关闭（Esc）") {
                model.closeAsk()
            }

            Spacer(minLength: 4)

            chromeButton(icon: ui.expanded
                         ? "arrow.down.right.and.arrow.up.left"
                         : "arrow.up.left.and.arrow.down.right",
                         help: ui.expanded ? "还原浮窗" : "全屏展开") {
                ui.expanded.toggle()
            }

            if !model.askHistory.isEmpty {
                if model.askSelectMode {
                    chromeText(model.askSelected.isEmpty ? "删除" : "删除（\(model.askSelected.count)）",
                               tint: model.askSelected.isEmpty ? Theme.brick.opacity(0.45) : Theme.brick) {
                        model.deleteSelectedAsks()
                    }
                    .disabled(model.askSelected.isEmpty)

                    chromeText("全选", tint: .secondary) {
                        model.askSelected = Set(model.askHistory.map(\.id))
                    }

                    chromeText("完成", tint: .secondary) {
                        model.askSelectMode = false
                        model.askSelected = []
                    }
                } else {
                    chromeText("选择", tint: .secondary) {
                        model.askSelectMode = true
                    }

                    chromeText("清空", tint: Theme.brick) {
                        ui.showClearConfirm = true
                    }
                    .help("清空全部对话记录（不可恢复）")
                }
            }
        }
        .padding(.leading, 2)
    }

    /// 顶部工具按钮统一样式：同尺寸圆形底 + 同一档图标色。
    /// 之前图标有的 8pt 有的 10pt、有的没底色，深浅不一，看着很散
    private func chromeButton(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.app(9.5, weight: .semibold))
                .foregroundStyle(inkStrong)
                .frame(width: 22, height: 22)
                .background(Color.primary.opacity(0.13), in: Circle())
                .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 0.6))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// 顶部文字按钮：统一字号与内边距，只让颜色区分危险与否。
    /// 文字按钮也补一层淡底，否则在材质上就是几团飘着的字
    private func chromeText(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.app(11.5, weight: .medium))
                .foregroundStyle(tint)
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(tint.opacity(0.12), in: Capsule())
                .overlay(Capsule().stroke(tint.opacity(0.26), lineWidth: 0.6))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
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
            .frame(maxHeight: ui.expanded ? .infinity : 280)
            .onChange(of: model.askHistory.count) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    private func turnView(_ turn: AskTurn) -> some View {
        let isLatest = model.askHistory.last?.id == turn.id
        let editing = ui.editingTurnID == turn.id

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Spacer(minLength: 24)

                if model.askSelectMode {
                    Image(systemName: model.askSelected.contains(turn.id) ? "checkmark.circle.fill" : "circle")
                        .font(.app(11))
                        .foregroundStyle(model.askSelected.contains(turn.id) ? Theme.accent : Color.secondary.opacity(0.5))
                }

                // 只有最新一条能改：改历史提问会让后面的回答对不上上下文
                if isLatest, !model.askSelectMode, !editing {
                    Button {
                        ui.editingText = turn.question
                        ui.editingTurnID = turn.id
                    } label: {
                        Image(systemName: "pencil")
                            .font(.app(9.5, weight: .medium))
                            .foregroundStyle(inkStrong)
                            .frame(width: 22, height: 22)
                            .background(Color.primary.opacity(0.13), in: Circle())
                            .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 0.6))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("改一下再重跑")
                }

                if editing {
                    TextField("", text: $ui.editingText)
                        .textFieldStyle(.plain)
                        .font(.app(11.5))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Theme.accent.opacity(0.26),
                                    in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .stroke(Theme.accent.opacity(0.55), lineWidth: 0.9)
                        }
                        .onSubmit { commitEdit(turn) }

                    chromeText("重跑", tint: Theme.accent) { commitEdit(turn) }
                    chromeText("取消", tint: .secondary) {
                        ui.editingTurnID = nil
                    }
                } else {
                    Text(turn.question)
                        .font(.app(11.5))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        // 之前 14% 太淡，几乎看不出这是个气泡；加深并补一圈描边
                        .background(Theme.accent.opacity(0.26),
                                    in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .stroke(Theme.accent.opacity(0.42), lineWidth: 0.7)
                        }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if model.askSelectMode { model.toggleAskSelect(turn.id) }
            }

            if turn.answer.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("正在读你的邮箱…")
                        .font(.app(12))
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "sparkles")
                        .font(.app(10))
                        .foregroundStyle(border)
                        .padding(.top, 3)

                    // Markdown 渲染：标题 / 列表 / 代码块 / 粗体不再以源码形式露出
                    MarkdownText(text: turn.answer, baseSize: 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // 静默脱敏是信任黑洞：必须让用户看见这次到底改掉了什么
                if !turn.redactions.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "shield.lefthalf.filled")
                            .font(.app(9))
                        Text("已脱敏 \(turn.redactions.count) 处：\(Redactor.summary(turn.redactions))")
                            .font(.app(10))
                    }
                    .foregroundStyle(Theme.gold)
                    .padding(.leading, 17)
                }

                // 每条回答的操作条：复制、重跑
                HStack(spacing: 14) {
                    answerAction("复制", icon: "doc.on.doc") {
                        copyToPasteboard(turn.answer)
                        model.showToast("已复制这条回答")
                    }
                    answerAction("重跑", icon: "arrow.clockwise") {
                        Task { await model.rerunAsk(turn.id) }
                    }
                    Spacer()
                }
                .padding(.leading, 17)
            }

            HStack(spacing: 6) {
                Image(systemName: "at")
                    .font(.app(9))
                Text(turn.accounts.joined(separator: "、"))
                    .font(.app(10.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(stamp(turn.date))
                    .font(.app(10.5))
                    .monospacedDigit()

                if model.askSelectMode {
                    Button {
                        model.toggleAskSelect(turn.id)
                    } label: {
                        Text(model.askSelected.contains(turn.id) ? "已选" : "选择")
                            .font(.app(10.5))
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        model.deleteAskTurn(turn.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.app(9, weight: .bold))
                            .foregroundStyle(Theme.brick)
                            .frame(width: 20, height: 20)
                            .background(Theme.brick.opacity(0.16), in: Circle())
                            .overlay(Circle().stroke(Theme.brick.opacity(0.28), lineWidth: 0.6))
                    }
                    .buttonStyle(.plain)
                    .help("删除这条记录")
                }
            }
            .foregroundStyle(inkSoft)
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// 回答下方的小按钮（复制 / 重跑）
    private func answerAction(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.app(9.5))
                Text(title)
                    .font(.app(10.5, weight: .medium))
            }
            .foregroundStyle(inkStrong)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(Color.primary.opacity(0.08), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func commitEdit(_ turn: AskTurn) {
        let text = ui.editingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        ui.editingTurnID = nil
        Task { await model.rerunAsk(turn.id, question: text) }
    }

    private func copyToPasteboard(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
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
                            .font(.app(11.5))
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
                        .font(.app(10))
                        .padding(.top, 1)

                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(model.askScopeNames.prefix(4)), id: \.self) { name in
                            Text(name)
                                .font(.app(11))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        if model.askScopeNames.count > 4 {
                            Text("等 \(model.askScopeNames.count) 个")
                                .font(.app(10))
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.app(7))
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
                        .font(.app(11))
                        .foregroundStyle(model.askAllAccounts ? Theme.accent : Color.secondary.opacity(0.5))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("所有账号").font(.app(12))
                        Text("\(model.accounts.count) 个账号的邮件")
                            .font(.app(10))
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
                            .font(.app(11))
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
                    .font(.app(11))
                    .foregroundStyle(picked ? Theme.accent : Color.secondary.opacity(0.5))
                Text(account.name)
                    .font(.app(11.5))
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
                .font(.app(13.5, weight: .medium))
                .foregroundStyle(border)

            TextField("随便问问…", text: $model.askText)
                .textFieldStyle(.plain)
                .font(.app(13))
                .focused($focused)
                .onSubmit { submit() }

            if model.askBusy {
                ProgressView().controlSize(.mini)
            } else if !model.askText.isEmpty {
                Button {
                    submit()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.app(15))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            } else if !model.askHistory.isEmpty {
                Button {
                    model.closeAsk()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.app(13))
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
                .font(.app(12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }
}
