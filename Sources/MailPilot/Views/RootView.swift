import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            AppBackground(settings: model.ui.settings)
            VStack(spacing: Theme.gap) {
                TopBar()
                HStack(spacing: Theme.gap) {
                    if !model.readerExpanded {
                        SidebarView()
                            .frame(width: Theme.sidebarWidth)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                        MessageListView()
                            .frame(width: Theme.listWidth)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    ReaderView()
                        .frame(maxWidth: .infinity)
                        .transition(.opacity)
                }
                .animation(.spring(response: 0.34, dampingFraction: 0.88), value: model.readerExpanded)
            }
            // 顶部只留 2pt：上面已经是系统给红绿灯预留的 title bar 安全区，
            // 再加 12pt padding 会让顶栏和标题栏之间空出一条明显的白带
            .padding(.horizontal, Theme.gap + 2)
            .padding(.top, 2)
            .padding(.bottom, Theme.gap + 2)
        }
        .frame(minWidth: 1000, minHeight: 640)
        .overlay(alignment: .top) {
            if model.showAsk {
                AskBar()
                    .padding(.top, 54)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .overlay {
            if model.showOnboarding {
                OnboardingView()
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.16), value: model.showAsk)
        .preferredColorScheme(model.appearance.colorScheme)
        // 不在这里全局 .tint()：macOS 的滚动条会跟着 tint 变色，
        // 深绿 tint 会让侧边栏/列表的滚动条变成墨绿色，喧宾夺主。
        // 强调色改为在各个主按钮上单独 .tint(Theme.accent)。
        .task { await model.load() }
        .sheet(isPresented: $model.composing) {
            ComposeView()
        }
        .sheet(isPresented: $model.showSettings) {
            SettingsView()
                .environmentObject(model.ai)
                .environmentObject(model.prefs)
                .environmentObject(model)
        }
        // 发送确认挂在根视图而不是 AskBar：浮窗可以被 Esc 关掉，
        // 但「要不要把这封邮件发出去」的决定不能跟着一起消失
        .sheet(isPresented: Binding(
            get: { model.pendingSendInfo != nil },
            set: { presented in if !presented { model.resolveSendConfirmation(false) } }
        )) {
            SendConfirmSheet()
                .environmentObject(model)
        }
        .sheet(isPresented: Binding(
            get: { model.pendingBatch != nil },
            set: { presented in if !presented { model.resolveBatch(false) } }
        )) {
            BatchConfirmSheet()
                .environmentObject(model)
        }
        .alert("操作失败", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { presented in if !presented { model.errorMessage = nil } }
        )) {
            Button("知道了") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Text(toast)
                    .font(.app(12))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
                    .padding(.bottom, 26)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.toast)
    }
}

/// CLT 环境缺少 SwiftUIMacros，@State 是宏、编不过，这里沿用 ObservableObject 承载。
final class TopBarState: ObservableObject {
    @Published var showModelPicker = false
}

struct TopBar: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var searchFocused: Bool
    @StateObject private var ui = TopBarState()

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "envelope.fill")
                    .font(.app(12, weight: .medium))
                    .foregroundStyle(.tint)
                Text("MailPilot")
                    .font(.app(13, weight: .semibold))
                Text("0.2")
                    .font(.app(10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 13)
            .frame(height: 32)
            .glassEffect(.regular, in: .capsule)

            if model.isDemo {
                Text("演示数据")
                    .font(.app(11, weight: .medium))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(Theme.gold.opacity(0.12), in: Capsule())
            }

            Button {
                model.toggleAsk()
            } label: {
                // 玻璃底 + 渐变图标 + 渐变细描边：既保住液态玻璃的透感，
                // 又能在一张浅色背景图上认出这是 AI 入口
                Image(systemName: "sparkles")
                    .font(.app(13, weight: .semibold))
                    .foregroundStyle(Theme.aiButtonGradient)
                    .frame(width: 40, height: 30)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .overlay {
                        Capsule().stroke(Theme.aiButtonGradient.opacity(0.55), lineWidth: 0.9)
                    }
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("问问 AI（⌘K）")

            modelPicker

            Button {
                model.cycleAppearance()
            } label: {
                Image(systemName: model.appearance.icon)
                    .font(.app(12))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .help("外观：\(model.appearance.label)（点击切换，右键进外观设置）")
            .contextMenu {
                Button("外观设置…") { model.openSettings(tab: .appearance) }
            }

            Button {
                model.showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.app(12))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .help("设置（⌘,）")

            Button {
                Task { await model.reload() }
            } label: {
                if model.syncing {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 30, height: 30)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.app(12))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
            }
            .buttonStyle(.plain)
            .help("同步最新邮件（⌘R）")
            .disabled(model.syncing)

            Button {
                model.composing = true
            } label: {
                Label("写邮件", systemImage: "square.and.pencil")
                    .font(.app(12, weight: .medium))
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.accent)
            .controlSize(.regular)

            Spacer(minLength: 8)

            searchField
        }
        .frame(height: 34)
    }

    /// 当前模型指示器 + 快速切换。用户要随时知道「现在是谁在干活」
    private var modelPicker: some View {
        Button {
            ui.showModelPicker.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: trustBadge)
                    .font(.app(9.5))
                Text(activeModelLabel)
                    .font(.app(11.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.app(7.5, weight: .semibold))
            }
            .foregroundStyle(model.ai.activeModelTrusted ? Color.secondary : Theme.gold)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .frame(maxWidth: 200)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
        .help(modelPickerHelp)
        .popover(isPresented: $ui.showModelPicker, arrowEdge: .bottom) {
            ModelQuickPicker()
                .environmentObject(model.ai)
                .environmentObject(model)
        }
    }

    private var activeModelLabel: String {
        guard let provider = model.ai.activeProvider else { return "未配置模型" }
        return provider.displayName(for: provider.selectedModel)
    }

    private var trustBadge: String {
        guard let provider = model.ai.activeProvider else { return "cpu" }
        if provider.kind.isLocal { return "lock.shield.fill" }
        return provider.isTrusted(provider.selectedModel) ? "checkmark.shield.fill" : "exclamationmark.shield.fill"
    }

    private var modelPickerHelp: String {
        guard let provider = model.ai.activeProvider else {
            return "还没有可用模型，点击配置"
        }
        let trust = provider.isTrusted(provider.selectedModel)
            ? (provider.kind.isLocal ? "本地模型，数据不出本机" : "可信模型")
            : "不可信模型，发送前会脱敏"
        return "当前模型：\(provider.displayName(for: provider.selectedModel))（\(trust)）\n点击切换"
    }

    private var searchField: some View {        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.app(11))
                .foregroundStyle(searchFocused ? Theme.moss : Color.secondary)
            TextField("搜索邮件", text: $model.query)
                .textFieldStyle(.plain)
                .font(.app(12.5))
                .focused($searchFocused)
                .tint(Theme.moss)
                .onChange(of: model.query) { _, _ in model.scheduleSearch() }
            if !model.query.isEmpty {
                Button {
                    model.query = ""
                    model.scheduleSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.app(11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .frame(width: 300)
        .glassEffect(.regular, in: .capsule)
        .overlay(
            Capsule().stroke(
                Theme.moss.opacity(searchFocused ? 0.85 : 0.40),
                lineWidth: searchFocused ? 1.4 : 1
            )
        )
        .animation(.easeOut(duration: 0.15), value: searchFocused)
    }
}
