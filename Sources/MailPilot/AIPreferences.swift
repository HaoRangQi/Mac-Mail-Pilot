import Combine
import Foundation

struct AIPreferences: Codable {
    enum Tone: String, Codable, CaseIterable, Identifiable {
        case neutral = "中立"
        case friendly = "友好"
        case formal = "正式"
        case concise = "简洁"
        var id: String { rawValue }
    }

    enum Length: String, Codable, CaseIterable, Identifiable {
        case short = "短"
        case medium = "中"
        case long = "长"
        var id: String { rawValue }

        var hint: String {
            switch self {
            case .short: return "3 句以内"
            case .medium: return "5 句左右"
            case .long: return "可以分点展开"
            }
        }
    }

    var personalizationEnabled = true
    var profile = ""
    var customInstructions = ""
    var tone: Tone = .neutral
    var length: Length = .medium
    var learnWritingStyle = false
    var styleSamples: [String] = []
    var quickRepliesEnabled = true
    var translateEnabled = true
    var translateTarget = "中文"

    /// 翻译专用模型。为空表示沿用主模型。
    ///
    /// 单独配的理由：翻译对**语义完整度**极其敏感，脱敏会把「张三」换成占位符，
    /// 译文就断了。所以给翻译指一个可信/本地的模型，避免为了脱敏牺牲质量。
    var translationProviderID: String? = nil
    var translationModel: String? = nil
    /// 浮动提问框上方的建议，可选（旧配置无此字段）
    var askSuggestions: [String]? = nil

    // MARK: - 隐私与数据外发

    /// 不可信模型时各动作的处置。键为 `AIAction.rawValue`，缺省走内置默认
    var untrustedPolicy: [String: UntrustedPolicy] = [:]

    /// 脱敏规则开关。键为规则名，`false` 表示关闭；缺省视为开启
    var redactionRules: [String: Bool] = [:]

    /// 总开关：只要用了不可信模型，无论什么动作都先弹确认
    var alwaysConfirmUntrusted = false

    /// 关闭的脱敏规则名集合
    var disabledRedactionRules: Set<String> {
        Set(redactionRules.filter { !$0.value }.keys)
    }

    /// 用户自定义的正则脱敏规则
    var customRedactionRules: [CustomRedactionRule] = []

    /// 关键字脱敏：命中即整体替换，不走正则，最可靠
    var redactionKeywords: [String] = []

    func untrustedPolicy(for action: AIAction) -> UntrustedPolicy {
        untrustedPolicy[action.rawValue] ?? PrivacyDefaults.policy(for: action)
    }

    static let defaultSuggestions = [
        "今天有哪些邮件需要我回复？",
        "总结一下当前邮箱的重点",
        "哪些邮件带附件？",
        "最近谁在催我？",
    ]

    var quickReplies: [String] {
        ["感兴趣", "谢谢", "稍后回复", "需要更多信息"]
    }

    var suggestionList: [String] {
        let custom = (askSuggestions ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return custom.isEmpty ? Self.defaultSuggestions : custom
    }
}

/// 不可信模型上某个动作的处置方式
enum UntrustedPolicy: String, Codable, CaseIterable, Identifiable {
    case allow = "放行"
    case redact = "脱敏后放行"
    case confirm = "每次确认"
    case deny = "禁止"

    var id: String { rawValue }

    var hint: String {
        switch self {
        case .allow: return "内容原样发送，不脱敏、不确认"
        case .redact: return "发送前自动脱敏，按下方规则替换敏感信息"
        case .confirm: return "每次发送前弹框，列出目标服务商、字符数与脱敏项"
        case .deny: return "在不可信模型上直接拒绝执行"
        }
    }
}

/// 内置默认策略。`TrustPolicy` 是唯一决策来源，这里是它的缺省值
enum PrivacyDefaults {
    static func policy(for action: AIAction) -> UntrustedPolicy {
        switch action {
        case .summarize, .classify: return .redact
        case .reply, .translate: return .confirm
        }
    }
}

/// 用户自定义的正则脱敏规则。内置规则不可删，自定义的随便改
struct CustomRedactionRule: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var name: String
    var pattern: String
    var enabled: Bool = true
    var hint: String = ""
}

final class AIPreferencesStore: ObservableObject {
    @Published var prefs: AIPreferences {
        didSet { persist() }
    }

    private let storageKey = "mailpilot.ai.preferences"

    init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(AIPreferences.self, from: data) {
            prefs = decoded
        } else {
            prefs = AIPreferences()
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(prefs) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    /// 把个性化、自定义指令、语气长度拼进系统提示词
    func systemPrompt(base: String = "你是一个严谨的中文邮件助理。回答直接、具体，不要客套。",
                      styleSamples autoSamples: [String] = []) -> String {
        var parts = [base]

        if prefs.personalizationEnabled {
            if !prefs.profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append("【关于我】\n\(prefs.profile)")
            }
            let samples = prefs.styleSamples + autoSamples
            if prefs.learnWritingStyle, !samples.isEmpty {
                let joined = samples.prefix(3).map { "- " + $0.prefix(400) }.joined(separator: "\n")
                parts.append("【我的写作风格样本】\n\(joined)")
            }
        }

        parts.append("【写作偏好】语气：\(prefs.tone.rawValue)；长度：\(prefs.length.hint)")

        let custom = prefs.customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty {
            parts.append("【自定义指令（优先级最高，覆盖以上所有内容）】\n\(custom)")
        }

        return parts.joined(separator: "\n\n")
    }
}
