import SwiftUI

final class EditorForm: ObservableObject {
    @Published var text = ""
    @Published var busy = false
    @Published var hint: String?
}

struct AIEditorSheet: View {
    let title: String
    let subtitle: String
    let placeholder: String
    var allowsGenerate = false
    var generateHint = "根据最近收件箱生成"
    let onSave: (String) -> Void

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var form = EditorForm()

    init(title: String,
         subtitle: String,
         placeholder: String,
         initial: String,
         allowsGenerate: Bool = false,
         generateHint: String = "根据最近收件箱生成",
         onSave: @escaping (String) -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.placeholder = placeholder
        self.allowsGenerate = allowsGenerate
        self.generateHint = generateHint
        self.onSave = onSave
        _form = StateObject(wrappedValue: {
            let f = EditorForm()
            f.text = initial
            return f
        }())
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.app(14, weight: .semibold))
                    Text(subtitle)
                        .font(.app(11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button { dismiss() } label: {
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

            Divider().opacity(0.5)

            TextEditor(text: $form.text)
                .font(.app(12.5))
                .scrollContentBackground(.hidden)
                .padding(12)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
                .overlay(alignment: .topLeading) {
                    if form.text.isEmpty {
                        Text(placeholder)
                            .font(.app(12.5))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 17)
                            .padding(.vertical, 20)
                            .allowsHitTesting(false)
                    }
                }
                .padding(20)

            if let hint = form.hint {
                Text(hint)
                    .font(.app(10.5))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider().opacity(0.5)

            HStack(spacing: 10) {
                if allowsGenerate {
                    Button {
                        Task { @MainActor in
                            form.busy = true
                            form.hint = "正在生成…"
                            let text = await model.generateProfile()
                            form.text = text
                            form.hint = "已生成，可继续编辑后保存"
                            form.busy = false
                        }
                    } label: {
                        HStack(spacing: 5) {
                            if form.busy { ProgressView().controlSize(.mini) }
                            else { Image(systemName: "sparkles").font(.app(10)) }
                            Text(generateHint).font(.app(12))
                        }
                    }
                    .disabled(form.busy)
                }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    onSave(form.text)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                }
            .padding(.horizontal, 20)
            .frame(height: 56)
        }
        .frame(width: 620, height: 520)
        .background(.regularMaterial)
    }
}

// MARK: - AI 功能

struct AIFeaturesView: View {
    @EnvironmentObject private var prefs: AIPreferencesStore
    @EnvironmentObject private var model: AppModel

    @StateObject private var ui = FeaturesUI()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                personalization
                writing
                suggestionSection
                translation
                footnote
            }
            .padding(22)
        }
        .hoverScrollIndicators()
        .sheet(item: $ui.editor) { editor in
            switch editor {
            case .profile:
                AIEditorSheet(
                    title: "我的简介",
                    subtitle: "AI 从你的收件箱与自定义指令中了解到的信息。每 30 天可重新生成一次。",
                    placeholder: "例如：我在一家 SaaS 公司做产品，常与客户沟通报价与合同细节。",
                    initial: prefs.prefs.profile,
                    allowsGenerate: true
                ) { prefs.prefs.profile = $0 }
                .environmentObject(model)
            case .instructions:
                AIEditorSheet(
                    title: "自定义指令",
                    subtitle: "用于引导行为的说明、事实或偏好。这些内容会覆盖 AI 自动学到的信息。",
                    placeholder: "例如：回复客户时先给结论，再给理由；不要使用感叹号。",
                    initial: prefs.prefs.customInstructions
                ) { prefs.prefs.customInstructions = $0 }
                .environmentObject(model)
            case .samples:
                AIEditorSheet(
                    title: "写作样本",
                    subtitle: "粘贴几段你写过的邮件正文，用空行分隔。AI 会模仿这个语气。",
                    placeholder: "粘贴你的邮件正文……",
                    initial: prefs.prefs.styleSamples.joined(separator: "\n\n")
                ) { text in
                    prefs.prefs.styleSamples = text
                        .components(separatedBy: "\n\n")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                }
                .environmentObject(model)
            case .suggestions:
                AIEditorSheet(
                    title: "提问建议",
                    subtitle: "一行一条，显示在浮动提问框上方。全部删掉会回到默认四问。",
                    placeholder: "今天有哪些邮件需要我回复？",
                    initial: prefs.prefs.suggestionList.joined(separator: "\n")
                ) { text in
                    let list = text
                        .components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    prefs.prefs.askSuggestions = list.isEmpty ? nil : list
                }
                .environmentObject(model)
            }
        }
    }

    // MARK: 个性化

    private var personalization: some View {
        section("个性化") {
            toggleRow(
                icon: "person.crop.circle",
                title: "个性化",
                subtitle: "让 AI 了解你的角色、工作流与写作方式，用于摘要、草稿与分类。",
                isOn: Binding(get: { prefs.prefs.personalizationEnabled },
                              set: { prefs.prefs.personalizationEnabled = $0 })
            )
            divider
            chevronRow(
                icon: "person.text.rectangle",
                title: "我的简介",
                subtitle: prefs.prefs.profile.isEmpty
                    ? "还没有内容，点开可以一键生成"
                    : String(prefs.prefs.profile.prefix(48))
            ) { ui.editor = .profile }
            divider
            chevronRow(
                icon: "text.alignleft",
                title: "自定义指令",
                subtitle: prefs.prefs.customInstructions.isEmpty
                    ? "添加说明或偏好，覆盖自动学习的内容"
                    : String(prefs.prefs.customInstructions.prefix(48))
            ) { ui.editor = .instructions }
        }
    }

    // MARK: 写作与回复

    private var writing: some View {
        section("写作与回复") {
            pickerRow(
                icon: "face.smiling",
                title: "语气",
                selection: Binding(get: { prefs.prefs.tone },
                                   set: { prefs.prefs.tone = $0 }),
                options: AIPreferences.Tone.allCases
            )
            divider
            pickerRow(
                icon: "text.line.first.and.arrowtriangle.forward",
                title: "文本长度",
                selection: Binding(get: { prefs.prefs.length },
                                   set: { prefs.prefs.length = $0 }),
                options: AIPreferences.Length.allCases
            )
            divider
            toggleRow(
                icon: "wand.and.stars",
                title: "学习我的写作风格",
                subtitle: "分析最近「已发送」里的邮件，让草稿更接近你的语气。",
                isOn: Binding(get: { prefs.prefs.learnWritingStyle },
                              set: { prefs.prefs.learnWritingStyle = $0 })
            )
            divider
            chevronRow(
                icon: "doc.text",
                title: "写作样本",
                subtitle: prefs.prefs.styleSamples.isEmpty
                    ? "手动粘贴几段邮件正文"
                    : "已添加 \(prefs.prefs.styleSamples.count) 段样本"
            ) { ui.editor = .samples }
            divider
            toggleRow(
                icon: "bolt.badge.clock",
                title: "快速 AI 回复",
                subtitle: "在阅读窗格显示「感兴趣」「谢谢」等一键生成回复的按钮。",
                isOn: Binding(get: { prefs.prefs.quickRepliesEnabled },
                              set: { prefs.prefs.quickRepliesEnabled = $0 })
            )
        }
    }

    // MARK: 提问建议

    private var suggestionSection: some View {
        section("提问建议") {
            chevronRow(
                icon: "text.bubble",
                title: "建议问题",
                subtitle: "\(prefs.prefs.suggestionList.count) 条，显示在浮动提问框上方"
            ) { ui.editor = .suggestions }
            divider
            Button {
                prefs.prefs.askSuggestions = nil
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.app(12))
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    Text("恢复默认四问")
                        .font(.app(12.5))
                    Spacer()
                }
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: 翻译

    private var translation: some View {
        section("翻译") {
            toggleRow(
                icon: "character.bubble",
                title: "翻译",
                subtitle: "在阅读窗格显示翻译按钮，把邮件译成指定语言。",
                isOn: Binding(get: { prefs.prefs.translateEnabled },
                              set: { prefs.prefs.translateEnabled = $0 })
            )
            divider
            HStack {
                Label("目标语言", systemImage: "globe")
                    .font(.app(12.5))
                Spacer()
                LanguagePickerButton(selection: Binding(
                    get: { prefs.prefs.translateTarget },
                    set: { prefs.prefs.translateTarget = $0 }
                ))
            }
            .padding(.vertical, 8)

            divider
            HStack {
                Label("翻译模型", systemImage: "cpu")
                    .font(.app(12.5))
                Spacer()
                translationModelMenu
            }
            .padding(.vertical, 8)

            Text(translationHint)
                .font(.app(10.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 8)
        }
    }

    /// 翻译可以单独指一个模型。
    /// 翻译对语义完整度最敏感——脱敏把「张三」换成占位符，整句译文就断了，
    /// 所以宁可换个模型，也别让译文变成一串占位符。
    private var translationModelMenu: some View {
        Menu {
            Button {
                prefs.prefs.translationProviderID = nil
                prefs.prefs.translationModel = nil
            } label: {
                if model.translationRoute == nil {
                    Label("跟随主模型", systemImage: "checkmark")
                } else {
                    Text("跟随主模型")
                }
            }

            let usable = model.ai.providers.filter { $0.enabled && !$0.models.isEmpty }
            if !usable.isEmpty {
                Divider()
                ForEach(usable) { provider in
                    Section(provider.name) {
                        ForEach(provider.models, id: \.self) { m in
                            let picked = prefs.prefs.translationProviderID == provider.id
                                && (prefs.prefs.translationModel ?? "") == m
                            Button {
                                prefs.prefs.translationProviderID = provider.id
                                prefs.prefs.translationModel = m
                            } label: {
                                if picked {
                                    Label(provider.displayName(for: m), systemImage: "checkmark")
                                } else {
                                    Text(provider.displayName(for: m))
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(model.translationRoute == nil ? "跟随主模型" : model.translationModelLabel)
                    .font(.app(12))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.app(8.5))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var translationHint: String {
        guard let route = model.translationRoute else {
            return "未指定时与摘要、草拟回复共用主模型。"
        }
        let trusted = route.provider.isTrusted(route.model)
        if trusted {
            return "翻译固定使用 \(route.provider.name) · \(route.provider.displayName(for: route.model))，内容原样发送，不脱敏。"
        }
        return "翻译固定使用 \(route.provider.name) · \(route.provider.displayName(for: route.model))。该模型不可信，发送前仍会脱敏——译文可能被占位符打断，建议换成可信或本地模型。"
    }

    private var footnote: some View {
        Text("这些偏好只用于拼装本机的提示词，不会单独上传。")
            .font(.app(10.5))
            .foregroundStyle(.tertiary)
            .padding(.top, 2)
    }

    // MARK: 组件

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.app(11, weight: .medium))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .kerning(0.5)
                .padding(.bottom, 7)
            VStack(spacing: 0) { content() }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var divider: some View {
        Divider().opacity(0.35)
    }

    private func toggleRow(icon: String, title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.app(12))
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.app(12.5, weight: .medium))
                Text(subtitle)
                    .font(.app(11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.mini)
        }
        .padding(.vertical, 9)
    }

    private func chevronRow(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.app(12))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.app(12.5, weight: .medium))
                    Text(subtitle)
                        .font(.app(11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.app(9))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 3)
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func pickerRow<T: Hashable & Identifiable & RawRepresentable>(
        icon: String,
        title: String,
        selection: Binding<T>,
        options: [T]
    ) -> some View where T.RawValue == String {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.app(12))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(title).font(.app(12.5))
            Spacer()
            Picker("", selection: selection) {
                ForEach(options) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 110)
        }
        .padding(.vertical, 6)
    }
}

final class FeaturesUI: ObservableObject {
    enum Editor: String, Identifiable {
        case profile, instructions, samples, suggestions
        var id: String { rawValue }
    }

    @Published var editor: Editor?
}
