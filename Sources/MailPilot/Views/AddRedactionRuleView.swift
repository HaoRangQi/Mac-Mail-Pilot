import SwiftUI

final class RuleForm: ObservableObject {
    @Published var name = ""
    @Published var pattern = ""
    @Published var testText = "把项目代号 XQ-2049 的报价发给 lisiyuan@huaxin-tech.com。"
}

/// 添加 / 编辑自定义脱敏规则。
///
/// 带实时测试：正则写错不会报错，只是不生效，所以必须当场看到命中结果。
struct AddRedactionRuleView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var form = RuleForm()

    /// 传入则为编辑，nil 为新增
    let existing: CustomRedactionRule?

    init(existing: CustomRedactionRule? = nil) {
        self.existing = existing
    }

    private var isValid: Bool {
        !form.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !form.pattern.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(existing == nil ? "添加脱敏规则" : "编辑脱敏规则")
                .font(.app(14, weight: .semibold))

            field("名称", text: $form.name, placeholder: "如：项目代号", monospaced: false)

            VStack(alignment: .leading, spacing: 5) {
                Text("正则")
                    .font(.app(12, weight: .medium))
                TextField("如：XQ-[0-9]{4}", text: $form.pattern)
                    .textFieldStyle(.plain)
                    .font(.app(12, design: .monospaced))
                    .padding(.horizontal, 9)
                    .frame(height: 30)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("测试文本")
                    .font(.app(12, weight: .medium))
                TextEditor(text: $form.testText)
                    .font(.app(12))
                    .scrollContentBackground(.hidden)
                    .frame(height: 68)
                    .padding(8)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("命中效果")
                    .font(.app(12, weight: .medium))

                Text(preview)
                    .font(.app(12, design: .monospaced))
                    .foregroundStyle(hitCount > 0 ? Theme.moss : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(9)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))

                Text(hitCount > 0 ? "命中 \(hitCount) 处" : "没有命中——正则可能有误")
                    .font(.app(11))
                    .foregroundStyle(hitCount > 0 ? Theme.moss : Theme.gold)
            }

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 480)
        .background(.regularMaterial)
        .onAppear {
            if let existing {
                form.name = existing.name
                form.pattern = existing.pattern
            }
        }
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String, monospaced: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.app(12, weight: .medium))
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.app(12, design: monospaced ? .monospaced : nil))
                .padding(.horizontal, 9)
                .frame(height: 30)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
        }
    }

    /// 用当前填的正则跑一次脱敏，让用户立刻看到效果
    private var preview: String {
        guard !form.pattern.isEmpty else { return "（先填正则）" }
        let rule = CustomRedactionRule(name: form.name.isEmpty ? "规则" : form.name,
                                       pattern: form.pattern,
                                       enabled: true)
        let result = Redactor.redact(form.testText, customRules: [rule])
        return result.text
    }

    private var hitCount: Int {
        guard !form.pattern.isEmpty else { return 0 }
        let rule = CustomRedactionRule(name: form.name.isEmpty ? "规则" : form.name,
                                       pattern: form.pattern,
                                       enabled: true)
        return Redactor.redact(form.testText, customRules: [rule]).mappings.count
    }

    private func save() {
        let name = form.name.trimmingCharacters(in: .whitespaces)
        let pattern = form.pattern.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !pattern.isEmpty else { return }

        if var existing {
            existing.name = name
            existing.pattern = pattern
            if let index = model.prefs.prefs.customRedactionRules.firstIndex(where: { $0.id == existing.id }) {
                model.prefs.prefs.customRedactionRules[index] = existing
            }
        } else {
            model.prefs.prefs.customRedactionRules.append(
                CustomRedactionRule(name: name, pattern: pattern)
            )
        }
        model.showToast("已保存规则「\(name)」")
        dismiss()
    }
}
