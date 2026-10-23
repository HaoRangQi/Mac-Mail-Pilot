import SwiftUI

final class AddModelForm: ObservableObject {
    @Published var modelID = ""
    @Published var name = ""
    @Published var group = ""
    @Published var contextWindow = ""
    @Published var maxOutput = ""
    @Published var showAdvanced = false
    @Published var error: String?
}

struct AddModelView: View {
    let providerID: String
    var onClose: () -> Void

    @EnvironmentObject private var ai: AISettingsStore
    @StateObject private var form = AddModelForm()

    private let contextPresets: [(String, Int)] = [
        ("128K", 128_000), ("200K", 200_000), ("256K", 256_000),
        ("400K", 400_000), ("512K", 512_000), ("1M", 1_000_000),
    ]

    private let outputPresets: [(String, Int)] = [
        ("16K", 16_384), ("32K", 32_768), ("64K", 65_536),
        ("128K", 131_072), ("256K", 262_144),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    field("模型 ID", required: true, placeholder: "例如 gpt-5.5", text: $form.modelID, mono: true)
                    field("模型名称", required: false, placeholder: "例如 GPT-5.5", text: $form.name)
                    field("分组名称", required: false, placeholder: "例如 ChatGPT", text: $form.group)

                    advancedSection

                    if let error = form.error {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                    }
                }
                .padding(20)
            }
            .scrollIndicators(.visible)

            Divider().opacity(0.5)
            footer
        }
        .frame(width: 560, height: 520)
        .background(.regularMaterial)
    }

    // MARK: - 头部 / 底部

    private var header: some View {
        HStack {
            Text("添加模型")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Button { onClose() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .frame(height: 50)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("模型 ID 由服务商定义，可从其文档或 /models 接口获取")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer()
            Button("取消") { onClose() }
                .keyboardShortcut(.cancelAction)
            Button("添加模型") { add() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(form.modelID.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 20)
        .frame(height: 58)
    }

    // MARK: - 字段

    private func field(_ title: String, required: Bool, placeholder: String, text: Binding<String>, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 2) {
                Text(title).font(.system(size: 12, weight: .medium))
                if required {
                    Text("*").font(.system(size: 12)).foregroundStyle(.red)
                }
            }
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, design: mono ? .monospaced : .default))
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
        }
    }

    // MARK: - 更多设置

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { form.showAdvanced.toggle() }
            } label: {
                HStack {
                    Text("更多设置").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Image(systemName: form.showAdvanced ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if form.showAdvanced {
                VStack(alignment: .leading, spacing: 14) {
                    tokenField("上下文窗口", text: $form.contextWindow, presets: contextPresets)
                    tokenField("最大输出 Token", text: $form.maxOutput, presets: outputPresets)
                }
                .padding(.top, 12)
            }
        }
        .padding(.top, 4)
    }

    private func tokenField(_ title: String, text: Binding<String>, presets: [(String, Int)]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 11.5, weight: .medium))
            HStack(spacing: 6) {
                ForEach(presets, id: \.0) { preset in
                    Button {
                        text.wrappedValue = String(preset.1)
                    } label: {
                        Text(preset.0)
                            .font(.system(size: 10.5))
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background(Color.primary.opacity(0.05), in: Capsule())
                            .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            TextField("例如 128000", text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
        }
    }

    // MARK: - 提交

    private func add() {
        let id = form.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            form.error = "模型 ID 不能为空"
            return
        }
        let name = form.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let group = form.group.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = Int(form.contextWindow.trimmingCharacters(in: .whitespaces))
        let output = Int(form.maxOutput.trimmingCharacters(in: .whitespaces))

        ai.update(id: providerID) { provider in
            if !provider.models.contains(id) {
                provider.models.append(id)
            }
            var meta = provider.modelMeta ?? [:]
            meta[id] = ModelMeta(
                displayName: name,
                group: group,
                purpose: .chat,
                contextWindow: context,
                maxOutput: output
            )
            provider.modelMeta = meta

            var catalog = provider.availableModels ?? []
            if !catalog.contains(id) {
                catalog.append(id)
                provider.availableModels = catalog
            }
            if provider.selectedModel.isEmpty {
                provider.selectedModel = id
            }
        }
        onClose()
    }
}
