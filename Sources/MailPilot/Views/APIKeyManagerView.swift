import AppKit
import SwiftUI

final class KeyManagerForm: ObservableObject {
    @Published var editingID: String?
    @Published var editLabel = ""
    @Published var editValue = ""
    @Published var revealed: Set<String> = []
    @Published var showAdd = false
    @Published var newLabel = ""
    @Published var newValue = ""
    @Published var hint: String?
}

struct APIKeyManagerView: View {
    let providerID: String

    @EnvironmentObject private var ai: AISettingsStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var form = KeyManagerForm()

    private var provider: AIProvider? {
        ai.providers.first { $0.id == providerID }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let provider {
                        keyList(provider)
                        if form.showAdd {
                            addRow
                        }
                        Button {
                            withAnimation(.easeInOut(duration: 0.12)) {
                                form.showAdd = true
                                form.hint = nil
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "plus")
                                Text("添加 API 密钥")
                            }
                            .font(.system(size: 12))
                            .frame(maxWidth: .infinity)
                            .frame(height: 32)
                        }
                        .buttonStyle(.plain)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    } else {
                        Text("服务商不存在")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    if let hint = form.hint {
                        Text(hint)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }

                    Text("多条密钥会按顺序尝试，遇到 401/403/429 自动换下一条。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
                .padding(20)
            }
            .scrollIndicators(.hidden)

            Divider().opacity(0.5)

            HStack {
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    }
            .padding(.horizontal, 20)
            .frame(height: 54)
        }
        .frame(width: 620, height: 520)
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("API 密钥管理")
                    .font(.system(size: 14, weight: .semibold))
                Text("管理当前服务商的多个 API Key")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
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
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    // MARK: - 列表

    private func keyList(_ provider: AIProvider) -> some View {
        VStack(spacing: 0) {
            if provider.allKeys.isEmpty {
                Text("还没有密钥")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 14)
            }

            ForEach(provider.allKeys) { key in
                keyRow(provider, key)
                if key.id != provider.allKeys.last?.id {
                    Divider().opacity(0.35)
                }
            }
        }
        .padding(.horizontal, 12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func keyRow(_ provider: AIProvider, _ key: APIKey) -> some View {
        if form.editingID == key.id {
            HStack(spacing: 8) {
                TextField("标签", text: $form.editLabel)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 8)
                    .frame(width: 96, height: 28)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))

                TextField("API 密钥", text: $form.editValue)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))

                iconButton("checkmark", color: .accentColor) {
                    ai.updateKey(providerID: provider.id, keyID: key.id, label: form.editLabel, value: form.editValue)
                    form.editingID = nil
                }
                iconButton("xmark") { form.editingID = nil }
            }
            .padding(.vertical, 9)
        } else {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(form.revealed.contains(key.id) ? key.value : key.masked)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                    if !key.label.isEmpty {
                        Text(key.label)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 6)

                iconButton("doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(key.value, forType: .string)
                    form.hint = "已复制到剪贴板"
                }
                iconButton("pencil") {
                    form.editingID = key.id
                    form.editLabel = key.label
                    form.editValue = key.value
                }
                iconButton("trash") {
                    ai.deleteKey(providerID: provider.id, keyID: key.id)
                }
                iconButton(form.revealed.contains(key.id) ? "eye.slash" : "eye") {
                    if form.revealed.contains(key.id) { form.revealed.remove(key.id) }
                    else { form.revealed.insert(key.id) }
                }

                Toggle("", isOn: Binding(
                    get: { key.enabled },
                    set: { ai.toggleKey(providerID: provider.id, keyID: key.id, enabled: $0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.mini)
            }
            .padding(.vertical, 9)
        }
    }

    private func iconButton(_ system: String, color: Color = .secondary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 11))
                .foregroundStyle(color)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 新增

    private var addRow: some View {
        HStack(spacing: 8) {
            TextField("标签", text: $form.newLabel)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 9)
                .frame(width: 96, height: 32)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.accent.opacity(0.6), lineWidth: 1))

            TextField("输入 API 密钥", text: $form.newValue)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 9)
                .frame(height: 32)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.accent.opacity(0.6), lineWidth: 1))

            iconButton("checkmark", color: .accentColor) {
                guard !form.newValue.trimmingCharacters(in: .whitespaces).isEmpty else {
                    form.hint = "密钥不能为空"
                    return
                }
                ai.addKey(providerID: providerID, label: form.newLabel, value: form.newValue)
                form.newLabel = ""
                form.newValue = ""
                form.showAdd = false
                form.hint = "已添加"
            }
            iconButton("xmark") {
                form.newLabel = ""
                form.newValue = ""
                form.showAdd = false
            }
        }
    }
}
