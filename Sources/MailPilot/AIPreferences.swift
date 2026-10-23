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
    /// 浮动提问框上方的建议，可选（旧配置无此字段）
    var askSuggestions: [String]? = nil

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
