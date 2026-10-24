import SwiftUI

/// 隐私与数据设置页。
///
/// 这里放两块可调项：
/// 1. 脱敏规则开关（Redactor 的每条规则）
/// 2. 不可信模型上各动作的处置（TrustPolicy 的策略）
///
/// 页面本身不写任何判断逻辑，只改 `AIPreferences` 里的值；
/// 真正的决策仍然只发生在 `TrustPolicy.decide()` 一处。
struct PrivacySettingsView: View {
    @EnvironmentObject private var ai: AISettingsStore
    @EnvironmentObject private var model: AppModel
    @StateObject private var form = PrivacyForm()

    private var prefs: AIPreferences { model.prefs.prefs }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                overview
                globalSwitch
                exemptionSection
                policySection
                redactionSection
                customRulesSection
                keywordsSection
            }
            .padding(22)
        }
        .hoverScrollIndicators()
        .sheet(item: $form.editingRule) { rule in
            AddRedactionRuleView(existing: rule)
                .environmentObject(model)
        }
        .sheet(isPresented: $form.addingRule) {
            AddRedactionRuleView()
                .environmentObject(model)
        }
    }

    // MARK: - 概览

    private var overview: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("MailPilot 的 AI 能力需要把邮件内容发给模型服务商。本地模型不出本机；第三方模型则会离开这台电脑。")
                .font(.app(12))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 5) {
                ForEach(ai.providers.filter { $0.enabled }) { provider in
                    HStack(spacing: 6) {
                        Image(systemName: provider.kind.isLocal
                              ? "lock.shield.fill"
                              : (provider.isTrustedProvider ? "checkmark.shield.fill" : "exclamationmark.shield.fill"))
                            .font(.app(10))
                            .foregroundStyle(provider.kind.isLocal || provider.isTrustedProvider
                                             ? Theme.moss
                                             : Theme.gold)
                            .frame(width: 14)

                        Text(provider.name)
                            .font(.app(11.5))

                        Text(provider.kind.isLocal
                             ? "本地 · 不出本机"
                             : (provider.isTrustedProvider ? "可信 · 原样发送" : "不可信 · 按下方规则管控"))
                            .font(.app(11))
                            .foregroundStyle(.secondary)

                        Spacer()
                    }
                }
            }
            .padding(11)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
        }
    }

    // MARK: - 总开关

    private var globalSwitch: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("只要用不可信模型，一律先问我", isOn: binding(\.alwaysConfirmUntrusted))
                .font(.app(12, weight: .medium))

            Text("开启后忽略下面每个动作的单独设置，任何内容发往第三方前都会弹确认框。")
                .font(.app(11))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - 单封豁免

    /// 阅读页那个「本封不脱敏」开关的总览与清理入口。
    ///
    /// 这层豁免是按邮件走的，最容易被忘记——所以必须有一个地方能一眼看到全部，
    /// 并且能一次清掉。
    private var exemptionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("单封邮件豁免")
                .font(.app(12, weight: .medium))

            Text("在阅读页把某封邮件标记为「不敏感」后，它在不可信模型上会原样发送、不脱敏也不确认。这里列出当前所有被标记的邮件。")
                .font(.app(11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Text(model.exemption.ids.isEmpty
                     ? "还没有标记任何邮件"
                     : "已标记 \(model.exemption.ids.count) 封")
                    .font(.app(12))
                    .foregroundStyle(model.exemption.ids.isEmpty ? .secondary : .primary)

                Spacer()

                Button {
                    model.exemption.clear()
                } label: {
                    Text("全部清除")
                        .font(.app(11.5))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.exemption.ids.isEmpty)
            }
            .padding(11)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
        }
    }

    // MARK: - 动作策略

    private var policySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("不可信模型上的动作")
                .font(.app(12, weight: .medium))

            Text("只对「不可信」模型生效。可信模型与本地模型一律直接执行。")
                .font(.app(11))
                .foregroundStyle(.tertiary)

            VStack(spacing: 0) {
                ForEach(AIAction.allCasesForSettings, id: \.self) { action in
                    HStack(spacing: 10) {
                        Text(action.label)
                            .font(.app(12))
                            .frame(width: 76, alignment: .leading)

                        Picker("", selection: policyBinding(for: action)) {
                            ForEach(UntrustedPolicy.allCases) { policy in
                                Text(policy.rawValue).tag(policy)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(width: 118, alignment: .leading)

                        Text(prefs.untrustedPolicy(for: action).hint)
                            .font(.app(11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer(minLength: 0)
                    }
                    .frame(height: 34)

                    if action != AIAction.allCasesForSettings.last {
                        Divider().opacity(0.35)
                    }
                }
            }
            .padding(.horizontal, 11)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
        }
    }

    // MARK: - 脱敏规则

    private var redactionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("脱敏规则")
                .font(.app(12, weight: .medium))

            Text("命中后替换为 ⟨类型序号⟩，模型返回结果再在本地还原。规则按长优先匹配，避免身份证被银行卡规则截断。")
                .font(.app(11))
                .foregroundStyle(.tertiary)

            VStack(spacing: 0) {
                ForEach(Redactor.ruleInfos) { rule in
                    HStack(spacing: 10) {
                        Toggle("", isOn: ruleBinding(name: rule.name))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .controlSize(.mini)

                        Text(rule.name)
                            .font(.app(12))
                            .frame(width: 62, alignment: .leading)

                        Text(rule.hint)
                            .font(.app(11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Spacer(minLength: 0)

                        Text(rule.pattern)
                            .font(.app(9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 220, alignment: .trailing)
                            .help(rule.pattern)
                    }
                    .frame(height: 32)

                    if rule.name != Redactor.ruleInfos.last?.name {
                        Divider().opacity(0.35)
                    }
                }
            }
            .padding(.horizontal, 11)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))

            Text("已知局限：脱敏防不住语义信息（「张三下周三签合同」这种），也拦不住模型服务商自己记录的日志。要更高隔离，请在「模型服务」里把相关供应商标为不可信，或改用本地模型。")
                .font(.app(11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 自定义正则规则

    private var customRulesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("自定义正则规则")
                    .font(.app(12, weight: .medium))
                Spacer()
                Button {
                    form.addingRule = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus").font(.app(10))
                        Text("添加").font(.app(11.5))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Text("用于内置规则覆盖不到的模式，如公司内部的项目代号、工单号。正则写错不会报错、只是不生效，所以添加时可以先用测试文本验证。")
                .font(.app(11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if prefs.customRedactionRules.isEmpty {
                Text("还没有自定义规则")
                    .font(.app(11.5))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(prefs.customRedactionRules.enumerated()), id: \.element.id) { index, rule in
                        HStack(spacing: 9) {
                            Toggle("", isOn: Binding(
                                get: { rule.enabled },
                                set: { model.prefs.prefs.customRedactionRules[index].enabled = $0 }
                            ))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .controlSize(.mini)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(rule.name)
                                    .font(.app(12))
                                    .foregroundStyle(rule.enabled ? Color.primary : Color.secondary)
                                Text(rule.pattern)
                                    .font(.app(9.5, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            Spacer(minLength: 0)

                            Button {
                                form.editingRule = rule
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.app(10.5))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("编辑")

                            Button {
                                model.prefs.prefs.customRedactionRules.removeAll { $0.id == rule.id }
                            } label: {
                                Image(systemName: "trash")
                                    .font(.app(10.5))
                                    .foregroundStyle(Theme.brick.opacity(0.85))
                            }
                            .buttonStyle(.plain)
                            .help("删除")
                        }
                        .frame(height: 36)

                        if index != prefs.customRedactionRules.count - 1 {
                            Divider().opacity(0.35)
                        }
                    }
                }
                .padding(.horizontal, 11)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
            }
        }
    }

    // MARK: - 关键字脱敏

    private var keywordsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("关键字脱敏")
                .font(.app(12, weight: .medium))

            Text("一行一个。命中的词整体替换成 ⟨关键字N⟩，不走正则，最可靠。适合公司名、项目代号、客户名这类固定说法。")
                .font(.app(11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: keywordsBinding)
                .font(.app(12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(height: 108)
                .padding(8)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))

            Text("当前 \(prefs.redactionKeywords.count) 个关键字")
                .font(.app(11))
                .foregroundStyle(.tertiary)
        }
    }

    /// 一行一个关键字的编辑绑定
    private var keywordsBinding: Binding<String> {
        Binding(
            get: { prefs.redactionKeywords.joined(separator: "\n") },
            set: { newValue in
                model.prefs.prefs.redactionKeywords = newValue
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
        )
    }

    // MARK: - 绑定

    private func binding(_ keyPath: WritableKeyPath<AIPreferences, Bool>) -> Binding<Bool> {        Binding(
            get: { model.prefs.prefs[keyPath: keyPath] },
            set: { model.prefs.prefs[keyPath: keyPath] = $0 }
        )
    }

    private func policyBinding(for action: AIAction) -> Binding<UntrustedPolicy> {
        Binding(
            get: { model.prefs.prefs.untrustedPolicy(for: action) },
            set: { model.prefs.prefs.untrustedPolicy[action.rawValue] = $0 }
        )
    }

    private func ruleBinding(name: String) -> Binding<Bool> {
        Binding(
            get: { model.prefs.prefs.redactionRules[name] ?? true },
            set: { model.prefs.prefs.redactionRules[name] = $0 }
        )
    }
}

private extension AIAction {
    /// 设置页里要展示的动作
    static let allCasesForSettings: [AIAction] = [.summarize, .reply, .classify, .translate]
}

/// 隐私设置页的表单状态（@State 在 CLT 下编不过，沿用 ObservableObject）
final class PrivacyForm: ObservableObject {
    @Published var addingRule = false
    @Published var editingRule: CustomRedactionRule?
}
