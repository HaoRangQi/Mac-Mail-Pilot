import Combine
import Foundation

enum ProviderKind: String, Codable, CaseIterable, Identifiable {
    // 顺序即界面顺序：本地优先
    case ollama
    case openai
    case anthropic

    var id: String { rawValue }

    var label: String {
        switch self {
        case .openai: return "OpenAI 兼容"
        case .anthropic: return "Anthropic"
        case .ollama: return "Ollama 本地"
        }
    }

    var defaultBase: String {
        switch self {
        case .openai: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com"
        case .ollama: return "http://127.0.0.1:11434"
        }
    }

    var defaultModel: String {
        switch self {
        case .openai: return "gpt-4o-mini"
        case .anthropic: return "claude-sonnet-4-5"
        case .ollama: return "qwen2.5:7b"
        }
    }

    var isLocal: Bool { self == .ollama }
}

struct APIKey: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var label: String = ""
    var value: String = ""
    var enabled: Bool = true

    var masked: String {
        guard value.count > 6 else { return String(repeating: "•", count: max(4, value.count)) }
        return value.prefix(2) + "****" + value.suffix(4)
    }
}

struct ModelMeta: Codable, Hashable {
    enum Purpose: String, Codable, CaseIterable, Identifiable {
        case chat = "对话"
        case image = "图像生成"
        case imageEdit = "图像编辑"

        var id: String { rawValue }

        var detail: String {
            switch self {
            case .chat: return "使用服务商的文本 API"
            case .image: return "根据提示词生成图片"
            case .imageEdit: return "接收输入图片并返回编辑后的图片"
            }
        }
    }

    var displayName: String = ""
    var group: String = ""
    var purpose: Purpose = .chat
    var contextWindow: Int? = nil
    var maxOutput: Int? = nil
}

struct AIProvider: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var name: String
    var kind: ProviderKind
    var baseURL: String
    /// 旧版单密钥字段，迁移后清空；保留是为了能解码旧配置
    var apiKey: String = ""
    /// 多密钥
    var keys: [APIKey]? = nil
    var models: [String] = []
    /// 服务端返回的完整目录（同步后缓存），供挑选
    var availableModels: [String]? = nil
    /// 手动添加时填的元信息（名称 / 分组 / 用途 / 窗口），可选以兼容旧配置
    var modelMeta: [String: ModelMeta]? = nil
    var selectedModel: String = ""
    var enabled: Bool = true
    /// 供应商级可信。nil = 用户没表过态，一律按不可信处理
    var trusted: Bool? = nil
    /// 模型级信任覆盖：true / false 覆盖供应商设置；键不存在则继承供应商
    var modelTrust: [String: Bool]? = nil
    var avatarImage: Data? = nil
    var avatarSeed: Int? = nil

    static func make(kind: ProviderKind) -> AIProvider {
        AIProvider(
            name: kind.label,
            kind: kind,
            baseURL: kind.defaultBase,
            models: [kind.defaultModel],
            selectedModel: kind.defaultModel
        )
    }

    var initial: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return String(trimmed.prefix(1)).uppercased()
    }

    var allKeys: [APIKey] { keys ?? [] }

    var enabledKeys: [APIKey] { allKeys.filter(\.enabled) }

    /// 界面上展示的主密钥
    var primaryKey: APIKey? { enabledKeys.first ?? allKeys.first }

    var hasKey: Bool { !enabledKeys.isEmpty || !apiKey.isEmpty }

    func displayName(for modelID: String) -> String {
        let name = modelMeta?[modelID]?.displayName ?? ""
        return name.isEmpty ? modelID : name
    }

    func groupName(for modelID: String) -> String {
        modelMeta?[modelID]?.group ?? ""
    }

    func isChatModel(_ modelID: String) -> Bool {
        if let purpose = modelMeta?[modelID]?.purpose {
            return purpose == .chat
        }
        return ModelFilter.isChat(modelID)
    }

    // MARK: - 信任

    /// 供应商是否被标记为可信（未表态 = 不可信）
    var isTrustedProvider: Bool { trusted ?? false }

    /// 某个模型是否可信。
    /// 本地模型恒可信——数据不出本机，没有外发风险，不该要求用户去「信任」它。
    func isTrusted(_ modelID: String) -> Bool {
        if kind.isLocal { return true }
        if let override = modelTrust?[modelID] { return override }
        return isTrustedProvider
    }

    /// 模型级覆盖状态：nil 表示继承供应商
    func trustOverride(_ modelID: String) -> Bool? {
        modelTrust?[modelID]
    }

    var trustedModelCount: Int {
        models.filter { isTrusted($0) }.count
    }
}

/// 配置存 UserDefaults，密钥只在本机。
final class AISettingsStore: ObservableObject {
    @Published var providers: [AIProvider] {
        didSet { persist() }
    }

    private let storageKey = "mailpilot.ai.providers"

    init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([AIProvider].self, from: data),
           !decoded.isEmpty {
            providers = decoded
            migrateLegacyKeys()
        } else {
            providers = [
                AIProvider(
                    name: "DeepSeek",
                    kind: .openai,
                    baseURL: "https://api.deepseek.com/v1",
                    models: ["deepseek-chat", "deepseek-reasoner"],
                    selectedModel: "deepseek-chat"
                )
            ]
        }
    }

    /// 把旧的单 apiKey 迁移成一条密钥记录
    private func migrateLegacyKeys() {
        var changed = false
        for index in providers.indices where (providers[index].keys ?? []).isEmpty {
            let legacy = providers[index].apiKey
            guard !legacy.isEmpty else { continue }
            providers[index].keys = [APIKey(label: "默认", value: legacy)]
            providers[index].apiKey = ""
            changed = true
        }
        if changed { persist() }
    }

    var activeProvider: AIProvider? {
        providers.first {
            $0.enabled && !$0.selectedModel.isEmpty && ($0.kind.isLocal || $0.hasKey)
        }
    }

    /// 顶栏快速切换模型：写入选中模型，并把它所在服务商提到首位
    /// （`activeProvider` 取第一个可用项，所以顺序就是优先级）
    func selectModel(providerID: String, model: String) {
        guard let index = providers.firstIndex(where: { $0.id == providerID }) else { return }
        providers[index].selectedModel = model
        guard index != 0 else { return }
        let provider = providers.remove(at: index)
        providers.insert(provider, at: 0)
    }

    /// 可用于对话的服务商及其模型，供快速切换面板分组展示
    var selectableGroups: [(provider: AIProvider, models: [String])] {
        providers
            .filter { $0.enabled && ($0.kind.isLocal || $0.hasKey) }
            .map { provider in
                (provider, provider.models.filter { provider.isChatModel($0) })
            }
            .filter { !$0.models.isEmpty }
    }

    var isConfigured: Bool { activeProvider != nil }

    func add(_ kind: ProviderKind) {
        providers.append(AIProvider.make(kind: kind))
    }

    func remove(id: String) {
        providers.removeAll { $0.id == id }
    }

    func update(id: String, _ mutate: (inout AIProvider) -> Void) {
        guard let index = providers.firstIndex(where: { $0.id == id }) else { return }
        mutate(&providers[index])
    }

    // MARK: - 信任

    func setProviderTrusted(_ providerID: String, _ value: Bool) {
        update(id: providerID) { $0.trusted = value }
    }

    /// 传 nil 表示清除覆盖、回到「继承供应商」
    func setModelTrust(_ providerID: String, model: String, _ value: Bool?) {
        update(id: providerID) { provider in
            var map = provider.modelTrust ?? [:]
            if let value {
                map[model] = value
            } else {
                map.removeValue(forKey: model)
            }
            provider.modelTrust = map.isEmpty ? nil : map
        }
    }

    /// 当前生效的 provider + model 是否可信
    var activeModelTrusted: Bool {
        guard let provider = activeProvider else { return false }
        return provider.isTrusted(provider.selectedModel)
    }

    // MARK: - 密钥

    func addKey(providerID: String, label: String, value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(id: providerID) {
            var list = $0.keys ?? []
            list.append(APIKey(label: label.trimmingCharacters(in: .whitespaces), value: trimmed))
            $0.keys = list
            $0.apiKey = ""
        }
    }

    func updateKey(providerID: String, keyID: String, label: String, value: String) {
        update(id: providerID) {
            guard var list = $0.keys, let index = list.firstIndex(where: { $0.id == keyID }) else { return }
            list[index].label = label
            list[index].value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            $0.keys = list
        }
    }

    func toggleKey(providerID: String, keyID: String, enabled: Bool) {
        update(id: providerID) {
            guard var list = $0.keys, let index = list.firstIndex(where: { $0.id == keyID }) else { return }
            list[index].enabled = enabled
            $0.keys = list
        }
    }

    func deleteKey(providerID: String, keyID: String) {
        update(id: providerID) {
            guard var list = $0.keys else { return }
            list.removeAll { $0.id == keyID }
            $0.keys = list
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(providers) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}

// MARK: - 调用

// MARK: - 模型筛选

enum ModelFilter {
    /// 明显不是对话模型的关键词：图像 / 语音 / 向量 / 视频 / 审核
    static let nonChatHints = [
        "dall-e", "dalle", "gpt-image", "image", "flux", "stable-diffusion", "sdxl",
        "midjourney", "imagen", "cogview", "seedream", "kolors", "wanx-image",
        "whisper", "tts", "audio", "speech", "voice", "suno", "music",
        "embed", "bge-", "gte-", "rerank", "moderation", "guard", "clip-",
        "veo", "kling", "sora", "video", "hunyuan-video", "sam-", "ocr",
    ]

    static func isChat(_ modelID: String) -> Bool {
        let lower = modelID.lowercased()
        return !nonChatHints.contains { lower.contains($0) }
    }
}

enum AIError: LocalizedError {    case notConfigured
    case noKey
    case http(Int, String)
    case empty
    /// 响应能解析但里面没有可用文本。带诊断信息，别让用户只看到「失败」两个字
    case emptyResponse(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "未配置可用的模型"
        case .noKey: return "没有启用的 API 密钥"
        case .http(let code, let body): return "HTTP \(code)：\(body.prefix(200))"
        case .empty: return "模型没有返回内容"
        case .emptyResponse(let detail): return "模型没有返回内容（\(detail)）"
        }
    }
}

enum AIService {

    /// 检测对话的默认问题
    static let defaultTestPrompt = "你的模型信息是？数据截止日期是？"

    // MARK: - 对话

    static func chat(provider: AIProvider, system: String, user: String) async throws -> String {
        try await chat(provider: provider, model: provider.selectedModel, system: system, user: user)
    }

    static func chat(provider: AIProvider, model: String, system: String, user: String) async throws -> String {
        guard provider.enabled, !model.isEmpty else { throw AIError.notConfigured }

        let keys = keyCandidates(provider)
        guard !keys.isEmpty else { throw AIError.noKey }

        let spec = chatPath(provider.kind)
        guard let url = endpoint(provider.baseURL, spec.path, needsV1: spec.needsV1) else {
            throw AIError.notConfigured
        }
        let body = chatBody(kind: provider.kind, model: model, system: system, user: user)

        var lastError: Error = AIError.notConfigured
        for key in keys {
            do {
                let data = try await send(url: url, method: "POST", headers: authHeaders(provider.kind, key), body: body)
                return try parseChat(data, kind: provider.kind)
            } catch let error as AIError {
                if case .http(let code, _) = error, code == 401 || code == 403 || code == 429 {
                    lastError = error
                    continue   // 换下一条密钥重试
                }
                throw error
            }
        }
        throw lastError
    }

    // MARK: - 带工具调用的对话

    /// 支持 tool calling 的对话。
    ///
    /// 循环：发出请求 → 模型若要调工具就交给 `execute` 执行 → 结果回传 → 再请求，
    /// 直到模型给出最终文本或达到轮数上限。`maxRounds` 防止模型无限调工具。
    ///
    /// 目前只实现 OpenAI 兼容协议（`.openai` 与 `.ollama`），Anthropic 的 tools 格式不同，后续再加。
    static func chatWithTools(provider: AIProvider,
                              model: String,
                              system: String,
                              user: String,
                              tools: [[String: Any]],
                              maxRounds: Int = 4,
                              execute: @escaping (ToolCall) async throws -> String) async throws -> String {
        guard provider.enabled, !model.isEmpty else { throw AIError.notConfigured }

        let keys = keyCandidates(provider)
        guard !keys.isEmpty else { throw AIError.noKey }

        let spec = chatPath(provider.kind)
        guard let url = endpoint(provider.baseURL, spec.path, needsV1: spec.needsV1) else {
            throw AIError.notConfigured
        }

        var messages: [[String: Any]] = [
            ["role": "system", "content": system],
            ["role": "user", "content": user],
        ]

        var lastError: Error = AIError.notConfigured
        for key in keys {
            do {
                // 模型偶尔会「只想不做」：这一轮既没有工具调用、也没有正文
                // （reasoning 模型把 token 全花在思考过程里时很常见）。
                // 这种情况重试一次并强制它直接回答，比直接报错有用得多。
                var forceNoTools = false
                var emptyRetried = false

                for _ in 0..<maxRounds {
                    var body: [String: Any] = [
                        "model": model,
                        "messages": messages,
                        "temperature": 0.4,
                        "stream": false,
                    ]
                    if !tools.isEmpty, !forceNoTools { body["tools"] = tools }
                    if forceNoTools { body["tool_choice"] = "none" }

                    let data = try await send(url: url, method: "POST",
                                              headers: authHeaders(provider.kind, key), body: body)
                    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let choice = (json["choices"] as? [[String: Any]])?.first,
                          let message = choice["message"] as? [String: Any] else {
                        throw AIError.empty
                    }

                    let rawCalls = message["tool_calls"] as? [[String: Any]] ?? []
                    if rawCalls.isEmpty {
                        if let content = messageText(message) { return content }

                        if !emptyRetried {
                            emptyRetried = true
                            forceNoTools = true
                            messages.append([
                                "role": "user",
                                "content": "请直接给出最终答案，不要调用任何工具，也不要只输出思考过程。",
                            ])
                            continue
                        }
                        throw AIError.emptyResponse(emptyDiagnostic(json, choice, message))
                    }

                    // assistant 的原始消息必须原样回传，OpenAI 协议要求上下文里有这段 tool_calls
                    messages.append(message)

                    for raw in rawCalls {
                        let callID = raw["id"] as? String ?? UUID().uuidString
                        guard let function = raw["function"] as? [String: Any],
                              let name = function["name"] as? String,
                              let tool = MailTool(rawValue: name) else {
                            messages.append(["role": "tool", "tool_call_id": callID,
                                             "content": "工具不存在或无法解析"])
                            continue
                        }

                        var arguments: [String: Any] = [:]
                        if let argsText = function["arguments"] as? String,
                           !argsText.isEmpty,
                           let argsData = argsText.data(using: .utf8),
                           let parsed = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] {
                            arguments = parsed
                        }

                        let result: String
                        do {
                            result = try await execute(ToolCall(id: callID, tool: tool, arguments: arguments))
                        } catch {
                            result = "执行失败：\(error.localizedDescription)"
                        }
                        messages.append(["role": "tool", "tool_call_id": callID, "content": result])
                    }
                }
                throw AIError.empty   // 轮数用尽，模型还在要工具
            } catch let error as AIError {
                if case .http(let code, _) = error, code == 401 || code == 403 || code == 429 {
                    lastError = error
                    continue
                }
                throw error
            }
        }
        throw lastError
    }

    // MARK: - 模型列表

    static func fetchModels(provider: AIProvider) async throws -> [String] {
        let keys = keyCandidates(provider)
        guard !keys.isEmpty else { throw AIError.noKey }

        let spec = modelsPath(provider.kind)
        guard let url = endpoint(provider.baseURL, spec.path, needsV1: spec.needsV1) else {
            throw AIError.notConfigured
        }

        var lastError: Error = AIError.notConfigured
        for key in keys {
            do {
                let data = try await send(url: url, method: "GET", headers: authHeaders(provider.kind, key), body: nil)
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw AIError.empty
                }
                var models: [String] = []
                if let list = json["data"] as? [[String: Any]] {
                    models = list.compactMap { $0["id"] as? String }
                } else if let list = json["models"] as? [[String: Any]] {
                    models = list.compactMap { $0["name"] as? String ?? $0["id"] as? String }
                }
                return models.sorted()
            } catch let error as AIError {
                if case .http(let code, _) = error, code == 401 || code == 403 || code == 429 {
                    lastError = error
                    continue
                }
                throw error
            }
        }
        throw lastError
    }

    // MARK: - 请求构造

    /// 从 message 里取正文。兼容三种写法：
    /// 1. `content` 是字符串（标准）
    /// 2. `content` 是分段数组（部分兼容实现）
    /// 3. `reasoning_content` 有内容但 `content` 为空 —— 这种**不算答案**，交给重试逻辑处理
    private static func messageText(_ message: [String: Any]) -> String? {
        if let text = message["content"] as? String,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        if let parts = message["content"] as? [[String: Any]] {
            let text = parts.compactMap { $0["text"] as? String }.joined()
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        }
        return nil
    }

    /// 空响应时给一句人话，说明到底是截断了、还是只思考了没输出
    private static func emptyDiagnostic(_ json: [String: Any],
                                        _ choice: [String: Any],
                                        _ message: [String: Any]) -> String {
        var parts: [String] = []
        if let finish = choice["finish_reason"] as? String, !finish.isEmpty {
            parts.append(finish == "length" ? "输出被长度限制截断" : "finish_reason=\(finish)")
        }
        if let reasoning = message["reasoning_content"] as? String, !reasoning.isEmpty {
            parts.append("模型只输出了思考过程（\(reasoning.count) 字）")
        }
        if let usage = json["usage"] as? [String: Any],
           let out = usage["completion_tokens"] as? Int {
            parts.append("completion_tokens=\(out)")
        }
        return parts.isEmpty ? "响应里没有可用的文本" : parts.joined(separator: "；")
    }

    private static func keyCandidates(_ provider: AIProvider) -> [String] {
        if provider.kind.isLocal { return [""] }
        let values = provider.enabledKeys.map(\.value).filter { !$0.isEmpty }
        if !values.isEmpty { return values }
        if !provider.apiKey.isEmpty { return [provider.apiKey] }
        return []
    }

    private static func chatPath(_ kind: ProviderKind) -> (path: String, needsV1: Bool) {
        switch kind {
        case .openai: return ("/chat/completions", true)
        case .anthropic: return ("/messages", true)
        case .ollama: return ("/api/chat", false)
        }
    }

    private static func modelsPath(_ kind: ProviderKind) -> (path: String, needsV1: Bool) {
        switch kind {
        case .openai: return ("/models", true)
        case .anthropic: return ("/models", true)
        case .ollama: return ("/api/tags", false)
        }
    }

    private static func authHeaders(_ kind: ProviderKind, _ key: String) -> [String: String] {
        var headers = ["Content-Type": "application/json"]
        switch kind {
        case .openai:
            if !key.isEmpty { headers["Authorization"] = "Bearer \(key)" }
        case .anthropic:
            if !key.isEmpty { headers["x-api-key"] = key }
            headers["anthropic-version"] = "2023-06-01"
        case .ollama:
            break
        }
        return headers
    }

    private static func chatBody(kind: ProviderKind, model: String, system: String, user: String) -> [String: Any] {
        switch kind {
        case .openai, .ollama:
            return [
                "model": model,
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user", "content": user],
                ],
                "temperature": 0.4,
                "stream": false,
            ]
        case .anthropic:
            return [
                "model": model,
                // 1024 对 reasoning 模型太紧，思考没写完就被截断，正文直接为空
                "max_tokens": 4096,
                "system": system,
                "messages": [["role": "user", "content": user]],
            ]
        }
    }

    private static func send(url: URL, method: String, headers: [String: String], body: [String: Any]?) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 90
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw AIError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    private static func parseChat(_ data: Data, kind: ProviderKind) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.empty
        }
        let text: String?
        switch kind {
        case .openai:
            text = ((json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
        case .anthropic:
            text = (json["content"] as? [[String: Any]])?.first?["text"] as? String
        case .ollama:
            text = (json["message"] as? [String: Any])?["content"] as? String
        }
        guard let text, !text.isEmpty else { throw AIError.empty }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 地址

    /// 自动补齐 /v1：用户填 `https://api.deepseek.com` 或 `.../v1` 都能用。
    private static func endpoint(_ base: String, _ path: String, needsV1: Bool) -> URL? {
        var raw = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while raw.hasSuffix("/") { raw.removeLast() }
        // 用户直接把完整端点粘进来时，原样使用（必须在补 /v1 之前判断）
        if raw.hasSuffix(path) { return URL(string: raw) }
        return URL(string: normalizedBase(raw, needsV1: needsV1) + path)
    }

    /// 规范化后的 base，供「检测」成功后回填到界面
    static func normalizedBase(_ raw: String, kind: ProviderKind) -> String {
        normalizedBase(raw, needsV1: !kind.isLocal)
    }

    /// 给界面用的「实际请求路径」预览
    static func previewRequestURL(base: String, kind: ProviderKind) -> String {
        var raw = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while raw.hasSuffix("/") { raw.removeLast() }
        guard !raw.isEmpty else { return "填写根地址后显示实际请求路径" }

        let spec = chatPath(kind)
        if raw.hasSuffix(spec.path) { return raw }
        return normalizedBase(raw, needsV1: spec.needsV1) + spec.path
    }

    private static func normalizedBase(_ raw: String, needsV1: Bool) -> String {
        var b = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") { b.removeLast() }
        guard needsV1 else { return b }
        if b.hasSuffix("/v1") { return b }
        return b + "/v1"
    }
}
