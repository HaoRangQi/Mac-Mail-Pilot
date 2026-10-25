import AppKit
import Combine
import Foundation
import SwiftUI

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var next: Appearance {
        switch self {
        case .system: return .light
        case .light: return .dark
        case .dark: return .system
        }
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case appearance
    case permissions
    case providers
    case privacy
    case features
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: return "外观"
        case .permissions: return "权限管理"
        case .providers: return "模型服务"
        case .privacy: return "隐私与数据"
        case .features: return "AI 功能"
        case .about: return "关于"
        }
    }

    var icon: String {
        switch self {
        case .appearance: return "paintbrush"
        case .permissions: return "lock.shield"
        case .providers: return "cpu"
        case .privacy: return "hand.raised"
        case .features: return "sparkles"
        case .about: return "info.circle"
        }
    }
}

enum ComposeAIError: LocalizedError {
    case noModel

    var errorDescription: String? {
        switch self {
        case .noModel: return "还没有可用的模型。先到「设置 → 模型服务」配置一个。"
        }
    }
}

/// 阅读页 AI 动作类型。决定生成结果下方给哪些操作按钮：
/// 摘要 / 分类只要复制；只有回复才需要编辑、存草稿、发送。
enum AIAction: String, Hashable {
    case summarize
    case reply
    case classify
    case translate

    var label: String {
        switch self {
        case .summarize: return "AI 摘要"
        case .reply: return "草拟回复"
        case .classify: return "分类"
        case .translate: return "翻译"
        }
    }
}

struct AskTurn: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var question: String
    var answer: String
    var date: Date = Date()
    var accounts: [String] = []
}

@MainActor
final class AppModel: ObservableObject {    // 数据
    @Published var accounts: [Account] = []
    @Published var mailboxes: [Mailbox] = []
    @Published var messages: [Message] = []
    @Published var badges: [String: Int] = [:]
    @Published var selectedMailboxID: String?
    @Published var selected: Message?
    @Published var query: String = ""

    // 状态
    @Published var loading = false
    @Published var syncing = false
    @Published var errorMessage: String?
    /// 轻量操作反馈，2.5 秒后自动消失
    @Published var toast: String?
    @Published var isDemo = true
    @Published var aiOutput: String?
    @Published var aiBusy = false
    /// 这次输出是哪个动作产生的——决定下方按钮给哪些（摘要不需要「存草稿/发送」）
    @Published var aiAction: AIAction?
    /// 本次输出是否来自可信模型。false 时界面要明确标注数据已外发给不可信服务商
    @Published var aiOutputTrusted = true
    /// 本次输出的脱敏映射，供界面展示「到底把什么替换成了占位符」
    @Published var aiRedactions: [Redactor.Mapping] = []
    /// 本次是「这封邮件已豁免」才原样发出的（用于结果区提示，别让用户以为脱敏失效了）
    @Published var aiExempted = false
    /// 回复草稿的编辑态
    @Published var aiEditing = false
    @Published var aiDraftText = ""
    @Published var composing = false
    @Published var showSettings = false
    /// 阅读区独占窗口：把侧边栏和列表挤掉，方便看长正文
    @Published var readerExpanded = false
    @Published var pendingDelete: Message?
    @Published var showDeleteConfirm = false
    /// 删除执行中（全库扫描兜底可能耗时，界面需要给出反馈）
    @Published var deleting = false
    /// 待确认发送的 AI 正文（非 nil 时弹确认框）
    @Published var pendingAISend: String?
    /// 待确认的 AI 请求（不可信模型 + 会生成对外内容时弹框）
    @Published var pendingAI: PendingAIRequest?
    @Published var showOnboarding = false

    // 设置
    @Published var settingsTab: SettingsTab = .permissions

    func openSettings(tab: SettingsTab = .permissions) {
        settingsTab = tab
        showSettings = true
    }

    // 浮动提问框
    @Published var showAsk = false
    @Published var askText = ""
    @Published var askBusy = false
    @Published var askAllAccounts = false
    @Published var askAccounts: Set<String> = []
    @Published var askHistory: [AskTurn] = []
    @Published var askSelectMode = false
    @Published var askSelected: Set<String> = []

    @Published var appearance: Appearance {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: "mailpilot.appearance") }
    }

    /// 侧边栏折叠的分组（"fav" / "smart" / 账户 ID）
    @Published var collapsedSections: Set<String> {
        didSet { UserDefaults.standard.set(Array(collapsedSections), forKey: "mailpilot.sidebar.collapsed") }
    }

    let ai = AISettingsStore()
    let prefs = AIPreferencesStore()
    /// 界面外观设置。改它 → store 发通知 → 这里转发 → 观察 model 的视图全部重算
    let ui = UISettingsStore()
    /// 单封邮件的「不敏感」名单（跳过脱敏与确认）
    let exemption = MailExemptionStore()
    private var uiObserver: AnyCancellable?
    private var exemptionObserver: AnyCancellable?
    private(set) var store: MailStore = DemoStore()
    private var searchTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var sentSamples: [String] = []
    private let askStorageKey = "mailpilot.ai.askHistory"

    init() {
        let raw = UserDefaults.standard.string(forKey: "mailpilot.appearance") ?? Appearance.system.rawValue
        appearance = Appearance(rawValue: raw) ?? .system
        collapsedSections = Set(UserDefaults.standard.stringArray(forKey: "mailpilot.sidebar.collapsed") ?? [])
        loadAskHistory()

        // UIState 是静态快照，视图不会自己发现它变了。
        // 把 store 的变更转发成 AppModel 的变更，主界面才能立刻跟着变。
        uiObserver = ui.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        exemptionObserver = exemption.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }

        if let native = NativeMailStore() {
            store = native
            isDemo = false
        } else {
            store = DemoStore()
            isDemo = true
            if !UserDefaults.standard.bool(forKey: "mailpilot.onboarding.dismissed") {
                showOnboarding = true
            }
        }
        writeLaunchStatus()
    }

    /// 每次启动把权限状态与所用数据源追加到 status.txt，方便排查「为什么停在演示模式」
    private func writeLaunchStatus() {
        let status: String
        switch MailAccess.status() {
        case .authorized(let version): status = "authorized(\(version))"
        case .denied: status = "denied"
        case .noMailData: status = "noMailData"
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let file = base.appendingPathComponent("MailPilot/status.txt")
        let line = "\(stamp) store=\(isDemo ? "demo" : "native") fda=\(status)\n"
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8) ?? Data())
            try? handle.close()
        } else {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? line.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - 派生

    var selectionTitle: String {
        guard let id = selectedMailboxID else { return "邮件" }
        if let smart = SmartBox(rawValue: id) { return smart.title }
        return mailboxes.first { $0.id == id }?.name ?? "邮件"
    }

    var totalUnread: Int {
        mailboxes.filter { $0.role == .inbox }.reduce(0) { $0 + $1.unread }
    }

    // MARK: - 生命周期

    func load() async {
        loading = true
        errorMessage = nil
        do {
            accounts = try await store.accounts()
            mailboxes = try await store.mailboxes()
            badges = try await store.badgeCounts()
            isDemo = store.isDemo
            if selectedMailboxID == nil {
                selectedMailboxID = SmartBox.allInbox.rawValue
            }
            await loadStyleSamples()
            await loadMessages()
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }

    func reload() async {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        // 重新发现邮箱目录（新邮件、新账户）
        if let native = NativeMailStore() {
            store = native
            isDemo = false
        }
        await load()
    }

    // MARK: - 权限

    /// 重新检测完全磁盘访问权限；成功后切到真实邮件
    @discardableResult
    func recheckAccess() async -> Bool {
        guard let native = NativeMailStore() else { return false }
        store = native
        isDemo = false
        showOnboarding = false
        selectedMailboxID = nil
        selected = nil
        await load()
        return true
    }

    func useDemoData() {
        UserDefaults.standard.set(true, forKey: "mailpilot.onboarding.dismissed")
        showOnboarding = false
    }

    func selectMailbox(_ id: String) async {
        selectedMailboxID = id
        selected = nil
        aiOutput = nil
        aiAction = nil
        aiEditing = false
        aiRedactions = []
        aiExempted = false
        query = ""
        if showAsk { syncAskScopeToSelection() }
        await loadMessages()
    }

    func loadMessages() async {
        guard let id = selectedMailboxID else { return }
        do {
            messages = try await store.messages(mailboxID: id, limit: 200)
        } catch {
            errorMessage = error.localizedDescription
            messages = []
        }
    }

    func open(_ message: Message) async {
        selected = message
        aiOutput = nil
        aiAction = nil
        aiEditing = false
        aiRedactions = []
        aiExempted = false
        if message.unread, let idx = messages.firstIndex(where: { $0.id == message.id }) {
            messages[idx].unread = false
        }
    }

    // MARK: - 搜索

    func scheduleSearch() {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            Task { await loadMessages() }
            return
        }
        searchTask = Task { [q] in
            try? await Task.sleep(nanoseconds: 260_000_000)
            guard !Task.isCancelled else { return }
            do {
                let rows = try await store.search(q, limit: 80)
                guard !Task.isCancelled else { return }
                self.messages = rows
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - AI

    private func context(_ m: Message) -> String {
        """
        发件人: \(m.sender) <\(m.senderEmail)>
        主题: \(m.subject)
        日期: \(m.date.formatted())
        正文:
        \(m.body.prefix(3000))
        """
    }

    func summarize() {
        guard let m = selected else { return }
        aiAction = .summarize
        aiEditing = false
        aiOutput = nil
        aiRedactions = []
        aiExempted = false
        requestAI(action: .summarize,
                  prompt: "用三句话以内概括这封邮件的要点，以及需要我做什么。",
                  message: m,
                  fallback: { Self.localSummary(m) })
    }

    func draftReply(instruction: String = "") {
        guard let m = selected else { return }
        let prompt = "基于这封邮件，用专业简洁的中文草拟一封回复" +
            (instruction.isEmpty ? "" : "，要求：\(instruction)") + "。只输出回复正文。"
        aiAction = .reply
        aiEditing = false
        aiOutput = nil
        aiRedactions = []
        aiExempted = false
        requestAI(action: .reply, prompt: prompt, message: m, fallback: { Self.localReply(m) })
    }

    func classify() {
        guard let m = selected else { return }
        aiAction = .classify
        aiEditing = false
        aiOutput = nil
        aiRedactions = []
        aiExempted = false
        requestAI(action: .classify,
                  prompt: "给这封邮件分类并判断优先级。只输出 JSON：{\"category\":\"...\",\"priority\":\"高|中|低\",\"needs_reply\":true|false}",
                  message: m,
                  fallback: { Self.localClassify(m) })
    }

    func translate() {
        guard let m = selected else { return }
        let target = prefs.prefs.translateTarget
        aiAction = .translate
        aiEditing = false
        aiOutput = nil
        aiRedactions = []
        aiExempted = false
        requestAI(action: .translate,
                  prompt: "把这封邮件翻译成\(target)，保留原意与结构，只输出译文。",
                  message: m,
                  route: translationRoute,
                  fallback: { "（未配置模型，无法翻译）" })
    }

    /// 翻译专用路由。没配、或配的模型已经不可用（服务商被删/关闭/没密钥）时返回 nil，回落到主模型。
    ///
    /// 翻译对语义完整度太敏感：脱敏把「张三」换成占位符，译文就断了。
    /// 所以允许单独指一个可信/本地模型，宁可换模型也不牺牲译文质量。
    var translationRoute: (provider: AIProvider, model: String)? {
        guard let id = prefs.prefs.translationProviderID,
              let provider = ai.providers.first(where: { $0.id == id }),
              provider.enabled,
              provider.kind.isLocal || provider.hasKey else { return nil }
        let configured = prefs.prefs.translationModel ?? ""
        let model = configured.isEmpty ? provider.selectedModel : configured
        guard !model.isEmpty else { return nil }
        return (provider, model)
    }

    /// 翻译按钮的浮动提示要显示的模型名
    var translationModelLabel: String {
        if let route = translationRoute {
            return route.provider.displayName(for: route.model)
        }
        if let active = ai.activeProvider {
            return active.displayName(for: active.selectedModel) + "（跟随主模型）"
        }
        return "未配置模型"
    }

    /// 写邮件页的正文起草。
    ///
    /// 和阅读页的 AI 动作不一样：外发的只有**用户自己敲的意图**（外加主题），
    /// 不含任何邮件正文，所以不走「邮件内容外发」的确认流程——用户点「AI 起草」
    /// 本身就是明确的外发意图，再弹一次确认只是噪音。
    /// 但模型不可信时仍然先脱敏：规则一致，只是不打断。
    func draftComposeBody(intent: String, subject: String, currentBody: String = "") async throws -> String {
        guard let provider = ai.activeProvider else {
            throw ComposeAIError.noModel
        }
        let model = provider.selectedModel
        let trusted = provider.isTrusted(model)

        let cleanSubject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = currentBody.trimmingCharacters(in: .whitespacesAndNewlines)

        // 主题是防跑偏最有力的锚点：有就明确要求紧扣，没有就完全不提，
        // 免得在提示词里留一个空的「主题：」反而干扰模型
        let subjectLine = cleanSubject.isEmpty ? "" : "邮件主题：\(cleanSubject)\n"
        let subjectRule = cleanSubject.isEmpty
            ? ""
            : "正文必须紧扣主题「\(cleanSubject)」，不要偏题、不要扩写主题以外的内容。\n"

        // 正文为空 → 起草；已有正文 → 按意图改写（这时正文也会一起外发，所以提示语里写明了）
        var user: String
        if body.isEmpty {
            user = """
            我要写一封邮件。
            \(subjectLine)意图：\(intent)
            \(subjectRule)直接输出邮件正文：中文、简洁专业、不要主题行、不要「以下是正文」这类说明，称呼与落款按需自然处理。
            """
        } else {
            user = """
            下面是我已经写好的一封邮件正文，请按我的要求改写它。
            \(subjectLine)修改要求：\(intent)
            \(subjectRule)当前正文：
            ---
            \(body)
            ---
            直接输出改写后的完整正文：中文、简洁专业、不要主题行、不要解释你改了什么。
            """
        }

        // 这里只看「要不要脱敏」，不看「要不要确认」：用户点「AI 起草」本身就是
        // 明确的外发意图，再弹一次确认只是噪音。规则仍然问 TrustPolicy，不自己写 if。
        let system = prefs.systemPrompt(styleSamples: sentSamples)
        var outboundSystem = system
        var mappings: [Redactor.Mapping] = []
        if TrustPolicy.decide(action: .reply, trusted: trusted, prefs: prefs.prefs).needsRedaction {
            let redacted = Redactor.redact(
                segments: [system, user],
                disabledRules: prefs.prefs.disabledRedactionRules,
                customRules: prefs.prefs.customRedactionRules,
                keywords: prefs.prefs.redactionKeywords
            )
            outboundSystem = redacted.segments[0]
            user = redacted.segments[1]
            mappings = redacted.mappings
        }

        let text = try await AIService.chat(
            provider: provider,
            model: model,
            system: outboundSystem,
            user: user
        )
        return mappings.isEmpty ? text : Redactor.restore(text, mappings)
    }

    /// 写邮件页按钮提示里显示的模型名
    var aiDraftModelLabel: String {
        guard let provider = ai.activeProvider else { return "未配置模型" }
        let trusted = provider.isTrusted(provider.selectedModel)
        let name = provider.displayName(for: provider.selectedModel)
        return trusted ? name : name + "（不可信，会先脱敏）"
    }

    // MARK: - 单封邮件豁免

    /// 豁免名单的键：优先 Message-ID（挪邮箱不变），退回收件路径
    func exemptionKey(for message: Message) -> String {
        message.messageID.isEmpty ? message.id : message.messageID
    }

    func isExempt(_ message: Message) -> Bool {
        exemption.contains(exemptionKey(for: message))
    }

    func setExempt(_ exempt: Bool, for message: Message) {
        exemption.set(exempt, id: exemptionKey(for: message))
    }

    /// 当前主模型是否可信（用于决定豁免开关显示哪种状态）
    var mainModelTrusted: Bool {
        guard let provider = ai.activeProvider else { return true }
        return provider.isTrusted(provider.selectedModel)
    }

    /// 根据最近收件箱生成「我的简介」
    func generateProfile() async -> String {
        guard let provider = ai.activeProvider else {
            return "请先在「模型服务」里配置一个可用的模型。"
        }
        let recent = (try? await store.messages(mailboxID: SmartBox.allInbox.rawValue, limit: 8)) ?? []
        guard !recent.isEmpty else { return "收件箱为空，无法生成简介。" }

        let ctx = recent.map {
            "主题：\($0.subject)\n发件人：\($0.displaySender)\n\($0.body.prefix(300))"
        }.joined(separator: "\n---\n")

        // 「生成简介」也是把邮件正文发出去，同样受外发策略约束：
        // 不可信模型先脱敏，返回后再把占位符还原（简介存在本机，不需要保持脱敏）。
        var payload = ctx
        var mappings: [Redactor.Mapping] = []
        if !provider.isTrusted(provider.selectedModel) {
            let redacted = Redactor.redact(
                ctx,
                disabledRules: prefs.prefs.disabledRedactionRules,
                customRules: prefs.prefs.customRedactionRules,
                keywords: prefs.prefs.redactionKeywords
            )
            payload = redacted.text
            mappings = redacted.mappings
        }

        do {
            let text = try await AIService.chat(
                provider: provider,
                system: "你是一个谨慎的中文助理，只根据给定邮件推断，不要编造。",
                user: "根据以下最近邮件，用 120 字以内写出「我的简介」：我的角色、主要工作内容、常见沟通对象。只输出简介正文。\n\n\(payload)"
            )
            return mappings.isEmpty ? text : Redactor.restore(text, mappings)
        } catch {
            return "生成失败：\(error.localizedDescription)"
        }
    }

    private func loadStyleSamples() async {
        guard prefs.prefs.learnWritingStyle else {
            sentSamples = []
            return
        }
        let sentBoxes = mailboxes.filter { $0.role == .sent }
        var samples: [String] = []
        for box in sentBoxes.prefix(2) {
            if let rows = try? await store.messages(mailboxID: box.id, limit: 2) {
                samples.append(contentsOf: rows.map { String($0.body.prefix(400)) })
            }
        }
        sentSamples = Array(samples.prefix(3))
    }

    /// 待确认的 AI 请求（不可信模型 + 会产生对外内容的动作时弹框）
    struct PendingAIRequest {
        let action: AIAction
        let provider: AIProvider?
        /// 这次请求实际用的模型（翻译可以走专用模型，不等于 provider.selectedModel）
        let model: String
        /// 实际要外发的 system 与 user（已按策略脱敏）
        var system: String
        var user: String
        /// 未脱敏原文。确认框里的「脱敏后发送」要用它重做一遍
        var originalSystem: String
        var originalUser: String
        let fallbackText: String
        var mappings: [Redactor.Mapping]
        var charCount: Int
        /// 脱敏后实际发送的文本，供用户在确认框里逐字检查
        var outboundPreview: String
        /// 演示模式：不真的发请求，确认后直接给本地结果
        let simulated: Bool
    }

    /// 所有 AI 调用的唯一入口：查策略 → 脱敏 → 需要确认则挂起 → 发送 → 还原。
    /// 不要在各处手写 if，规则只在 TrustPolicy 一处。
    private func requestAI(action: AIAction,
                           prompt: String,
                           message: Message,
                           route: (provider: AIProvider, model: String)? = nil,
                           fallback: () -> String) {
        let fallbackText = fallback()

        // 翻译可以指定专用模型；其余动作走当前主模型
        let resolved: (provider: AIProvider, model: String)?
        if let route {
            resolved = route
        } else if let active = ai.activeProvider {
            resolved = (active, active.selectedModel)
        } else {
            resolved = nil
        }

        guard let resolved else {
            // 演示模式下没有可用模型，也走一遍完整的「脱敏 → 确认 → 预览」链路，
            // 确认后给本地结果。否则用户不配 key 就永远看不到管控长什么样。
            if isDemo {
                let system = prefs.systemPrompt(styleSamples: sentSamples)
                let user = prompt + "\n\n" + context(message)
                let redacted = Redactor.redact(
                    segments: [system, user],
                    disabledRules: prefs.prefs.disabledRedactionRules,
                    customRules: prefs.prefs.customRedactionRules,
                    keywords: prefs.prefs.redactionKeywords
                )
                aiOutputTrusted = false
                pendingAI = PendingAIRequest(
                    action: action,
                    provider: nil,
                    model: "",
                    system: "",
                    user: redacted.segments[1],
                    originalSystem: system,
                    originalUser: user,
                    fallbackText: fallbackText,
                    mappings: redacted.mappings,
                    charCount: redacted.segments[1].count,
                    outboundPreview: redacted.segments[1],
                    simulated: true
                )
                aiRedactions = redacted.mappings
                return
            }

            aiOutputTrusted = true
            aiOutput = fallbackText + "\n\n（未配置模型，以上为本地生成。点右上角齿轮接入 AI。）"
            return
        }

        let provider = resolved.provider
        let model = resolved.model

        // 这封邮件是否被用户标记为「不敏感」——标记后跳过脱敏与确认，
        // 但「禁止该动作」的硬性策略不受影响（见 TrustPolicy）
        let exempted = exemption.contains(exemptionKey(for: message))

        let decision = TrustPolicy.decide(action: action,
                                          provider: provider,
                                          model: model,
                                          prefs: prefs.prefs,
                                          exempted: exempted)
        if let reason = decision.denial {
            aiOutput = "已拒绝：\(reason)"
            return
        }
        aiExempted = exempted && !provider.isTrusted(model)

        // system 里也有真实内容（用户简介、发件箱原文样本），必须和 user 一起脱敏。
        // 两段共用一套占位符编号，否则还原时会把 A 段的邮箱还原成 B 段的。
        let system = prefs.systemPrompt(styleSamples: sentSamples)
        let user = prompt + "\n\n" + context(message)
        var outboundSystem = system
        var outboundUser = user
        var mappings: [Redactor.Mapping] = []

        if decision.needsRedaction {
            let redacted = Redactor.redact(
                segments: [system, user],
                disabledRules: prefs.prefs.disabledRedactionRules,
                customRules: prefs.prefs.customRedactionRules,
                keywords: prefs.prefs.redactionKeywords
            )
            outboundSystem = redacted.segments[0]
            outboundUser = redacted.segments[1]
            mappings = redacted.mappings
            aiRedactions = redacted.mappings
        }

        aiOutputTrusted = provider.isTrusted(model)

        let request = PendingAIRequest(
            action: action,
            provider: provider,
            model: model,
            system: outboundSystem,
            user: outboundUser,
            originalSystem: system,
            originalUser: user,
            fallbackText: fallbackText,
            mappings: mappings,
            charCount: outboundSystem.count + outboundUser.count,
            outboundPreview: Self.preview(system: outboundSystem, user: outboundUser),
            simulated: false
        )

        if decision.needsConfirmation {
            pendingAI = request
            return
        }
        performAI(request)
    }

    /// 确认框里「查看实际发送的内容」的展示文本：system 与 user 都会发出去，就都要露出来
    private static func preview(system: String, user: String) -> String {
        guard !system.isEmpty else { return user }
        return "【系统提示词】\n\(system)\n\n【邮件内容】\n\(user)"
    }

    /// 用户确认后继续。
    ///
    /// - Parameter redacting: 用户在确认框里选了「脱敏后发送」。
    ///   这条路径存在的理由：动作策略是「每次确认」时内容本来不脱敏，
    ///   但用户看到确认框才意识到这封邮件敏感——不该逼他去设置里改永久策略。
    func confirmPendingAI(redacting: Bool = false) {
        guard var request = pendingAI else { return }
        pendingAI = nil

        if redacting, request.mappings.isEmpty {
            let redacted = Redactor.redact(
                segments: [request.originalSystem, request.originalUser],
                disabledRules: prefs.prefs.disabledRedactionRules,
                customRules: prefs.prefs.customRedactionRules,
                keywords: prefs.prefs.redactionKeywords
            )
            request.system = redacted.segments[0]
            request.user = redacted.segments[1]
            request.mappings = redacted.mappings
            request.charCount = request.system.count + request.user.count
            request.outboundPreview = Self.preview(system: request.system, user: request.user)
            aiRedactions = redacted.mappings
        }

        performAI(request)
    }

    private func performAI(_ request: PendingAIRequest) {
        // 演示模式：不真的发请求，直接给本地结果
        if request.simulated {
            aiBusy = false
            aiOutputTrusted = false
            aiOutput = request.fallbackText
                + "\n\n（演示模式：未配置真实模型，以上为本地生成。上面的确认框展示了不可信模型的完整管控流程。）"
            return
        }

        aiBusy = true
        guard let provider = request.provider else {
            aiBusy = false
            errorMessage = "配置缺失：找不到可用的模型服务商"
            return
        }
        Task { @MainActor in
            do {
                let text = try await AIService.chat(
                    provider: provider,
                    model: request.model.isEmpty ? provider.selectedModel : request.model,
                    system: request.system,
                    user: request.user
                )
                aiOutput = request.mappings.isEmpty
                    ? text
                    : Redactor.restore(text, request.mappings)
            } catch {
                aiOutputTrusted = true   // 失败后是本地结果，数据没外发
                aiOutput = "调用失败：\(error.localizedDescription)\n\n--- 本地结果 ---\n\(request.fallbackText)"
            }
            aiBusy = false
        }
    }

    static func localSummary(_ m: Message) -> String {
        let sentences = m.body
            .split(whereSeparator: { "。！？\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count > 8 }
        var out = sentences.prefix(3).joined(separator: "；")
        if out.isEmpty { out = String(m.body.prefix(90)) }
        if m.needsReply { out += "\n\n需要你回复。" }
        if !m.attachments.isEmpty {
            out += "\n附件：" + m.attachments.map(\.filename).joined(separator: "、")
        }
        return out
    }

    static func localReply(_ m: Message) -> String {
        let who = m.displaySender
        var text = "\(who)您好，\n\n"
        if m.subject.contains("报价") || m.subject.contains("采购") {
            text += "收到您的需求。关于阶梯报价和账期，我们内部核算后会在本周五前给您完整方案。\n\n另确认一下：200 台的交付是否需要分批？"
        } else if m.subject.contains("维护") {
            text += "窗口没问题。这次会连缓存层一起重启，建议把窗口延长到 5 点，我这边同步更新维护公告。"
        } else if m.subject.contains("合同") {
            text += "意见收到，付款节点和违约金上限两处我们原则同意，法务确认后今天回签。"
        } else {
            text += "邮件收到，我这边确认后尽快回复您。"
        }
        return text + "\n\n祝好"
    }

    static func localClassify(_ m: Message) -> String {
        let s = m.subject
        var category = "其他"
        let table: [(String, String)] = [
            ("报价", "商务"), ("合同", "商务"), ("采购", "商务"),
            ("体检", "行政"), ("维护", "系统通知"), ("Issue", "订阅资讯"),
            ("招聘", "人事"), ("存储", "系统通知"), ("阅读", "订阅资讯"),
            ("账单", "财务"), ("订阅", "财务"), ("登录", "系统通知"),
        ]
        for (k, v) in table where s.contains(k) { category = v; break }
        let priority = m.needsReply ? "高" : "低"
        return "分类：\(category)\n优先级：\(priority)\n需回复：\(m.needsReply ? "是" : "否")"
    }

    // MARK: - 删除（永不自动执行，必须二次确认；真实移入「邮件」App 废纸篓）

    func requestDelete(_ message: Message) {
        pendingDelete = message
        showDeleteConfirm = true
    }

    func confirmDelete() async {
        guard let target = pendingDelete else { return }
        pendingDelete = nil
        showDeleteConfirm = false
        deleting = true
        defer { deleting = false }
        do {
            try await store.moveToTrash(target)
            if selected?.id == target.id { selected = nil }
            messages.removeAll { $0.id == target.id }
            // 以数据源为准重新拉一次：真实模式下 .emlx 已移走，演示模式下内存已移除
            await loadMessages()
            badges = (try? await store.badgeCounts()) ?? badges
            mailboxes = (try? await store.mailboxes()) ?? mailboxes
            showToast(isDemo ? "已从演示数据中移除" : "已移入「邮件」App 的废纸篓")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 底部轻提示，自动消失
    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }

    // MARK: - 工具调用（AI 操作邮件）

    /// 待用户确认的工具调用（破坏性操作）
    @Published var pendingToolCall: ToolCall?

    /// 确认挂起时的续体。工具调用闭包会 await 在这里，直到用户在弹框上点确认或取消
    private var toolConfirmContinuation: CheckedContinuation<Bool, Never>?

    /// 当前模型能否使用某工具。
    /// 只读任何模型可用；写入与破坏性一律先确认——「AI 只找不删」的边界在这里守住。
    func toolPermission(_ tool: MailTool) -> (allowed: Bool, needsConfirm: Bool) {
        switch tool.risk {
        case .read:
            return (true, false)
        case .write, .destructive:
            return (true, true)
        }
    }

    /// 用户在弹框上的选择。resume 挂起中的工具调用，让 AI 拿到结果后继续
    func resolveToolConfirmation(_ approved: Bool) {
        toolConfirmContinuation?.resume(returning: approved)
        toolConfirmContinuation = nil
        if !approved { pendingToolCall = nil }
    }

    /// 执行一次工具调用，返回给模型看的文本结果
    func executeToolCall(_ call: ToolCall) async -> String {
        // 非只读工具一律先问人。删除虽只是进废纸篓、可恢复，也必须由用户点头
        if call.tool.risk != .read {
            pendingToolCall = call
            let approved = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                self.toolConfirmContinuation = continuation
            }
            pendingToolCall = nil
            guard approved else { return "用户取消了这次操作，没有执行" }
        }

        switch call.tool {
        case .searchMessages:
            let query = (call.arguments["query"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return "搜索词为空" }
            let hits = (try? await store.search(query, limit: 10)) ?? []
            guard !hits.isEmpty else { return "没有找到匹配「\(query)」的邮件" }
            return hits.map { m in
                """
                - id: \(m.id)
                  主题: \(m.subject)
                  发件人: \(m.displaySender) <\(m.senderEmail)>
                  日期: \(m.date.formatted(date: .abbreviated, time: .shortened))
                  摘要: \(m.preview)
                """
            }.joined(separator: "\n")

        case .getMessage:
            let id = call.arguments["message_id"] as? String ?? ""
            guard let message = try? await store.message(id: id) else {
                return "找不到 ID 为 \(id) 的邮件"
            }
            return """
            主题: \(message.subject)
            发件人: \(message.displaySender) <\(message.senderEmail)>
            日期: \(message.date.formatted())
            正文:
            \(message.body.prefix(3000))
            """

        case .listMailboxes:
            let grouped = Dictionary(grouping: mailboxes) { $0.accountID }
            var lines: [String] = []
            for account in accounts {
                let boxes = grouped[account.id] ?? []
                guard !boxes.isEmpty else { continue }
                lines.append("\(account.name)（\(account.email.isEmpty ? "无邮箱地址" : account.email)）")
                for box in boxes {
                    lines.append("  - \(box.name)：\(box.total) 封")
                }
            }
            return lines.isEmpty ? "没有邮箱" : lines.joined(separator: "\n")

        case .moveToTrash:
            let id = call.arguments["message_id"] as? String ?? ""
            guard let message = try? await store.message(id: id) else {
                return "找不到 ID 为 \(id) 的邮件"
            }
            // 破坏性操作：必须用户点过确认才会走到这里
            do {
                try await store.moveToTrash(message)
                await loadMessages()
                showToast("已移入废纸篓：\(message.subject)")
                return "已移入废纸篓：\(message.subject)"
            } catch {
                return "删除失败：\(error.localizedDescription)"
            }

        case .markRead, .setFlag, .saveDraft, .sendMessage:
            return "工具「\(call.tool.rawValue)」尚未开放。标记已读、旗标、存草稿、发送请在界面上手动完成。"
        }    }

    /// 带工具的问答入口
    func askWithTools(_ question: String) async {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        guard ai.activeProvider != nil else {
            errorMessage = "还没有配置模型。点右上角齿轮接入后才能使用问答。"
            return
        }

        askBusy = true
        defer { askBusy = false }

        do {
            let answer = try await runAsk(text)
            appendAsk(question: text, answer: answer)
        } catch {
            errorMessage = "调用失败：\(error.localizedDescription)"
        }
    }

    /// 真正发请求的那一步。首次提问和「重跑」共用
    private func runAsk(_ text: String) async throws -> String {
        guard let provider = ai.activeProvider else { throw AIError.notConfigured }

        let system = """
        你是 MailPilot 的邮件助理。你可以调用工具查询用户的邮件并回答问题。

        规则：
        - 需要邮件信息时，先 searchMessages 拿 ID，再 getMessage 读正文
        - 回答用简体中文，直接、具体，不要客套
        - 不知道就说不知道，不要编造邮件内容
        - 删除、发送等操作**必须由用户确认后才能执行**。你请求之后系统会弹框问用户，
          在收到「已执行」之前绝对不要说「已经删除/已经发送」
        - moveToTrash 只是移入废纸篓，可以恢复，但仍需用户点头
        """

        return try await AIService.chatWithTools(
            provider: provider,
            model: provider.selectedModel,
            system: system,
            user: text,
            tools: MailTool.allCases.map { $0.toolSchema }
        ) { call in
            await self.executeToolCall(call)
        }
    }

    // MARK: - AI 结果交付（作为当前邮件的回复）

    /// 进入回复草稿的编辑态
    func beginEditingAI() {
        aiDraftText = aiOutput ?? ""
        aiEditing = true
    }

    /// 退出编辑态，把修改写回输出
    func finishEditingAI() {
        let text = aiDraftText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { aiOutput = aiDraftText }
        aiEditing = false
    }

    /// 当前可交付的文本：编辑态取编辑框，否则取原始输出
    var aiDeliverableText: String {
        aiEditing ? aiDraftText : (aiOutput ?? "")
    }

    /// 把 AI 生成的正文当作回复：存进「邮件」草稿箱，或直接发送。
    /// 收件人取原邮件的发件人，主题补 Re:，发件账号取原邮件所属账户。
    func deliverAIOutput(_ text: String, asDraft: Bool) async {
        guard let message = selected else { return }
        let to = message.senderEmail
        guard !to.isEmpty else {
            errorMessage = "这封邮件没有发件人地址，无法回复"
            return
        }
        let from = accounts.first { $0.id == message.accountID }?.email ?? ""
        let subject = message.subject.lowercased().hasPrefix("re:")
            ? message.subject
            : "Re: \(message.subject)"
        let body = text

        do {
            try await Task.detached(priority: .userInitiated) {
                try MailSender.compose(
                    from: from, to: [to], cc: [], bcc: [],
                    subject: subject, body: body,
                    delivery: asDraft ? .saveDraft : .sendNow
                )
            }.value
            showToast(asDraft ? "已存入「邮件」草稿箱" : "已交给「邮件」发送")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - 外观

    func cycleAppearance() {
        appearance = appearance.next
    }

    func toggleSection(_ key: String) {
        if collapsedSections.contains(key) {
            collapsedSections.remove(key)
        } else {
            collapsedSections.insert(key)
        }
    }

    // MARK: - 浮动提问框

    var askSuggestions: [String] {
        prefs.prefs.suggestionList
    }

    func toggleAsk() {
        if showAsk {
            closeAsk()
            return
        }
        showAsk = true
        syncAskScopeToSelection()
    }

    /// 每次打开浮动框，按当前侧边栏选中项重置范围：
    /// 智能邮箱（所有收件箱/今天…）→ 所有账号；某个账号的邮箱 → 只勾该账号
    func syncAskScopeToSelection() {
        if let active = activeAccountID {
            askAllAccounts = false
            askAccounts = [active]
        } else {
            askAllAccounts = true
            askAccounts = []
        }
    }

    func closeAsk() {
        showAsk = false
        askText = ""
        askSelectMode = false
        askSelected = []
    }

    func ask() {
        let question = askText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !askBusy else { return }

        guard let provider = ai.activeProvider else {
            appendAsk(question: question, answer: "还没有配置模型。点右上角齿轮 →「模型服务」添加一个。")
            return
        }

        askBusy = true
        askText = ""

        let allAccounts = askAllAccounts
        let targets = allAccounts ? accounts.map(\.id) : Array(askAccounts)
        let scopeText = allAccounts
            ? "所有账号（\(targets.count) 个）"
            : "已选账号：" + accounts.filter { targets.contains($0.id) }.map(\.name).joined(separator: "、")
        let scopeNames = allAccounts ? ["所有账号"] : accounts.filter { targets.contains($0.id) }.map(\.name)

        let turn = AskTurn(question: question, answer: "", accounts: scopeNames)
        askHistory.append(turn)
        persistAsk()

        Task { @MainActor in
            guard !targets.isEmpty else {
                self.finishAsk(turn.id, answer: "还没有选择账号。点左下角选一个，或选「所有账号」。")
                return
            }

            var collected: [Message] = []
            for accountID in targets {
                let inboxes = mailboxes.filter { $0.accountID == accountID && $0.role == .inbox }
                for box in inboxes {
                    let rows = (try? await store.messages(mailboxID: box.id, limit: 6)) ?? []
                    collected.append(contentsOf: rows)
                }
            }
            collected = Array(collected.prefix(15))

            guard !collected.isEmpty else {
                self.finishAsk(turn.id, answer: "选中的账号里没有邮件。")
                return
            }

            let context = collected.map { message in
                let account = accounts.first { $0.id == message.accountID }?.name ?? ""
                return "· [\(account)] \(message.displaySender)｜\(message.subject)｜\(message.date.formatted(date: .numeric, time: .shortened))\n  \(message.preview)"
            }.joined(separator: "\n")

            let prompt = """
            操作范围：\(scopeText)
            邮件内容（\(collected.count) 封）：
            \(context)

            用户问题：\(question)
            """

            do {
                let text = try await AIService.chat(
                    provider: provider,
                    system: prefs.systemPrompt(styleSamples: sentSamples),
                    user: prompt
                )
                self.finishAsk(turn.id, answer: text)
            } catch {
                self.finishAsk(turn.id, answer: "调用失败：\(error.localizedDescription)")
            }
        }
    }

    private func appendAsk(question: String, answer: String) {
        askHistory.append(AskTurn(question: question, answer: answer))
        persistAsk()
    }

    /// 重跑某条提问：保留问题，重新生成回答（覆盖原来的）。
    /// 传 `question` 时先改写问题再重跑——用户在气泡里编辑后点「重跑」走这条。
    func rerunAsk(_ id: String, question newQuestion: String? = nil) async {
        guard !askBusy,
              let index = askHistory.firstIndex(where: { $0.id == id }) else { return }

        if let newQuestion {
            let trimmed = newQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { askHistory[index].question = trimmed }
        }

        let question = askHistory[index].question
        askHistory[index].answer = ""     // 先清空，界面显示「正在读你的邮箱…」
        askBusy = true
        defer { askBusy = false }

        do {
            let answer = try await runAsk(question)
            if let current = askHistory.firstIndex(where: { $0.id == id }) {
                askHistory[current].answer = answer
            }
        } catch {
            if let current = askHistory.firstIndex(where: { $0.id == id }) {
                askHistory[current].answer = "调用失败：\(error.localizedDescription)"
            }
        }
        persistAsk()
    }

    private func finishAsk(_ id: String, answer: String) {
        if let index = askHistory.firstIndex(where: { $0.id == id }) {
            askHistory[index].answer = answer
        }
        persistAsk()
        askBusy = false
    }

    // MARK: - 历史记录

    private func loadAskHistory() {
        guard let data = UserDefaults.standard.data(forKey: askStorageKey),
              let decoded = try? JSONDecoder().decode([AskTurn].self, from: data) else { return }
        askHistory = decoded
    }

    private func persistAsk() {
        if askHistory.count > 200 {
            askHistory = Array(askHistory.suffix(200))
        }
        if let data = try? JSONEncoder().encode(askHistory) {
            UserDefaults.standard.set(data, forKey: askStorageKey)
        }
    }

    func deleteAskTurn(_ id: String) {
        askHistory.removeAll { $0.id == id }
        askSelected.remove(id)
        persistAsk()
    }

    func toggleAskSelect(_ id: String) {
        if askSelected.contains(id) {
            askSelected.remove(id)
        } else {
            askSelected.insert(id)
        }
    }

    func deleteSelectedAsks() {
        askHistory.removeAll { askSelected.contains($0.id) }
        askSelected = []
        askSelectMode = false
        persistAsk()
    }

    func clearAskHistory() {
        askHistory = []
        askSelected = []
        askSelectMode = false
        persistAsk()
    }

    var activeAccountID: String? {
        guard let id = selectedMailboxID else { return nil }
        if SmartBox(rawValue: id) != nil { return nil }
        return mailboxes.first { $0.id == id }?.accountID
    }

    var askScopeTitle: String {
        if askAllAccounts { return "所有账号" }
        let names = accounts.filter { askAccounts.contains($0.id) }.map(\.name)
        if names.isEmpty { return "选择账号" }
        if names.count == 1 { return names[0] }
        return "\(names.count) 个账号"
    }

    /// 胶囊里逐行展示的名称
    var askScopeNames: [String] {
        if askAllAccounts { return ["所有账号"] }
        let names = accounts.filter { askAccounts.contains($0.id) }.map(\.name)
        return names.isEmpty ? ["选择账号"] : names
    }

    func toggleAskAccount(_ id: String) {
        askAllAccounts = false
        if askAccounts.contains(id) {
            askAccounts.remove(id)
        } else {
            askAccounts.insert(id)
        }
    }

    func toggleAllAccounts() {
        askAllAccounts.toggle()
        // 「所有账号」是独立选项，不往下面的多选里塞 ID
        if askAllAccounts {
            askAccounts = []
        }
    }
}
