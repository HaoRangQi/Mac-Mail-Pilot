import AppKit
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
                guardSection
                exemptionSection
                policySection
                redactionSection
                customRulesSection
                keywordsSection
                auditSection
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
                        Image(systemName: provider.isTrustedProvider
                              ? (provider.kind.isLocal ? "lock.shield.fill" : "checkmark.shield.fill")
                              : "exclamationmark.shield.fill")
                            .font(.app(10))
                            .foregroundStyle(provider.isTrustedProvider ? Theme.moss : Theme.gold)
                            .frame(width: 14)

                        Text(provider.name)
                            .font(.app(11.5))

                        Text(provider.isTrustedProvider
                             ? (provider.kind.isLocal ? "本地 · 不出本机" : "可信 · 原样发送")
                             : (provider.kind.isLocal ? "本地 · 已关闭可信，按下方规则管控" : "不可信 · 按下方规则管控"))
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

            Text("开启后任何内容发往第三方前都会弹确认框。它只追加确认，不会取消下面各动作已设的脱敏——该脱敏的仍然先脱敏。")
                .font(.app(11))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - 受保护范围

    private var lockedAccounts: [Account] {
        model.accounts.filter { model.guards.isAccountLocked($0.id) }
    }

    /// 上锁不是脱敏，是「根本不让模型看到」。
    /// 所以这一节必须明确讲清楚它和下面「单封豁免」的方向正好相反。
    private var guardSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("受保护范围")
                    .font(.app(12, weight: .medium))
                Spacer()
                Button {
                    model.clearAllGuards()
                } label: {
                    Text("全部清除")
                        .font(.app(11.5))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.guards.lockedAccountCount == 0 && model.guards.lockedMessageCount == 0)
            }

            Text("上锁的账号或邮件，不可信模型完全看不到——不是脱敏，是根本不进入上下文。账号级与邮件级取最严：账号上锁后，单封不能再解锁。")
                .font(.app(11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 5) {
                statRow("锁定账号", "\(model.guards.lockedAccountCount) 个")
                statRow("锁定邮件", "\(model.guards.lockedMessageCount) 封")
                if model.guards.orphanedCount > 0 {
                    statRow("已失效", "\(model.guards.orphanedCount) 条 · 源邮件已不在磁盘上，满 20 天自动清理")
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))

            if !lockedAccounts.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(lockedAccounts) { account in
                        HStack(spacing: 6) {
                            Image(systemName: "lock.fill")
                                .font(.app(8))
                                .foregroundStyle(Theme.brick)
                            Text(account.name)
                                .font(.app(11.5))
                            Text(account.email)
                                .font(.app(10.5))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                            Spacer(minLength: 6)
                            Button("解锁") {
                                model.unlockAccount(id: account.id)
                            }
                            .buttonStyle(.plain)
                            .font(.app(11))
                            .foregroundStyle(.secondary)
                        }
                        .frame(height: 22)
                    }
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
            }
        }
    }

    private func statRow(_ title: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.app(11.5))
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            Text(value)
                .font(.app(11.5))
            Spacer(minLength: 0)
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

    // MARK: - 外发记录

    /// 每次外发与写操作都会留一条元数据。这里只做「看得见、能清掉」，
    /// 不做复杂查询——真要分析直接看 JSONL 文件。
    private var auditSection: some View {
        // 让清空后能重算大小
        let _ = form.auditVersion
        let bytes = AuditLog.totalBytes

        return VStack(alignment: .leading, spacing: 8) {
            Text("外发记录")
                .font(.app(12, weight: .medium))

            Text("每次把邮件内容发给模型、每次删除或发送，都会记一条元数据：时间、动作、服务商、模型、字符数、脱敏数量。**不记录正文**。")
                .font(.app(11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Text(bytes == 0 ? "还没有记录" : "已占用 \(byteText(bytes))")
                    .font(.app(12))
                    .foregroundStyle(bytes == 0 ? .secondary : .primary)

                Spacer()

                Button("在访达中显示") {
                    if let url = AuditLog.fileURL,
                       FileManager.default.fileExists(atPath: url.path) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(bytes == 0)

                Button("清空") {
                    AuditLog.clear()
                    form.auditVersion += 1
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(bytes == 0)
            }
            .padding(11)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
        }
    }

    private func byteText(_ bytes: Int) -> String {
        if bytes > 1_048_576 { return String(format: "%.1f MB", Double(bytes) / 1_048_576) }
        return "\(max(1, bytes / 1024)) KB"
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
    static let allCasesForSettings: [AIAction] = [.summarize, .reply, .classify, .translate, .ask]
}

/// 隐私设置页的表单状态（@State 在 CLT 下编不过，沿用 ObservableObject）
final class PrivacyForm: ObservableObject {
    @Published var addingRule = false
    @Published var editingRule: CustomRedactionRule?
    /// 审计日志清空后 +1，用来触发大小重算
    @Published var auditVersion = 0
}
