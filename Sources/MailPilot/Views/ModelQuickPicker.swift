import SwiftUI

final class QuickPickerForm: ObservableObject {
    @Published var query = ""
}

/// 顶栏弹出的模型快速切换面板（参考 Cherry Studio 的模型下拉）：
/// 搜索 + 按服务商分组 + 当前项打勾，底部直达模型服务设置。
struct ModelQuickPicker: View {
    @EnvironmentObject private var ai: AISettingsStore
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var form = QuickPickerForm()

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider().opacity(0.5)

            if groups.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(groups, id: \.provider.id) { group in
                            Text(group.provider.name)
                                .font(.app(10.5, weight: .medium))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .padding(.horizontal, 14)
                                .padding(.top, 10)
                                .padding(.bottom, 3)

                            ForEach(group.models, id: \.self) { modelID in
                                row(group.provider, modelID)
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
            }

            Divider().opacity(0.5)
            footer
        }
        .frame(width: 380, height: 440)
    }

    // MARK: - 数据

    private var groups: [(provider: AIProvider, models: [String])] {
        let query = form.query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return ai.selectableGroups }
        return ai.selectableGroups.compactMap { group in
            let filtered = group.models.filter {
                $0.lowercased().contains(query)
                    || group.provider.displayName(for: $0).lowercased().contains(query)
            }
            return filtered.isEmpty ? nil : (group.provider, filtered)
        }
    }

    // MARK: - 组件

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.app(11))
                .foregroundStyle(.secondary)
            TextField("搜索模型…", text: $form.query)
                .textFieldStyle(.plain)
                .font(.app(12.5))
            if !form.query.isEmpty {
                Button {
                    form.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.app(10))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
    }

    private func row(_ provider: AIProvider, _ modelID: String) -> some View {
        let selected = ai.activeProvider?.id == provider.id && provider.selectedModel == modelID
        return Button {
            ai.selectModel(providerID: provider.id, model: modelID)
            model.showToast("已切换到 \(provider.displayName(for: modelID))")
            dismiss()
        } label: {
            HStack(spacing: 8) {
                Text(provider.displayName(for: modelID))
                    .font(.app(12.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)

                if !provider.kind.isLocal, !provider.isTrusted(modelID) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(.app(9))
                        .foregroundStyle(Theme.gold)
                        .help("不可信模型：发送前会自动脱敏")
                }

                if selected {
                    Image(systemName: "checkmark")
                        .font(.app(10, weight: .semibold))
                        .foregroundStyle(Theme.moss)
                }
            }
            .foregroundStyle(selected ? Theme.moss : Color.primary)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected ? Theme.moss.opacity(0.10) : Color.clear)
            )
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "cpu")
                .font(.app(22, weight: .light))
                .foregroundStyle(.tertiary)
            Text(form.query.isEmpty ? "没有可用的模型" : "没有匹配的模型")
                .font(.app(12))
                .foregroundStyle(.secondary)
            if form.query.isEmpty {
                Text("先在「模型服务」里配置服务商与 API Key")
                    .font(.app(11))
                    .foregroundStyle(.tertiary)
                Button("打开模型服务") {
                    dismiss()
                    model.openSettings(tab: .providers)
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.accent)
                .controlSize(.small)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "slider.horizontal.3")
                .font(.app(11))
            Text("配置模型服务")
                .font(.app(12))
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 40)
        .contentShape(Rectangle())
        .onTapGesture {
            dismiss()
            model.openSettings(tab: .providers)
        }
    }
}
