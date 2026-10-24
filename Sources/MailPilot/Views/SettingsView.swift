import SwiftUI

enum SettingsSheet: String, Identifiable {
    case add, keys, test, models, addModel
    var id: String { rawValue }
}

final class SettingsForm: ObservableObject {
    @Published var selectedID: String?
    @Published var revealKey = false
    @Published var newModel = ""
    @Published var status: String?
    @Published var busy = false
    @Published var activeSheet: SettingsSheet?
    @Published var pendingDeleteID: String?
}

struct SettingsView: View {
    @EnvironmentObject private var ai: AISettingsStore
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var form = SettingsForm()

    private var current: AIProvider? {
        guard let id = form.selectedID else { return nil }
        return ai.providers.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("", selection: $model.settingsTab) {
                    ForEach(SettingsTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 400)

                Spacer()

                Button("完成") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }
            .padding(.horizontal, 16)
            .frame(height: 46)

            Divider().opacity(0.6)

            switch model.settingsTab {
            case .permissions:
                PermissionView()
            case .providers:
                HStack(spacing: 0) {
                    providerList
                        .frame(width: 214)
                    Divider().opacity(0.6)
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            case .features:
                AIFeaturesView()
            case .about:
                AboutView()
            }
        }
        .frame(width: 820, height: 660)
        .background(.regularMaterial)
        .onAppear {
            if form.selectedID == nil { form.selectedID = ai.providers.first?.id }
        }
        .sheet(item: $form.activeSheet) { sheet in
            switch sheet {
            case .add:
                AddProviderView { id in
                    form.selectedID = id
                    form.status = nil
                }
                .environmentObject(ai)
            case .keys:
                APIKeyManagerView(providerID: form.selectedID ?? "")
                    .environmentObject(ai)
            case .test:
                TestModelView(providerID: form.selectedID ?? "")
                    .environmentObject(ai)
            case .models:
                ModelPickerView(providerID: form.selectedID ?? "")
                    .environmentObject(ai)
            case .addModel:
                AddModelView(providerID: form.selectedID ?? "") {
                    form.activeSheet = nil
                }
                .environmentObject(ai)
            }
        }
    }

    // MARK: - 左侧服务商列表

    private var providerList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("服务商")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(ai.providers.filter(\.enabled).count) 启用")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .frame(height: 32)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(ai.providers) { provider in
                        providerRow(provider)
                    }
                }
                .padding(.horizontal, 8)
            }
            .hoverScrollIndicators()

            Divider().opacity(0.6)

            Button {
                form.activeSheet = .add
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                    Text("添加服务商")
                }
                .font(.system(size: 12))
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
    }

    private func providerRow(_ provider: AIProvider) -> some View {
        let selected = form.selectedID == provider.id
        let active = ai.activeProvider?.id == provider.id
        return HStack(spacing: 7) {
            ProviderAvatar(provider: provider, size: 20)
            Text(provider.name)
                .font(.system(size: 12.5))
                .foregroundStyle(provider.enabled ? Color.primary : Color.secondary)
                .lineLimit(1)
            Spacer(minLength: 2)
            if active {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Theme.accent.opacity(0.15) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            form.selectedID = provider.id
            form.status = nil
        }
    }

    // MARK: - 右侧详情

    @ViewBuilder
    private var detail: some View {
        if let provider = current {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header(provider)
                    trustSection(provider)
                    keySection(provider)
                    baseSection(provider)
                    modelSection(provider)
                    footer(provider)
                }
                .padding(22)
            }
            .hoverScrollIndicators()
            .confirmationDialog(
                "删除该服务商？",
                isPresented: Binding(
                    get: { form.pendingDeleteID != nil },
                    set: { if !$0 { form.pendingDeleteID = nil } }
                ),
                presenting: form.pendingDeleteID
            ) { id in
                Button("删除", role: .destructive) {
                    ai.remove(id: id)
                    form.selectedID = ai.providers.first?.id
                    form.pendingDeleteID = nil
                }
                Button("取消", role: .cancel) { form.pendingDeleteID = nil }
            } message: { _ in
                Text("该服务商的密钥与模型配置会一并移除。")
            }
        } else {
            VStack(spacing: 8) {
                Text("还没有服务商")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text("在左下角添加一个")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(_ provider: AIProvider) -> some View {
        HStack(spacing: 10) {
            ProviderAvatar(provider: provider, size: 34)

            TextField("服务商名称", text: stringBinding(provider, \.name))
                .textFieldStyle(.plain)
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: 260)

            Text(provider.kind.label)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .frame(height: 19)
                .background(Color.primary.opacity(0.06), in: Capsule())

            Spacer()

            Button {
                form.pendingDeleteID = provider.id
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.brick.opacity(0.9))
                    .frame(width: 28, height: 28)
                    .background(Theme.brick.opacity(0.10), in: Circle())
            }
            .buttonStyle(.plain)
            .help("删除该服务商")

            Toggle("", isOn: boolBinding(provider, \.enabled))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
    }

    // MARK: - 信任

    // MARK: - 信任

    /// 模型级信任切换：继承 → 强制可信 → 强制不可信 → 继承
    private func nextTrustOverride(_ provider: AIProvider, _ model: String) -> Bool? {
        switch provider.trustOverride(model) {
        case .none: return true
        case .some(true): return false
        case .some(false): return nil
        }
    }

    private func trustBadgeIcon(_ provider: AIProvider, _ model: String) -> String {
        switch provider.trustOverride(model) {
        case .none: return "shield.lefthalf.filled"
        case .some(true): return "checkmark.shield.fill"
        case .some(false): return "exclamationmark.shield.fill"
        }
    }

    private func trustBadgeColor(_ provider: AIProvider, _ model: String) -> Color {
        switch provider.trustOverride(model) {
        case .none: return Color.secondary.opacity(0.55)
        case .some(true): return Theme.moss
        case .some(false): return Theme.gold
        }
    }

    private func trustBadgeHelp(_ provider: AIProvider, _ model: String) -> String {
        let inherited = provider.isTrustedProvider ? "可信" : "不可信"
        switch provider.trustOverride(model) {
        case .none:
            return "继承供应商（\(inherited)）。点击改为「强制可信」"
        case .some(true):
            return "已强制可信，忽略供应商设置。点击改为「强制不可信」"
        case .some(false):
            return "已强制不可信，忽略供应商设置。点击恢复继承"
        }
    }

    /// 供应商级信任开关。默认不可信，用户手动开启后其下模型才放行
    private func trustSection(_ provider: AIProvider) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: trustIcon(provider))
                .font(.system(size: 13))
                .foregroundStyle(trustColor(provider))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(trustTitle(provider))
                    .font(.system(size: 12, weight: .medium))
                Text(trustDetail(provider))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if !provider.kind.isLocal {
                Toggle("", isOn: Binding(
                    get: { provider.isTrustedProvider },
                    set: { ai.setProviderTrusted(provider.id, $0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .help(provider.isTrustedProvider ? "关闭后其下模型全部回到不可信" : "开启后其下模型默认可信")
            }
        }
        .padding(11)
        .background(trustColor(provider).opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
    }

    private func trustIcon(_ provider: AIProvider) -> String {
        if provider.kind.isLocal { return "lock.shield.fill" }
        return provider.isTrustedProvider ? "checkmark.shield.fill" : "exclamationmark.shield"
    }

    private func trustColor(_ provider: AIProvider) -> Color {
        if provider.kind.isLocal { return Theme.moss }
        return provider.isTrustedProvider ? Theme.moss : Theme.gold
    }

    private func trustTitle(_ provider: AIProvider) -> String {
        if provider.kind.isLocal { return "本地模型" }
        return provider.isTrustedProvider ? "可信供应商" : "不可信供应商（默认）"
    }

    private func trustDetail(_ provider: AIProvider) -> String {
        if provider.kind.isLocal {
            return "数据不出本机，无需信任设置"
        }
        if provider.isTrustedProvider {
            return "其下模型原样发送，不做脱敏、不弹确认。仅在你确认该服务商的数据政策可信时开启"
        }
        return "其下模型发送前会自动脱敏；草拟回复 / 翻译等会产生对外内容的动作，每次发送前需你确认"
    }

    private func keySection(_ provider: AIProvider) -> some View {        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text("API 密钥").font(.system(size: 12, weight: .medium))
                if provider.allKeys.count > 1 {
                    Text("+\(provider.allKeys.count - 1)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 8) {
                Button {
                    form.activeSheet = .keys
                } label: {
                    HStack {
                        Text(keySummary(provider))
                            .font(.system(size: 12.5, design: .monospaced))
                            .foregroundStyle(provider.hasKey || provider.kind.isLocal ? Color.primary : Color.secondary)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .frame(maxWidth: .infinity)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("管理多条 API 密钥")

                Button {
                    form.activeSheet = .keys
                } label: {
                    Image(systemName: "key")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .help("API 密钥管理")

                Button {
                    form.activeSheet = .test
                } label: {
                    Text("检测")
                        .font(.system(size: 12))
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                }
                .buttonStyle(.bordered)
                .disabled(provider.models.isEmpty && provider.selectedModel.isEmpty)
            }
        }
    }

    private func keySummary(_ provider: AIProvider) -> String {
        if provider.kind.isLocal { return provider.hasKey ? (provider.primaryKey?.masked ?? "本地模型") : "本地模型无需密钥" }
        guard let primary = provider.primaryKey else { return "未配置密钥，点击添加" }
        return primary.masked
    }

    private func baseSection(_ provider: AIProvider) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("API 地址")
                    .font(.system(size: 12, weight: .medium))
                if let status = form.status {
                    Text(status)
                        .font(.system(size: 10.5))
                        .foregroundStyle(status.hasPrefix("失败") ? Theme.brick : Color.secondary)
                        .lineLimit(1)
                }
            }

            HStack(spacing: 8) {
                TextField("https://api.example.com（/v1 可省略）", text: stringBinding(provider, \.baseURL))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, design: .monospaced))
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))

                Button {
                    ai.update(id: provider.id) { $0.baseURL = provider.kind.defaultBase }
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .help("恢复默认地址")
            }

            Text("实际请求：\(AIService.previewRequestURL(base: provider.baseURL, kind: provider.kind))")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .textSelection(.enabled)

            HStack(spacing: 5) {
                Image(systemName: provider.kind.isLocal ? "lock.shield.fill" : "lock.shield")
                    .font(.system(size: 10))
                Text(provider.kind.isLocal
                     ? "本地模型，邮件内容不出本机"
                     : "推荐使用本地模型：邮件内容不会离开这台电脑")
                    .font(.system(size: 10.5))
            }
            .foregroundStyle(provider.kind.isLocal ? Theme.moss : Color.secondary)
        }
    }

    private func modelSection(_ provider: AIProvider) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("模型")
                    .font(.system(size: 12, weight: .medium))
                Text("\(provider.models.count)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    form.activeSheet = .addModel
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text("添加")
                    }
                    .font(.system(size: 11.5))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    form.activeSheet = .models
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "checklist")
                        Text("选择模型")
                    }
                    .font(.system(size: 11.5))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    syncModels(provider)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("同步模型")
                    }
                    .font(.system(size: 11.5))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(form.busy)
            }

            VStack(spacing: 0) {
                if provider.models.isEmpty {
                    Text("还没有选中模型，点「同步模型」拉取后挑选")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 10)
                }

                ForEach(provider.models, id: \.self) { model in
                    modelRow(provider, model)
                    if model != provider.models.last {
                        Divider().opacity(0.35)
                    }
                }
            }
            .padding(.horizontal, 10)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
        }
    }

    private func modelRow(_ provider: AIProvider, _ model: String) -> some View {
        let selected = provider.selectedModel == model
        return HStack(spacing: 8) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 11))
                .foregroundStyle(selected ? Theme.accent : Color.secondary.opacity(0.6))
            Text(provider.displayName(for: model))
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer()

            if !provider.kind.isLocal {
                Button {
                    ai.setModelTrust(provider.id, model: model, nextTrustOverride(provider, model))
                } label: {
                    Image(systemName: trustBadgeIcon(provider, model))
                        .font(.system(size: 11))
                        .foregroundStyle(trustBadgeColor(provider, model))
                }
                .buttonStyle(.plain)
                .help(trustBadgeHelp(provider, model))
            }

            Button {
                ai.update(id: provider.id) {
                    $0.models.removeAll { $0 == model }
                    if $0.selectedModel == model { $0.selectedModel = $0.models.first ?? "" }
                }
            } label: {
                Image(systemName: "minus.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .frame(height: 32)
        .contentShape(Rectangle())
        .onTapGesture {
            ai.update(id: provider.id) { $0.selectedModel = model }
        }
    }

    private func footer(_ provider: AIProvider) -> some View {
        HStack {
            Text(ai.activeProvider?.id == provider.id
                 ? "当前使用：\(provider.name) · \(provider.selectedModel)"
                 : "未在使用（需要启用、填密钥、选模型）")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.top, 4)
    }

    // MARK: - 动作

    private func probe(_ provider: AIProvider) {
        form.busy = true
        form.status = "检测中…"
        Task { @MainActor in
            do {
                let models = try await AIService.fetchModels(provider: provider)
                let normalized = AIService.normalizedBase(provider.baseURL, kind: provider.kind)
                ai.update(id: provider.id) {
                    $0.baseURL = normalized
                    $0.availableModels = models
                    // 只自动选中一个对话模型，其余交给用户挑
                    if $0.models.isEmpty, let first = models.first(where: ModelFilter.isChat) ?? models.first {
                        $0.models = [first]
                        if $0.selectedModel.isEmpty { $0.selectedModel = first }
                    }
                }
                form.status = models.isEmpty ? "连接成功，但没有返回模型" : "发现 \(models.count) 个模型"
                if models.count > 1 {
                    form.activeSheet = .models
                }
            } catch {
                form.status = "失败：\(error.localizedDescription)"
            }
            form.busy = false
        }
    }

    private func syncModels(_ provider: AIProvider) {
        probe(provider)
    }

    // MARK: - 绑定

    private func stringBinding(_ provider: AIProvider, _ keyPath: WritableKeyPath<AIProvider, String>) -> Binding<String> {
        Binding(
            get: { ai.providers.first { $0.id == provider.id }?[keyPath: keyPath] ?? "" },
            set: { value in ai.update(id: provider.id) { $0[keyPath: keyPath] = value } }
        )
    }

    private func boolBinding(_ provider: AIProvider, _ keyPath: WritableKeyPath<AIProvider, Bool>) -> Binding<Bool> {
        Binding(
            get: { ai.providers.first { $0.id == provider.id }?[keyPath: keyPath] ?? false },
            set: { value in ai.update(id: provider.id) { $0[keyPath: keyPath] = value } }
        )
    }
}
