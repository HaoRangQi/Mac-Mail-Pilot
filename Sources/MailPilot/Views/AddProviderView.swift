import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class AddProviderForm: ObservableObject {
    @Published var name = ""
    @Published var apiKey = ""
    @Published var baseURL = ""
    @Published var kind: ProviderKind = .ollama
    @Published var model = ""
    @Published var reveal = false
    @Published var avatarImage: Data?
    @Published var avatarSeed = 0
    @Published var showAdvanced = false
}

struct AddProviderView: View {
    @EnvironmentObject private var ai: AISettingsStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var form = AddProviderForm()

    var onAdded: (String) -> Void

    private var keyPlaceholder: String {
        form.kind == .ollama ? "本地模型可留空" : "输入 API 密钥"
    }

    private var preview: AIProvider {        AIProvider(
            id: "preview-\(form.kind.rawValue)",
            name: form.name.isEmpty ? "P" : form.name,
            kind: form.kind,
            baseURL: form.baseURL,
            avatarImage: form.avatarImage,
            avatarSeed: form.avatarSeed
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    avatarBlock
                    nameField
                    keyField
                    endpointBlock
                    advancedBlock
                }
                .padding(22)
            }
            .scrollIndicators(.visible)

            Divider().opacity(0.5)
            footer
        }
        .frame(width: 560, height: 600)
        .background(.regularMaterial)
        .onAppear {
            if form.baseURL.isEmpty { form.baseURL = form.kind.defaultBase }
        }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack {
            Text("添加自定义提供商")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .frame(height: 48)
    }

    // MARK: - 头像

    private var avatarBlock: some View {
        VStack(spacing: 12) {
            ProviderAvatar(provider: preview, size: 84)

            HStack(spacing: 8) {
                actionButton("图片上传", icon: "photo") { pickImage() }
                actionButton("换颜色", icon: "paintpalette") {
                    form.avatarSeed = (form.avatarSeed + 1) % AvatarPalette.colors.count
                    form.avatarImage = nil
                }
                actionButton("重置头像", icon: "arrow.counterclockwise") {
                    form.avatarImage = nil
                    form.avatarSeed = 0
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private func actionButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10.5))
                Text(title).font(.system(size: 11.5))
            }
            .padding(.horizontal, 11)
            .frame(height: 28)
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
    }

    // MARK: - 表单

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 2) {
                Text("提供商名称").font(.system(size: 12, weight: .medium))
                Text("*").font(.system(size: 12)).foregroundStyle(.red)
            }
            TextField("例如 OpenAI", text: $form.name)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
        }
    }

    private var keyField: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("API 密钥").font(.system(size: 12, weight: .medium))
            HStack(spacing: 6) {
                Group {
                    if form.reveal {
                        TextField(keyPlaceholder, text: $form.apiKey)
                    } else {
                        SecureField(keyPlaceholder, text: $form.apiKey)
                    }
                }
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, design: .monospaced))
                .padding(.leading, 10)

                Button {
                    form.reveal.toggle()
                } label: {
                    Image(systemName: form.reveal ? "eye.slash" : "eye")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 3)
            }
            .frame(height: 32)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
        }
    }

    private var endpointBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("端点设置").font(.system(size: 12, weight: .medium))

            Picker("", selection: $form.kind) {
                ForEach(ProviderKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: form.kind) { _, newValue in
                form.baseURL = newValue.defaultBase
            }

            HStack(spacing: 5) {
                Image(systemName: form.kind.isLocal ? "lock.shield.fill" : "lock.shield")
                    .font(.system(size: 10))
                Text(form.kind.isLocal
                     ? "当前为本地模型，邮件内容不出本机"
                     : "推荐使用本地模型：邮件内容不会离开这台电脑")
                    .font(.system(size: 10.5))
            }
            .foregroundStyle(form.kind.isLocal ? Theme.moss : Color.secondary)

            TextField("Base URL：https://example.com", text: $form.baseURL)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, design: .monospaced))
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))

            Text("实际请求：\(AIService.previewRequestURL(base: form.baseURL, kind: form.kind))")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    private var advancedBlock: some View {
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
                VStack(alignment: .leading, spacing: 7) {
                    Text("默认模型 ID（可留空，稍后同步）")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    TextField("例如 gpt-4o-mini", text: $form.model)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5, design: .monospaced))
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                }
                .padding(.top, 10)
            }
        }
        .padding(.top, 2)
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: 10) {
            Text("密钥仅保存在本机")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            Spacer()
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("添加") { add() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(form.name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
    }

    // MARK: - 动作

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) {
            form.avatarImage = data
        }
    }

    private func add() {
        var provider = AIProvider(
            name: form.name.trimmingCharacters(in: .whitespaces),
            kind: form.kind,
            baseURL: form.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        provider.apiKey = ""
        let keyValue = form.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !keyValue.isEmpty {
            provider.keys = [APIKey(label: "默认", value: keyValue)]
        }
        provider.avatarImage = form.avatarImage
        provider.avatarSeed = form.avatarSeed

        let model = form.model.trimmingCharacters(in: .whitespaces)
        if !model.isEmpty {
            provider.models = [model]
            provider.selectedModel = model
        }

        ai.providers.append(provider)
        onAdded(provider.id)
        dismiss()
    }
}
