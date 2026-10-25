import Foundation

/// 数据外发策略。
///
/// **所有关于「能不能发、要不要脱敏、要不要确认」的规则都集中在这里**，
/// 调用点只问 `TrustPolicy.decide(...)` 拿结论，不自己写 if。
/// 分散判断迟早会漏，集中一处才能审。
enum TrustPolicy {

    /// 一次外发的处置结论。
    ///
    /// 这里刻意用**两个正交维度**而不是四选一枚举：
    /// 「脱敏」和「确认」回答的是两个不同问题——前者管发出去的内容，
    /// 后者管发这个动作要不要人点头。把它们做成互斥选项，就会出现
    /// 「要确认就一定不脱敏」这种荒谬组合（0.2.40 修的就是这个）。
    struct Decision: Equatable {
        /// 发送前必须脱敏
        var redaction: Bool = false
        /// 发送前必须用户确认
        var confirmation: Bool = false
        /// 非 nil 表示拒绝，值是给用户看的理由
        var denial: String? = nil

        static let allow = Decision()
        static let redact = Decision(redaction: true)
        static let confirm = Decision(confirmation: true)
        static let redactConfirm = Decision(redaction: true, confirmation: true)
        static func deny(_ reason: String) -> Decision { Decision(denial: reason) }

        var isAllowed: Bool { denial == nil }
        var needsRedaction: Bool { redaction }
        var needsConfirmation: Bool { confirmation }
    }

    /// 动作 × 信任级别 → 决策。这是唯一的事实来源。
    ///
    /// 用户可在「设置 → 隐私与数据」里覆盖每个动作在不可信模型上的处置，
    /// 未覆盖时走 `PrivacyDefaults`：只读类（摘要/分类）脱敏后直接发，
    /// 会产生对外内容的（草拟回复/翻译）脱敏后再让用户确认。
    ///
    /// - Parameter exempted: 这封邮件是否被用户标记为「不敏感」。
    ///   标记后直接放行，跳过脱敏与确认——但**不推翻 deny**：
    ///   「禁止该动作用于不可信模型」是用户对动作本身的规定，不该被单封邮件覆盖。
    static func decide(action: AIAction,
                       trusted: Bool,
                       prefs: AIPreferences,
                       exempted: Bool = false) -> Decision {
        let base = baseDecision(action: action, trusted: trusted, prefs: prefs)
        guard exempted, base.isAllowed else { return base }
        // 豁免只把 redact / confirm 降级为 allow，deny 保持原样
        return .allow
    }

    private static func baseDecision(action: AIAction,
                                     trusted: Bool,
                                     prefs: AIPreferences) -> Decision {
        guard !trusted else { return .allow }

        var base: Decision
        switch prefs.untrustedPolicy(for: action) {
        case .allow: base = .allow
        case .redact: base = .redact
        case .confirm: base = .confirm
        case .redactConfirm: base = .redactConfirm
        case .deny: base = .deny("「\(action.label)」已被你在隐私设置中禁止用于不可信模型")
        }

        // 总开关只**追加**确认，不取消脱敏。
        // 之前这里是 `return .confirm`，把动作级的「脱敏后放行」直接降级成了
        // 「不脱敏 + 确认」——用户开了更保守的开关，结果内容反而原样外发。
        if prefs.alwaysConfirmUntrusted, base.isAllowed {
            base.confirmation = true
        }
        return base
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
        let decision = decide(action: action, trusted: trusted, prefs: prefs)
        if let reason = decision.denial { return reason }
        if trusted { return "可信模型，内容原样发送" }

        switch (decision.redaction, decision.confirmation) {
        case (true, true): return "不可信模型，发送前会先脱敏，再让你确认"
        case (true, false): return "不可信模型，发送前会自动脱敏"
        case (false, true): return "不可信模型，每次发送前会弹确认"
        case (false, false): return "已放行，内容原样发送"
        }
    }
}
