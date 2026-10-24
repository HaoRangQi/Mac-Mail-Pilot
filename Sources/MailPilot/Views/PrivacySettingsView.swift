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

    private var prefs: AIPreferences { model.prefs.prefs }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                overview
                globalSwitch
                policySection
                redactionSection
            }
            .padding(22)
        }
        .hoverScrollIndicators()
    }

    // MARK: - 概览

    private var overview: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("MailPilot 的 AI 能力需要把邮件内容发给模型服务商。本地模型不出本机；第三方模型则会离开这台电脑。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 5) {
                ForEach(ai.providers.filter { $0.enabled }) { provider in
                    HStack(spacing: 6) {
                        Image(systemName: provider.kind.isLocal
                              ? "lock.shield.fill"
                              : (provider.isTrustedProvider ? "checkmark.shield.fill" : "exclamationmark.shield.fill"))
                            .font(.system(size: 10))
                            .foregroundStyle(provider.kind.isLocal || provider.isTrustedProvider
                                             ? Theme.moss
                                             : Theme.gold)
                            .frame(width: 14)

                        Text(provider.name)
                            .font(.system(size: 11.5))

                        Text(provider.kind.isLocal
                             ? "本地 · 不出本机"
                             : (provider.isTrustedProvider ? "可信 · 原样发送" : "不可信 · 按下方规则管控"))
                            .font(.system(size: 11))
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
                .font(.system(size: 12, weight: .medium))

            Text("开启后忽略下面每个动作的单独设置，任何内容发往第三方前都会弹确认框。")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - 动作策略

    private var policySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("不可信模型上的动作")
                .font(.system(size: 12, weight: .medium))

            Text("只对「不可信」模型生效。可信模型与本地模型一律直接执行。")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            VStack(spacing: 0) {
                ForEach(AIAction.allCasesForSettings, id: \.self) { action in
                    HStack(spacing: 10) {
                        Text(action.label)
                            .font(.system(size: 12))
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
                            .font(.system(size: 11))
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
                .font(.system(size: 12, weight: .medium))

            Text("命中后替换为 ⟨类型序号⟩，模型返回结果再在本地还原。规则按长优先匹配，避免身份证被银行卡规则截断。")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            VStack(spacing: 0) {
                ForEach(Redactor.ruleInfos) { rule in
                    HStack(spacing: 10) {
                        Toggle("", isOn: ruleBinding(name: rule.name))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .controlSize(.mini)

                        Text(rule.name)
                            .font(.system(size: 12))
                            .frame(width: 62, alignment: .leading)

                        Text(rule.hint)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Spacer(minLength: 0)

                        Text(rule.pattern)
                            .font(.system(size: 9, design: .monospaced))
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
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 绑定

    private func binding(_ keyPath: WritableKeyPath<AIPreferences, Bool>) -> Binding<Bool> {
        Binding(
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
