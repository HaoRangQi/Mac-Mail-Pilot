import SwiftUI

struct TestItem: Identifiable {
    let id = UUID()
    let model: String
    let ok: Bool
    let text: String
}

final class TestForm: ObservableObject {
    @Published var model = ""
    @Published var prompt = AIService.defaultTestPrompt
    @Published var busy = false
    @Published var progress = ""
    @Published var results: [TestItem] = []
}

struct TestModelView: View {
    let providerID: String

    @EnvironmentObject private var ai: AISettingsStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var form = TestForm()

    private var provider: AIProvider? {
        ai.providers.first { $0.id == providerID }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    modelPicker
                    keyRow
                    promptRow
                    if !form.results.isEmpty || form.busy {
                        resultList
                    }
                }
                .padding(20)
            }
            .hoverScrollIndicators()

            Divider().opacity(0.5)
            footer
        }
        .frame(width: 640, height: 580)
        .background(.regularMaterial)
        .onAppear {
            if form.model.isEmpty, let provider {
                form.model = provider.selectedModel.isEmpty
                    ? (provider.models.first ?? "")
                    : provider.selectedModel
            }
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .top) {
            Text("请选择要检测的模型")
                .font(.app(14, weight: .semibold))
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.app(11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    // MARK: - 表单

    private var modelPicker: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("选择模型").font(.app(12, weight: .medium))
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    if let provider {
                        ProviderAvatar(provider: provider, size: 18)
                        Picker("", selection: $form.model) {
                            if provider.models.isEmpty {
                                Text("尚未同步模型").tag("")
                            }
                            ForEach(provider.models, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("服务商不存在")
                            .font(.app(12))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 36)
                .frame(maxWidth: .infinity)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))

                Button {
                    runSingle()
                } label: {
                    HStack(spacing: 4) {
                        if form.busy {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "play.fill").font(.app(8))
                        }
                        Text("检测")
                            .font(.app(11.5, weight: .medium))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11)
                    .frame(height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Theme.accent)
                    )
                    .opacity(form.busy || form.model.isEmpty ? 0.4 : 1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(height: 36)
                .disabled(form.busy || form.model.isEmpty)
                .help("只检测当前选中的模型")
            }
        }
    }

    private var keyRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("API 密钥").font(.app(12, weight: .medium))
            HStack {
                Text(provider?.primaryKey?.masked ?? (provider?.kind.isLocal == true ? "本地模型无需密钥" : "未配置密钥"))
                    .font(.app(12, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .frame(maxWidth: .infinity)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var promptRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("检测对话").font(.app(12, weight: .medium))
            TextField("输入用于检测的提问", text: $form.prompt)
                .textFieldStyle(.plain)
                .font(.app(12.5))
                .padding(.horizontal, 10)
                .frame(height: 36)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
            Text("默认问模型身份与数据截止日期，可自行改写。")
                .font(.app(10.5))
                .foregroundStyle(.tertiary)
        }
    }

    private var resultList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("检测结果").font(.app(12, weight: .medium))
                Spacer()
                if form.busy {
                    Text(form.progress)
                        .font(.app(10.5))
                        .foregroundStyle(.tertiary)
                    ProgressView().controlSize(.small)
                }
            }

            VStack(spacing: 0) {
                ForEach(form.results) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: item.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .font(.app(10.5))
                                .foregroundStyle(item.ok ? Theme.moss : Theme.brick)
                            Text(item.model)
                                .font(.app(11.5, design: .monospaced))
                                .lineLimit(1)
                        }
                        Text(item.text)
                            .font(.app(12))
                            .foregroundStyle(item.ok ? Color.primary : Color.secondary)
                            .lineLimit(6)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    if item.id != form.results.last?.id {
                        Divider().opacity(0.35)
                    }
                }
            }
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
        }
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: 10) {
            Button("检测所有模型") { runAll() }
                .disabled(form.busy || (provider?.models.isEmpty ?? true))
            Spacer()
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("开始") { runSingle() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(form.busy || form.model.isEmpty)
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
    }

    // MARK: - 执行

    private func runSingle() {
        guard let provider else { return }
        form.busy = true
        form.results = []
        form.progress = "正在检测 \(form.model)"
        let model = form.model
        let prompt = form.prompt
        Task { @MainActor in
            do {
                let text = try await AIService.chat(
                    provider: provider,
                    model: model,
                    system: "你是模型自检助手，请如实、简短地回答。",
                    user: prompt
                )
                form.results = [TestItem(model: model, ok: true, text: text)]
            } catch {
                form.results = [TestItem(model: model, ok: false, text: error.localizedDescription)]
            }
            form.progress = ""
            form.busy = false
        }
    }

    private func runAll() {
        guard let provider else { return }
        form.busy = true
        form.results = []
        let models = provider.models
        let prompt = form.prompt
        Task { @MainActor in
            for (index, model) in models.enumerated() {
                form.progress = "\(index + 1)/\(models.count) \(model)"
                do {
                    let text = try await AIService.chat(
                        provider: provider,
                        model: model,
                        system: "你是模型自检助手，请如实、简短地回答。",
                        user: prompt
                    )
                    form.results.append(TestItem(model: model, ok: true, text: text))
                } catch {
                    form.results.append(TestItem(model: model, ok: false, text: error.localizedDescription))
                }
            }
            form.progress = ""
            form.busy = false
        }
    }
}
