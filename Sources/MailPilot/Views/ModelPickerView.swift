import SwiftUI

final class ModelPickerForm: ObservableObject {
    @Published var query = ""
    @Published var busy = false
    @Published var status: String?
    @Published var onlyChat = true
    @Published var showAdd = false
}

struct ModelPickerView: View {
    let providerID: String

    @EnvironmentObject private var ai: AISettingsStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var form = ModelPickerForm()

    private var provider: AIProvider? {
        ai.providers.first { $0.id == providerID }
    }

    private var catalog: [String] {
        provider?.availableModels ?? provider?.models ?? []
    }

    private var filtered: [String] {
        var list = catalog
        if form.onlyChat {
            list = list.filter { provider?.isChatModel($0) ?? ModelFilter.isChat($0) }
        }
        let q = form.query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            list = list.filter {
                $0.localizedCaseInsensitiveContains(q)
                    || (provider?.displayName(for: $0).localizedCaseInsensitiveContains(q) ?? false)
            }
        }
        return list
    }

    private var hiddenCount: Int {
        guard form.onlyChat else { return 0 }
        return catalog.filter { !(provider?.isChatModel($0) ?? ModelFilter.isChat($0)) }.count
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                Divider().opacity(0.5)
                searchBar
                list
                Divider().opacity(0.5)
                footer
            }
            .frame(width: 620, height: 560)
            .background(.regularMaterial)

            if form.showAdd {
                Color.black.opacity(0.20)
                    .frame(width: 620, height: 560)
                    .onTapGesture { form.showAdd = false }

                AddModelView(providerID: providerID) { form.showAdd = false }
                    .environmentObject(ai)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.28), radius: 28, y: 10)
            }
        }
        .frame(width: 620, height: 560)
        .onAppear { loadIfNeeded() }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 8) {
            Text("选择模型")
                .font(.system(size: 14, weight: .semibold))
            Text("\(catalog.count)")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .frame(height: 18)
                .background(Color.primary.opacity(0.07), in: Capsule())
            Spacer()
            if form.busy {
                ProgressView().controlSize(.small)
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .frame(height: 50)
    }

    // MARK: - 搜索与批量

    private var searchBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("搜索模型…", text: $form.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                if !form.query.isEmpty {
                    Button { form.query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 8) {
                Text("已选 \(provider?.models.count ?? 0) / \(catalog.count)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("全选") { selectAll(true) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("·").font(.system(size: 10)).foregroundStyle(.tertiary)
                Button("清空") { selectAll(false) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Toggle("只看对话模型", isOn: $form.onlyChat)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if hiddenCount > 0 {
                    Text("已隐藏 \(hiddenCount) 个图像 / 语音 / 向量模型")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: - 列表

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if filtered.isEmpty {
                    Text(form.busy ? "正在拉取模型列表…" : "没有匹配的模型")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 40)
                }
                ForEach(filtered, id: \.self) { model in
                    row(model)
                    Divider().opacity(0.3).padding(.leading, 40)
                }
            }
            .padding(.horizontal, 12)
        }
        .scrollIndicators(.visible)
    }

    private func row(_ model: String) -> some View {
        let selected = provider?.models.contains(model) ?? false
        let isCurrent = provider?.selectedModel == model
        return Button {
            toggle(model)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(selected ? Theme.accent : Color.secondary.opacity(0.45))

                VStack(alignment: .leading, spacing: 1) {
                    Text(provider?.displayName(for: model) ?? model)
                        .font(.system(size: 12.5))
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .lineLimit(1)
                    if let p = provider, p.displayName(for: model) != model {
                        Text(model)
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                if let group = provider?.groupName(for: model), !group.isEmpty {
                    Text(group)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .frame(height: 15)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }

                if isCurrent {
                    Text("当前")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .frame(height: 15)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                }

                Spacer(minLength: 6)

                Image(systemName: selected ? "minus.circle" : "plus.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Theme.brick.opacity(0.75) : Theme.accent)
            }
            .padding(.horizontal, 8)
            .frame(height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: 10) {
            Button("添加模型") { form.showAdd = true }
            if let status = form.status {
                Text(status)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("刷新列表") { load(force: true) }
                .disabled(form.busy)
            Button("完成") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                }
        .padding(.horizontal, 18)
        .frame(height: 56)
    }

    // MARK: - 数据

    private func toggle(_ model: String) {
        guard let provider else { return }
        if provider.models.contains(model) {
            ai.update(id: providerID) {
                $0.models.removeAll { $0 == model }
                if $0.selectedModel == model {
                    $0.selectedModel = $0.models.first ?? ""
                }
            }
        } else {
            ai.update(id: providerID) {
                $0.models.append(model)
                if $0.selectedModel.isEmpty { $0.selectedModel = model }
            }
        }
    }

    private func selectAll(_ on: Bool) {
        let targets = Set(filtered)
        ai.update(id: providerID) { p in
            if on {
                var list = p.models
                for model in targets where !list.contains(model) {
                    list.append(model)
                }
                p.models = list
                if p.selectedModel.isEmpty { p.selectedModel = list.first ?? "" }
            } else {
                p.models = p.models.filter { !targets.contains($0) }
                if !p.models.contains(p.selectedModel) {
                    p.selectedModel = p.models.first ?? ""
                }
            }
        }
    }

    private func loadIfNeeded() {
        guard let provider else { return }
        if (provider.availableModels ?? []).isEmpty {
            load(force: true)
        }
    }

    private func load(force: Bool) {
        guard let provider, !form.busy else { return }
        form.busy = true
        form.status = "正在拉取…"
        Task { @MainActor in
            do {
                let models = try await AIService.fetchModels(provider: provider)
                ai.update(id: providerID) { $0.availableModels = models }
                form.status = models.isEmpty ? "服务端没有返回模型" : "共 \(models.count) 个模型"
            } catch {
                form.status = "失败：\(error.localizedDescription)"
            }
            form.busy = false
        }
    }
}
