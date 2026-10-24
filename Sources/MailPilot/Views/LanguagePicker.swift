import SwiftUI

struct Language: Identifiable, Hashable {
    let zh: String
    let en: String
    var id: String { zh }

    static let all: [Language] = [
        Language(zh: "中文", en: "Chinese"),
        Language(zh: "繁体中文", en: "Traditional Chinese"),
        Language(zh: "英文", en: "English"),
        Language(zh: "日文", en: "Japanese"),
        Language(zh: "韩文", en: "Korean"),
        Language(zh: "法文", en: "French"),
        Language(zh: "德文", en: "German"),
        Language(zh: "西班牙文", en: "Spanish"),
        Language(zh: "葡萄牙文", en: "Portuguese"),
        Language(zh: "俄文", en: "Russian"),
        Language(zh: "意大利文", en: "Italian"),
        Language(zh: "荷兰文", en: "Dutch"),
        Language(zh: "波兰文", en: "Polish"),
        Language(zh: "土耳其文", en: "Turkish"),
        Language(zh: "阿拉伯文", en: "Arabic"),
        Language(zh: "希伯来文", en: "Hebrew"),
        Language(zh: "印地文", en: "Hindi"),
        Language(zh: "泰文", en: "Thai"),
        Language(zh: "越南文", en: "Vietnamese"),
        Language(zh: "印尼文", en: "Indonesian"),
        Language(zh: "马来文", en: "Malay"),
        Language(zh: "菲律宾文", en: "Filipino"),
        Language(zh: "乌克兰文", en: "Ukrainian"),
        Language(zh: "捷克文", en: "Czech"),
        Language(zh: "瑞典文", en: "Swedish"),
        Language(zh: "丹麦文", en: "Danish"),
        Language(zh: "挪威文", en: "Norwegian"),
        Language(zh: "芬兰文", en: "Finnish"),
        Language(zh: "希腊文", en: "Greek"),
        Language(zh: "匈牙利文", en: "Hungarian"),
        Language(zh: "罗马尼亚文", en: "Romanian"),
        Language(zh: "波斯文", en: "Persian"),
        Language(zh: "孟加拉文", en: "Bengali"),
        Language(zh: "乌尔都文", en: "Urdu"),
        Language(zh: "斯瓦希里文", en: "Swahili"),
    ]

    static func find(_ name: String) -> Language? {
        all.first { $0.zh == name }
    }
}

final class LanguageUI: ObservableObject {
    @Published var show = false
    @Published var query = ""
}

struct LanguagePickerButton: View {
    @Binding var selection: String

    @StateObject private var ui = LanguageUI()

    private var filtered: [Language] {
        let q = ui.query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return Language.all }
        return Language.all.filter {
            $0.zh.localizedCaseInsensitiveContains(q) || $0.en.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        Button {
            ui.query = ""
            ui.show.toggle()
        } label: {
            HStack(spacing: 5) {
                Text(selection.isEmpty ? "选择语言" : selection)
                    .font(.system(size: 12.5))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $ui.show, arrowEdge: .bottom) {
            panel
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("搜索语言", text: $ui.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                if !ui.query.isEmpty {
                    Button { ui.query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 8)

            Divider().opacity(0.4)

            ScrollView {
                LazyVStack(spacing: 0) {
                    if filtered.isEmpty {
                        Text("没有匹配的语言")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 24)
                    }
                    ForEach(filtered) { language in
                        row(language)
                    }
                }
                .padding(.vertical, 4)
            }
            .hoverScrollIndicators()
        }
        .frame(width: 240, height: 320)
    }

    private func row(_ language: Language) -> some View {
        let selected = selection == language.zh
        return Button {
            selection = language.zh
            ui.show = false
        } label: {
            HStack(spacing: 8) {
                Text(language.zh)
                    .font(.system(size: 12.5))
                    .foregroundStyle(selected ? Theme.accent : Color.primary)
                Text(language.en)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(selected ? Theme.accent.opacity(0.08) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
