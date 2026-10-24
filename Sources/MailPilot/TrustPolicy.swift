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
    /// 设计取向：
    /// - 只读类（摘要 / 分类）风险低，不可信模型允许用，但内容必须脱敏
    /// - 会产生对外内容类（回复 / 翻译）风险高，不可信模型每次都要人确认
    /// - 可信模型一律放行，不做额外打扰
    private static let table: [AIAction: (trusted: Decision, untrusted: Decision)] = [
        .summarize: (.allow, .redact),
        .classify: (.allow, .redact),
        .reply: (.allow, .confirm),
        .translate: (.allow, .confirm),
    ]

    static func decide(action: AIAction, trusted: Bool) -> Decision {
        guard let rule = table[action] else {
            // 未登记的动作按最保守处理
            return trusted ? .allow : .confirm
        }
        return trusted ? rule.trusted : rule.untrusted
    }

    static func decide(action: AIAction, provider: AIProvider, model: String) -> Decision {
        decide(action: action, trusted: provider.isTrusted(model))
    }

    /// 供 UI 展示的一句话说明
    static func explain(action: AIAction, trusted: Bool) -> String {
        switch decide(action: action, trusted: trusted) {
        case .allow:
            return "可信模型，内容原样发送"
        case .redact:
            return "不可信模型，发送前会自动脱敏（邮箱 / 手机 / 证件号等）"
        case .confirm:
            return "不可信模型，每次发送前会弹确认"
        case .deny(let reason):
            return "已拒绝：\(reason)"
        }
    }
}
