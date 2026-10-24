import Foundation

/// 数据外发策略。
///
/// **所有关于「能不能发、要不要脱敏、要不要确认」的规则都集中在这里**，
/// 调用点只问 `TrustPolicy.decide(...)` 拿结论，不自己写 if。
/// 分散判断迟早会漏，集中一处才能审。
enum TrustPolicy {

    enum Decision: Equatable {
        /// 放行，按原样发送
        case allow
        /// 允许，但必须先脱敏（第三方 + 只读类任务）
        case redact
        /// 允许，但每次发送前要用户确认（第三方 + 会产生对外内容的动作）
        case confirm
        /// 拒绝
        case deny(String)

        var isAllowed: Bool {
            if case .deny = self { return false }
            return true
        }

        var needsRedaction: Bool { self == .redact }
        var needsConfirmation: Bool { self == .confirm }
    }

    /// 动作 × 信任级别 → 决策。这是唯一的事实来源。
    ///
    /// 用户可在「设置 → 隐私与数据」里覆盖每个动作在不可信模型上的处置，
    /// 未覆盖时走 `PrivacyDefaults`：只读类（摘要/分类）脱敏，会产生对外
    /// 内容的（草拟回复/翻译）每次确认。
    ///
    /// - Parameter exempted: 这封邮件是否被用户标记为「不敏感」。
    ///   标记后直接放行，跳过脱敏与确认——但**不推翻 deny**：
    ///   「禁止该动作用于不可信模型」是用户对动作本身的规定，不该被单封邮件覆盖。
    static func decide(action: AIAction,
                       trusted: Bool,
                       prefs: AIPreferences,
                       exempted: Bool = false) -> Decision {
        let base = baseDecision(action: action, trusted: trusted, prefs: prefs)
        guard exempted else { return base }
        // 豁免只把 redact / confirm 降级为 allow，deny 保持原样
        if case .deny = base { return base }
        return .allow
    }

    private static func baseDecision(action: AIAction,
                                     trusted: Bool,
                                     prefs: AIPreferences) -> Decision {
        guard !trusted else { return .allow }

        // 总开关优先：开了就一律先确认
        if prefs.alwaysConfirmUntrusted { return .confirm }

        switch prefs.untrustedPolicy(for: action) {
        case .allow: return .allow
        case .redact: return .redact
        case .confirm: return .confirm
        case .deny: return .deny("「\(action.label)」已被你在隐私设置中禁止用于不可信模型")
        }
    }

    static func decide(action: AIAction,
                       provider: AIProvider,
                       model: String,
                       prefs: AIPreferences,
                       exempted: Bool = false) -> Decision {
        decide(action: action, trusted: provider.isTrusted(model), prefs: prefs, exempted: exempted)
    }

    /// 供 UI 展示的一句话说明
    static func explain(action: AIAction,
                        trusted: Bool,
                        prefs: AIPreferences,
                        exempted: Bool = false) -> String {
        if exempted, !trusted {
            return "这封邮件已标记为不敏感，内容原样发送，不脱敏也不确认"
        }
        switch decide(action: action, trusted: trusted, prefs: prefs) {
        case .allow:
            return trusted ? "可信模型，内容原样发送" : "已放行，内容原样发送"
        case .redact:
            return "不可信模型，发送前会自动脱敏"
        case .confirm:
            return "不可信模型，每次发送前会弹确认"
        case .deny(let reason):
            return reason
        }
    }
}
