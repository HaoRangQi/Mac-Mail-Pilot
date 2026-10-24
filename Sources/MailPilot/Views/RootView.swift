import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            AppBackground()
            VStack(spacing: Theme.gap) {
                TopBar()
                HStack(spacing: Theme.gap) {
                    SidebarView()
                        .frame(width: Theme.sidebarWidth)
                    MessageListView()
                        .frame(width: Theme.listWidth)
                    ReaderView()
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(Theme.gap + 2)
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
        .tint(Theme.accent)
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
                    .font(.system(size: 12))
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

struct TopBar: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "envelope.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tint)
                Text("MailPilot")
                    .font(.system(size: 13, weight: .semibold))
                Text("0.2")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 13)
            .frame(height: 32)
            .glassEffect(.regular, in: .capsule)

            if model.isDemo {
                Text("演示数据")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(Theme.gold.opacity(0.12), in: Capsule())
            }

            Button {
                model.toggleAsk()
            } label: {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.aiGradient)
                    .frame(width: 44, height: 30)
                    .background(
                        Theme.aiGradient.opacity(0.14),
                        in: Capsule()
                    )
                    .overlay(
                        Capsule().stroke(Theme.aiGradient.opacity(0.35), lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .help("问问 AI（⌘K）")

            Button {
                model.cycleAppearance()
            } label: {
                Image(systemName: model.appearance.icon)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(Color.primary.opacity(0.05), in: Circle())
            }
            .buttonStyle(.plain)
            .help("外观：\(model.appearance.label)（点击切换）")

            Button {
                model.showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(Color.primary.opacity(0.05), in: Circle())
            }
            .buttonStyle(.plain)
            .help("模型服务设置")

            Button {
                Task { await model.reload() }
            } label: {
                if model.syncing {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 30, height: 30)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(Color.primary.opacity(0.05), in: Circle())
                }
            }
            .buttonStyle(.plain)
            .help("同步最新邮件（⌘R）")
            .disabled(model.syncing)

            Button {
                model.composing = true
            } label: {
                Label("写邮件", systemImage: "square.and.pencil")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.regular)

            Spacer(minLength: 8)

            searchField
        }
        .frame(height: 36)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(searchFocused ? Theme.moss : Color.secondary)
            TextField("搜索邮件", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($searchFocused)
                .onChange(of: model.query) { _, _ in model.scheduleSearch() }
            if !model.query.isEmpty {
                Button {
                    model.query = ""
                    model.scheduleSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .frame(width: 300)
        .glassEffect(.regular.tint(Theme.moss.opacity(searchFocused ? 0.42 : 0.26)), in: .capsule)
        .overlay(
            Capsule().stroke(
                Theme.moss.opacity(searchFocused ? 0.55 : 0.20),
                lineWidth: searchFocused ? 1 : 0.8
            )
        )
        .animation(.easeOut(duration: 0.15), value: searchFocused)
    }
}
