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
        // 本地不预置模型：用户机器上装了什么只有 /api/tags 知道，猜一个只会报 model not found
        case .ollama: return ""
        }
    }

    var isLocal: Bool { self == .ollama }

    /// 内置服务商：Ollama 恒存在、不可删除，新增服务商时也不再提供。
    /// 本地优先是这个 App 的默认姿态，不该让用户先手动建一个才能用。
    var isBuiltin: Bool { self == .ollama }
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

    /// 内置 Ollama 用固定 id，重启不会换身份。
    /// 判断「是不是内置」仍然看 kind——老配置里已有的 Ollama 保留原 id
    /// （翻译路由存的是 id，改 id 会把用户配好的翻译路由打断）。
    static let builtinLocalID = "builtin.ollama"

    /// 内置 Ollama：模型列表留空，等「同步模型」从 /api/tags 拉真实的。
    static var builtinLocal: AIProvider {
        AIProvider(
            id: builtinLocalID,
            name: ProviderKind.ollama.label,
            kind: .ollama,
            baseURL: ProviderKind.ollama.defaultBase,
            models: [],
            selectedModel: ""
        )
    }

    var isBuiltin: Bool { kind.isBuiltin }

    /// 内置 Ollama 的推荐模型：1B 参数、约 672 MB，跑得动就很流畅。
    /// 只做推荐展示，不写进默认配置——用户未必 pull 过，硬塞一个不存在的模型只会报错。
    static let recommendedLocalModel = "minicpm-v-4.7-1b-heretic"

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

    /// 供应商是否被标记为可信。
    /// 未表态时：本地默认可信（数据不出本机），第三方默认不可信。
    /// 本地这一档可以关掉——用户可能连远程 Ollama，或者就是想让本地模型也走脱敏流程。
    var isTrustedProvider: Bool {
        if let trusted { return trusted }
        return kind.isLocal
    }

    /// 某个模型是否可信
    func isTrusted(_ modelID: String) -> Bool {
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
            providers = []
        }
        ensureBuiltinLocal()
        dropLegacyPlaceholderModel()
    }

    /// 内置 Ollama 恒存在，用户不用自己新建。
    /// 追加在末尾而不是插到首位——`activeProvider` 取第一个可用项，
    /// 插到前面会把老用户已经配好的云端服务商顶掉。
    /// 列表里想让它排第一是渲染层的事（`displayProviders`），不动数组顺序。
    private func ensureBuiltinLocal() {
        guard !providers.contains(where: { $0.isBuiltin }) else { return }
        providers.append(.builtinLocal)
    }

    /// 0.2.44-0.2.45 给内置 Ollama 塞过一个 `qwen2.5:7b` 占位模型，
    /// 那只是个名字，用户机器上多半没装。只在「完全等于出厂状态」时清掉，避免误删用户自己加的模型。
    private func dropLegacyPlaceholderModel() {
        for index in providers.indices where providers[index].isBuiltin {
            let provider = providers[index]
            guard provider.availableModels == nil,
                  provider.selectedModel == Self.legacyPlaceholderModel,
                  provider.models == [Self.legacyPlaceholderModel] else { continue }
            providers[index].models = []
            providers[index].selectedModel = ""
        }
    }

    private static let legacyPlaceholderModel = "qwen2.5:7b"

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

    /// 可用于对话的服务商及其模型，供快速切换面板分组展示。
    /// 内置 Ollama 恒定排第一，其余保持数组原序——展示顺序，不影响 `activeProvider` 的优先级。
    var selectableGroups: [(provider: AIProvider, models: [String])] {
        let available = providers.filter { $0.enabled && ($0.kind.isLocal || $0.hasKey) }
        let ordered = available.filter(\.isBuiltin) + available.filter { !$0.isBuiltin }
        return ordered
            .map { provider in
                (provider, provider.models.filter { provider.isChatModel($0) })
            }
            .filter { !$0.models.isEmpty }
    }

    var isConfigured: Bool { activeProvider != nil }

    func remove(id: String) {
        // 内置 Ollama 不可删除：不想要可以关掉开关。
        // 拦在 store 层而不是只藏按钮——以后多一个删除入口也绕不过去。
        guard let provider = providers.first(where: { $0.id == id }), !provider.isBuiltin else { return }
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

/// 一次问答累计的 token 用量。各家协议字段不同，统一在这里累加
final class UsageBox {
    private(set) var input = 0
    private(set) var output = 0

    var total: Int { input + output }

    func add(input newInput: Int, output newOutput: Int) {
        input += newInput
        output += newOutput
    }
}

enum AIService {

    /// 检测对话的默认问题
    static let defaultTestPrompt = "你的模型信息是？数据截止日期是？"

    // MARK: - 对话

    static func chat(provider: AIProvider, system: String, user: String) async throws -> String {
        try await chat(provider: provider, model: provider.selectedModel, system: system, user: user)
    }

    /// `onDelta` 非空时走流式：每收到一段就回调**到目前为止的完整文本**（不是增量），
    /// 调用方可以直接覆盖显示。流式拿不到东西（网关不认 stream 等）时自动退回非流式，
    /// 不会让用户多看到一次报错。
    static func chat(provider: AIProvider,
                     model: String,
                     system: String,
                     user: String,
                     onDelta: ((String) -> Void)? = nil) async throws -> String {
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
                if let onDelta {
                    var streamBody = body
                    streamBody["stream"] = true
                    if provider.kind == .openai {
                        // 让最后一块带上 usage，否则流式回答的 token 用量永远是 0
                        streamBody["stream_options"] = ["include_usage": true]
                    }
                    do {
                        if let text = try await streamPlainChat(provider: provider, url: url,
                                                                key: key, body: streamBody,
                                                                onDelta: onDelta) {
                            return text
                        }
                    } catch let error as AIError {
                        // 密钥问题必须往上走，换下一条；其余（网关不认 stream / 解析不了）退非流式
                        if case .http(let code, _) = error, code == 401 || code == 403 || code == 429 {
                            throw error
                        }
                    } catch {
                        // 传输层异常：同样退非流式
                    }
                    // 清掉已经显示出来的半截流式文本，避免和非流式结果拼在一起
                    onDelta("")
                }
                let data = try await send(url: url, method: "POST",
                                          headers: authHeaders(provider.kind, key), body: body,
                                          timeout: localTimeout(provider.kind))
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

    // MARK: - 流式底层

    /// 流式请求的公共通道：逐行读 SSE / NDJSON，读到的每一行交给 `onLine`。
    /// 非 200 在这里就变成 AIError.http，和 `send` 保持同一套错误口径。
    private static func openStream(url: URL,
                                   headers: [String: String],
                                   body: [String: Any],
                                   timeout: TimeInterval,
                                   onLine: (String) throws -> Void) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            // 错误体通常很小，读到这里就够拼出可读的报错了
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count >= 8192 { break }
            }
            throw AIError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        for try await line in bytes.lines {
            try onLine(line)
        }
    }

    /// SSE 的 `data: {...}` 行；注释行和其他字段直接忽略
    private static func sseJSON(_ line: String) -> [String: Any]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data:") else { return nil }
        let payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]", !payload.isEmpty,
              let data = payload.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// 流里出现的服务端错误要当场抛出去，不能当成「没有内容」静默跳过
    private static func streamError(_ json: [String: Any]) -> AIError? {
        if let error = json["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "\(error)"
            return .emptyResponse("服务端报错：\(message.prefix(160))")
        }
        if let error = json["error"] as? String {
            return .emptyResponse("服务端报错：\(error.prefix(160))")
        }
        if (json["type"] as? String) == "error" {
            let message = (json["error"] as? [String: Any])?["message"] as? String ?? "未知错误"
            return .emptyResponse("服务端报错：\(message.prefix(160))")
        }
        return nil
    }

    /// 一轮流式响应的归一化结果：两家协议拼出来的东西不一样，
    /// 上层循环只关心「文本」和「要调哪些工具」
    private struct StreamedRound {
        var received = false
        var text = ""
        /// OpenAI / Ollama：可直接回传的 assistant 消息
        var message: [String: Any] = [:]
        /// Anthropic：可直接回传的 content 块
        var content: [[String: Any]] = []
        var toolCalls: [[String: Any]] = []
        /// Anthropic 的结束原因，只用于空回答时的诊断
        var stopReason: String?
    }

    /// 不带工具的流式对话。拿不到任何文本时返回 nil，让调用方退回非流式。
    private static func streamPlainChat(provider: AIProvider,
                                        url: URL,
                                        key: String,
                                        body: [String: Any],
                                        onDelta: (String) -> Void) async throws -> String? {
        let round: StreamedRound
        switch provider.kind {
        case .openai:
            round = try await streamOpenAI(url: url, key: key, body: body, usage: nil, onDelta: onDelta)
        case .ollama:
            round = try await streamOllama(url: url, key: key, body: body, usage: nil, onDelta: onDelta)
        case .anthropic:
            round = try await streamAnthropic(url: url, key: key, body: body, usage: nil, onDelta: onDelta)
        }
        let text = round.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// OpenAI 兼容协议的流式解析。
    /// 工具调用是**分片**下发的：同一个 index 的 `arguments` 要一段段拼起来，
    /// 拼完才是合法 JSON——直接解析第一片必然失败。
    private static func streamOpenAI(url: URL,
                                     key: String,
                                     body: [String: Any],
                                     usage: UsageBox?,
                                     onDelta: (String) -> Void) async throws -> StreamedRound {
        var round = StreamedRound()
        var slots: [Int: [String: Any]] = [:]
        var order: [Int] = []
        onDelta("")

        try await openStream(url: url, headers: authHeaders(.openai, key),
                             body: body, timeout: localTimeout(.openai)) { line in
            guard let json = sseJSON(line) else { return }
            if let error = streamError(json) { throw error }

            if let u = json["usage"] as? [String: Any] {
                usage?.add(input: u["prompt_tokens"] as? Int ?? 0,
                           output: u["completion_tokens"] as? Int ?? 0)
            }
            guard let choices = json["choices"] as? [[String: Any]] else { return }
            round.received = true
            guard let delta = choices.first?["delta"] as? [String: Any] else { return }

            if let piece = delta["content"] as? String, !piece.isEmpty {
                round.text += piece
                onDelta(round.text)
            }
            guard let rawCalls = delta["tool_calls"] as? [[String: Any]] else { return }
            for item in rawCalls {
                let index = item["index"] as? Int ?? (order.last ?? 0)
                if slots[index] == nil {
                    order.append(index)
                    slots[index] = ["id": "", "name": "", "arguments": ""]
                }
                var slot = slots[index] ?? [:]
                if let id = item["id"] as? String, !id.isEmpty { slot["id"] = id }
                if let function = item["function"] as? [String: Any] {
                    if let name = function["name"] as? String, !name.isEmpty { slot["name"] = name }
                    if let args = function["arguments"] as? String {
                        slot["arguments"] = (slot["arguments"] as? String ?? "") + args
                    }
                }
                slots[index] = slot
            }
        }

        round.toolCalls = order.sorted().compactMap { index in
            guard let slot = slots[index],
                  let name = slot["name"] as? String, !name.isEmpty else { return nil }
            let id = (slot["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
            return [
                "id": id,
                "type": "function",
                "function": ["name": name, "arguments": slot["arguments"] as? String ?? "{}"],
            ]
        }
        var message: [String: Any] = [
            "role": "assistant",
            "content": round.text.isEmpty ? NSNull() : round.text,
        ]
        if !round.toolCalls.isEmpty { message["tool_calls"] = round.toolCalls }
        round.message = message
        return round
    }

    /// Ollama 的流是 NDJSON：一行一个完整 JSON，工具调用一次给全，不需要拼装
    private static func streamOllama(url: URL,
                                     key: String,
                                     body: [String: Any],
                                     usage: UsageBox?,
                                     onDelta: (String) -> Void) async throws -> StreamedRound {
        var round = StreamedRound()
        var calls: [[String: Any]] = []
        onDelta("")

        try await openStream(url: url, headers: authHeaders(.ollama, key),
                             body: body, timeout: localTimeout(.ollama)) { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            if let error = streamError(json) { throw error }
            round.received = true

            if let message = json["message"] as? [String: Any] {
                if let piece = message["content"] as? String, !piece.isEmpty {
                    round.text += piece
                    onDelta(round.text)
                }
                if let raw = message["tool_calls"] as? [[String: Any]] {
                    calls.append(contentsOf: raw)
                }
            }
            if let input = json["prompt_eval_count"] as? Int {
                usage?.add(input: input, output: json["eval_count"] as? Int ?? 0)
            }
        }

        round.toolCalls = calls
        var message: [String: Any] = ["role": "assistant", "content": round.text]
        if !calls.isEmpty { message["tool_calls"] = calls }
        round.message = message
        return round
    }

    /// Anthropic 的流式：文本按 `text_delta` 追加，工具参数按 `input_json_delta` 拼接，
    /// 结束时要还原成和**非流式完全一样**的 content 块数组——下一轮要原样回传
    private static func streamAnthropic(url: URL,
                                        key: String,
                                        body: [String: Any],
                                        usage: UsageBox?,
                                        onDelta: (String) -> Void) async throws -> StreamedRound {
        var round = StreamedRound()
        var blocks: [Int: [String: Any]] = [:]
        var order: [Int] = []
        onDelta("")

        try await openStream(url: url, headers: authHeaders(.anthropic, key),
                             body: body, timeout: localTimeout(.anthropic)) { line in
            guard let json = sseJSON(line) else { return }
            if let error = streamError(json) { throw error }

            switch json["type"] as? String ?? "" {
            case "message_start":
                round.received = true
                // 这里只取 input；output 的最终值在 message_delta 里，两处都加会重复
                if let message = json["message"] as? [String: Any],
                   let u = message["usage"] as? [String: Any] {
                    usage?.add(input: u["input_tokens"] as? Int ?? 0, output: 0)
                }

            case "content_block_start":
                round.received = true
                guard let index = json["index"] as? Int,
                      let block = json["content_block"] as? [String: Any] else { return }
                if blocks[index] == nil { order.append(index) }
                var slot = block
                if slot["type"] as? String == "tool_use" { slot["_partial"] = "" }
                blocks[index] = slot

            case "content_block_delta":
                guard let index = json["index"] as? Int,
                      var slot = blocks[index],
                      let delta = json["delta"] as? [String: Any] else { return }
                switch delta["type"] as? String ?? "" {
                case "text_delta":
                    slot["text"] = (slot["text"] as? String ?? "") + (delta["text"] as? String ?? "")
                    blocks[index] = slot
                    round.text = order.sorted()
                        .compactMap { blocks[$0]?["text"] as? String }
                        .joined(separator: "\n")
                    onDelta(round.text)
                case "input_json_delta":
                    slot["_partial"] = (slot["_partial"] as? String ?? "") + (delta["partial_json"] as? String ?? "")
                    blocks[index] = slot
                default:
                    break
                }

            case "content_block_stop":
                guard let index = json["index"] as? Int, var slot = blocks[index] else { return }
                if slot["type"] as? String == "tool_use" {
                    if let partial = slot["_partial"] as? String,
                       let data = partial.data(using: .utf8),
                       let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        slot["input"] = input
                    } else {
                        slot["input"] = [:]
                    }
                }
                slot.removeValue(forKey: "_partial")
                blocks[index] = slot

            case "message_delta":
                // stop_reason 在这里，但 content 只用于回传给下一轮，不能混进去
                if let delta = json["delta"] as? [String: Any] {
                    round.stopReason = delta["stop_reason"] as? String
                }
                if let u = json["usage"] as? [String: Any] {
                    usage?.add(input: 0, output: u["output_tokens"] as? Int ?? 0)
                }

            default:
                break
            }
        }

        var content: [[String: Any]] = []
        for index in order.sorted() {
            guard let slot = blocks[index] else { continue }
            switch slot["type"] as? String ?? "" {
            case "text":
                let text = slot["text"] as? String ?? ""
                if !text.isEmpty { content.append(["type": "text", "text": text]) }
            case "tool_use":
                content.append([
                    "type": "tool_use",
                    "id": slot["id"] as? String ?? UUID().uuidString,
                    "name": slot["name"] as? String ?? "",
                    "input": slot["input"] as? [String: Any] ?? [:],
                ])
            default:
                break
            }
        }
        // stop_reason 只是诊断信息，不能留在 content 里回传给下一轮
        round.content = content
        round.text = content.filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
        return round
    }

    /// 一轮 OpenAI / Ollama 请求：有 onDelta 就先试流式，拿不到任何东西再退回非流式。
    /// 密钥错误必须往上抛（外层要换 key）；其余 HTTP 错误多半是网关不认 stream，静默回退。
    private static func openAIRound(kind: ProviderKind,
                                    url: URL,
                                    key: String,
                                    body: [String: Any],
                                    usage: UsageBox?,
                                    onDelta: ((String) -> Void)?) async throws
        -> (message: [String: Any], json: [String: Any]) {
        if let onDelta {
            var streamBody = body
            streamBody["stream"] = true
            if kind == .openai {
                streamBody["stream_options"] = ["include_usage": true]
            }
            do {
                let round: StreamedRound
                if kind == .ollama {
                    round = try await streamOllama(url: url, key: key, body: streamBody,
                                                   usage: usage, onDelta: onDelta)
                } else {
                    round = try await streamOpenAI(url: url, key: key, body: streamBody,
                                                   usage: usage, onDelta: onDelta)
                }
                if round.received {
                    return (round.message, ["stream": true])
                }
            } catch let error as AIError {
                if case .http(let code, _) = error, code == 401 || code == 403 || code == 429 {
                    throw error
                }
            } catch {
                // 传输层异常：退非流式
            }
            onDelta("")
        }

        let data = try await send(url: url, method: "POST",
                                  headers: authHeaders(kind, key), body: body,
                                  timeout: localTimeout(kind))
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.emptyResponse("响应不是 JSON（\(data.count) 字节）")
        }
        recordUsage(from: json, into: usage)
        guard let message = assistantMessage(from: json) else {
            throw AIError.emptyResponse(describeResponse(json, data))
        }
        return (message, json)
    }

    /// 一轮 Anthropic 请求，回退规则同 `openAIRound`
    private static func anthropicRound(url: URL,
                                       key: String,
                                       body: [String: Any],
                                       usage: UsageBox?,
                                       onDelta: ((String) -> Void)?) async throws
        -> (content: [[String: Any]], text: String, json: [String: Any]) {
        if let onDelta {
            var streamBody = body
            streamBody["stream"] = true
            do {
                let round = try await streamAnthropic(url: url, key: key, body: streamBody,
                                                      usage: usage, onDelta: onDelta)
                if round.received {
                    let text = round.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    let json: [String: Any] = ["stream": true,
                                               "stop_reason": round.stopReason ?? "未知"]
                    return (round.content, text, json)
                }
            } catch let error as AIError {
                if case .http(let code, _) = error, code == 401 || code == 403 || code == 429 {
                    throw error
                }
            } catch {
                // 传输层异常：退非流式
            }
            onDelta("")
        }

        let data = try await send(url: url, method: "POST",
                                  headers: authHeaders(.anthropic, key), body: body,
                                  timeout: localTimeout(.anthropic))
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            throw AIError.empty
        }
        recordUsage(from: json, into: usage)
        let text = content
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (content, text, json)
    }

    // MARK: - 带工具调用的对话

    /// 支持 tool calling 的对话。
    ///
    /// 循环：发出请求 → 模型若要调工具就交给 `execute` 执行 → 结果回传 → 再请求，
    /// 直到模型给出最终文本或达到轮数上限。`maxRounds` 防止模型无限调工具。
    ///
    /// OpenAI 兼容协议和 Anthropic 的 tools 格式不同，走两条实现：
    /// 前者是 `tool_calls` + `role: tool`，后者是内容块 `tool_use` / `tool_result`。
    static func chatWithTools(provider: AIProvider,
                              model: String,
                              system: String,
                              user: String,
                              tools: [[String: Any]],
                              history: [(question: String, answer: String)] = [],
                              maxRounds: Int = 4,
                              usage: UsageBox? = nil,
                              redaction: RedactionContext? = nil,
                              onDelta: ((String) -> Void)? = nil,
                              execute: @escaping (ToolCall) async throws -> String) async throws -> String {
        guard provider.enabled, !model.isEmpty else { throw AIError.notConfigured }

        if provider.kind == .anthropic {
            return try await anthropicChatWithTools(provider: provider,
                                                    model: model,
                                                    system: system,
                                                    user: user,
                                                    tools: tools,
                                                    history: history,
                                                    maxRounds: maxRounds,
                                                    usage: usage,
                                                    redaction: redaction,
                                                    onDelta: onDelta,
                                                    execute: execute)
        }

        let keys = keyCandidates(provider)
        guard !keys.isEmpty else { throw AIError.noKey }

        let spec = chatPath(provider.kind)
        guard let url = endpoint(provider.baseURL, spec.path, needsV1: spec.needsV1) else {
            throw AIError.notConfigured
        }

        // 脱敏必须是**会话级**的：工具结果与后续提问共用同一套占位符编号
        var messages: [[String: Any]] = [
            ["role": "system", "content": redaction?.mask(system) ?? system],
        ]
        // 历史问答按原样回放（同样要脱敏：存下来的是还原后的明文）
        for turn in history {
            messages.append(["role": "user", "content": redaction?.mask(turn.question) ?? turn.question])
            messages.append(["role": "assistant", "content": redaction?.mask(turn.answer) ?? turn.answer])
        }
        messages.append(["role": "user", "content": redaction?.mask(user) ?? user])

        // 换 key 重试必须从同一份上下文重来：否则上一轮插进去的提醒消息会越积越多
        let baseMessages = messages
        var lastError: Error = AIError.notConfigured
        for key in keys {
            do {
                var messages = baseMessages
                // 模型偶尔会「只想不做」：这一轮既没有工具调用、也没有正文
                // （reasoning 模型把 token 全花在思考过程里时很常见）。
                // 这种情况重试一次并强制它直接回答，比直接报错有用得多。
                var forceNoTools = false
                var emptyRetried = false
                // 轮数用尽时不能只丢一句报错：小模型很容易反复调工具，
                // 硬报错等于把前面几轮查到的内容全扔了。记下沿途的正文，
                // 最后一轮还会把工具拿掉强行要一个回答
                var lastContent: String?
                var trail: [String] = []

                for round in 0..<maxRounds {
                    let isLastRound = round == maxRounds - 1
                    if isLastRound {
                        messages.append([
                            "role": "user",
                            "content": "不要再调用工具了。请直接根据上面已经查到的信息回答；没查到就直说没查到。",
                        ])
                    }

                    var body: [String: Any] = [
                        "model": model,
                        "messages": messages,
                        "temperature": 0.4,
                        "stream": false,
                    ]
                    // 最后一轮不下发工具：留着它只会再换来一次 tool_calls
                    if !tools.isEmpty, !forceNoTools, !isLastRound { body["tools"] = tools }
                    if forceNoTools { body["tool_choice"] = "none" }
                    applyKeepAlive(&body, kind: provider.kind)

                    let step = try await openAIRound(kind: provider.kind, url: url, key: key,
                                                     body: body, usage: usage, onDelta: onDelta)
                    let message = step.message
                    let json = step.json

                    // 有些模型会「一边调工具一边写结论」，这段正文同样有用，先留着
                    if let content = messageText(message) { lastContent = content }

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
                        throw AIError.emptyResponse(emptyDiagnostic(json, message))
                    }

                    if isLastRound {
                        // 最后一轮已经不再下发工具；模型还凭记忆发出来就不再执行——
                        // 反正没有下一轮，执行了也只会白改数据（删除、发信都是真的）
                        break
                    }
                    trail.append("第 \(round + 1) 轮：" + rawCalls
                        .compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
                        .joined(separator: "、"))

                    // assistant 的原始消息必须原样回传，OpenAI 协议要求上下文里有这段 tool_calls
                    messages.append(message)

                    for raw in rawCalls {
                        let callID = raw["id"] as? String ?? UUID().uuidString
                        let function = raw["function"] as? [String: Any]
                        let name = function?["name"] as? String
                        guard let function, let name, let tool = MailTool(rawValue: name) else {
                            messages.append(toolResultMessage(kind: provider.kind,
                                                              callID: callID,
                                                              name: name ?? "",
                                                              content: "工具不存在或无法解析"))
                            continue
                        }

                        var arguments: [String: Any] = [:]
                        if let argsText = function["arguments"] as? String,
                           !argsText.isEmpty,
                           let argsData = argsText.data(using: .utf8),
                           let parsed = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] {
                            // OpenAI 兼容：arguments 是 JSON 字符串
                            arguments = parsed
                        } else if let parsed = function["arguments"] as? [String: Any] {
                            // Ollama：arguments 直接是对象
                            arguments = parsed
                        }

                        let result: String
                        do {
                            result = try await execute(ToolCall(id: callID, tool: tool, arguments: arguments))
                        } catch {
                            result = "执行失败：\(error.localizedDescription)"
                        }
                        // 工具返回里就是邮件正文和发件人，必须过同一套脱敏
                        messages.append(toolResultMessage(kind: provider.kind,
                                                          callID: callID,
                                                          name: name,
                                                          content: redaction?.mask(result) ?? result))
                    }
                }
                // 轮数用尽。最后一轮已经强行要过回答，还是要不到才走这里：
                // 有沿途正文就先交出去，总比把查到的内容全扔了强
                if let lastContent { return lastContent }
                let detail = trail.isEmpty ? "" : "（\(trail.joined(separator: "；"))）"
                throw AIError.emptyResponse("模型连续 \(maxRounds) 轮都在请求工具，最后一轮也不肯直接回答\(detail)")
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

    // MARK: - Anthropic tool calling

    /// Anthropic 的工具调用循环。
    ///
    /// 和 OpenAI 的三处结构差异：
    /// 1. system 是顶层字段，不是 messages 里的一条
    /// 2. 工具定义是 `{name, description, input_schema}`，没有 `function` 包一层
    /// 3. 工具结果不是 `role: tool`，而是**用户消息里的 `tool_result` 内容块**
    private static func anthropicChatWithTools(provider: AIProvider,
                                               model: String,
                                               system: String,
                                               user: String,
                                               tools: [[String: Any]],
                                               history: [(question: String, answer: String)],
                                               maxRounds: Int,
                                               usage: UsageBox?,
                                               redaction: RedactionContext?,
                                               onDelta: ((String) -> Void)?,
                                               execute: @escaping (ToolCall) async throws -> String) async throws -> String {
        let keys = keyCandidates(provider)
        guard !keys.isEmpty else { throw AIError.noKey }

        let spec = chatPath(provider.kind)
        guard let url = endpoint(provider.baseURL, spec.path, needsV1: spec.needsV1) else {
            throw AIError.notConfigured
        }

        let maskedSystem = redaction?.mask(system) ?? system
        var messages: [[String: Any]] = []
        for turn in history {
            messages.append(["role": "user", "content": redaction?.mask(turn.question) ?? turn.question])
            messages.append(["role": "assistant", "content": redaction?.mask(turn.answer) ?? turn.answer])
        }
        messages.append(["role": "user", "content": redaction?.mask(user) ?? user])
        let anthropicTools = tools.compactMap { item -> [String: Any]? in
            guard let function = item["function"] as? [String: Any],
                  let name = function["name"] as? String else { return nil }
            return [
                "name": name,
                "description": function["description"] as? String ?? "",
                "input_schema": function["parameters"] as? [String: Any]
                    ?? ["type": "object", "properties": [:], "required": []],
            ]
        }

        let baseMessages = messages
        var lastError: Error = AIError.notConfigured
        for key in keys {
            do {
                var messages = baseMessages
                // 和 OpenAI / Ollama 那条一样：轮数用尽时留一手，
                // 最后一轮不下发工具，逼它用已经拿到的信息回答
                var lastText: String?
                for round in 0..<maxRounds {
                    let isLastRound = round == maxRounds - 1
                    if isLastRound {
                        messages.append([
                            "role": "user",
                            "content": "不要再调用工具了。请直接根据上面已经查到的信息回答；没查到就直说没查到。",
                        ])
                    }
                    var body: [String: Any] = [
                        "model": model,
                        "system": maskedSystem,
                        "messages": messages,
                        "max_tokens": 4096,
                        "temperature": 0.4,
                    ]
                    if !anthropicTools.isEmpty, !isLastRound { body["tools"] = anthropicTools }

                    let step = try await anthropicRound(url: url, key: key, body: body,
                                                        usage: usage, onDelta: onDelta)
                    let content = step.content
                    let text = step.text
                    let json = step.json
                    let toolUses = content.filter { ($0["type"] as? String) == "tool_use" }

                    if !text.isEmpty { lastText = text }
                    if toolUses.isEmpty {
                        if !text.isEmpty { return text }
                        let stop = json["stop_reason"] as? String ?? "未知"
                        throw AIError.emptyResponse("stop_reason=\(stop)")
                    }
                    if isLastRound { break }

                    // assistant 的内容块必须原样回传，协议要求上下文里有那段 tool_use
                    messages.append(["role": "assistant", "content": content])

                    var results: [[String: Any]] = []
                    for use in toolUses {
                        let useID = use["id"] as? String ?? UUID().uuidString
                        guard let name = use["name"] as? String,
                              let tool = MailTool(rawValue: name) else {
                            results.append(["type": "tool_result", "tool_use_id": useID,
                                            "content": "工具不存在或无法解析"])
                            continue
                        }
                        let arguments = use["input"] as? [String: Any] ?? [:]
                        let result: String
                        do {
                            result = try await execute(ToolCall(id: useID, tool: tool, arguments: arguments))
                        } catch {
                            result = "执行失败：\(error.localizedDescription)"
                        }
                        results.append(["type": "tool_result", "tool_use_id": useID,
                                        "content": redaction?.mask(result) ?? result])
                    }
                    messages.append(["role": "user", "content": results])
                }
                if let lastText { return lastText }
                throw AIError.emptyResponse("模型连续 \(maxRounds) 轮都在请求工具，最后一轮也不肯直接回答")
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

    /// 工具结果的回传格式两家不同：
    /// OpenAI 用 `tool_call_id` 对应那次调用；Ollama 用 `tool_name` 对应工具名。
    /// 实测给 Ollama 只发 `tool_call_id`，模型会认为这次调用没被响应，转头再调一遍同一个工具，
    /// 四轮用尽也答不出东西。
    private static func toolResultMessage(kind: ProviderKind,
                                          callID: String,
                                          name: String,
                                          content: String) -> [String: Any] {
        if kind == .ollama {
            return ["role": "tool", "tool_name": name, "content": content]
        }
        return ["role": "tool", "tool_call_id": callID, "content": content]
    }

    /// 取出这一轮的 assistant 消息。
    /// OpenAI 兼容在 `choices[0].message`；Ollama 的 `/api/chat` 直接在顶层 `message`。
    private static func assistantMessage(from json: [String: Any]) -> [String: Any]? {
        if let message = (json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any] {
            return message
        }
        return json["message"] as? [String: Any]
    }

    /// 结构对不上时的诊断：优先把服务端的报错捞出来，否则把字段名和原文片段给出去，
    /// 否则用户只看到「模型没有返回内容」，根本无从查起
    private static func describeResponse(_ json: [String: Any], _ data: Data) -> String {
        if let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            return "服务端报错：\(message.prefix(160))"
        }
        if let error = json["error"] as? String {
            return "服务端报错：\(error.prefix(160))"
        }
        let keys = json.keys.sorted().joined(separator: ",")
        let raw = String(decoding: data.prefix(200), as: UTF8.self)
        return "响应结构不认识（字段：\(keys)；原文：\(raw)）"
    }

    /// 空响应时给一句人话，说明到底是截断了、还是只思考了没输出
    private static func emptyDiagnostic(_ json: [String: Any], _ message: [String: Any]) -> String {
        var parts: [String] = []
        // OpenAI 用 finish_reason，Ollama 用 done_reason，Anthropic 用 stop_reason
        let finish = (json["choices"] as? [[String: Any]])?.first?["finish_reason"] as? String
            ?? json["done_reason"] as? String
            ?? json["stop_reason"] as? String
        if let finish, !finish.isEmpty {
            parts.append(finish == "length" ? "输出被长度限制截断" : "finish_reason=\(finish)")
        }
        if let reasoning = message["reasoning_content"] as? String, !reasoning.isEmpty {
            parts.append("模型只输出了思考过程（\(reasoning.count) 字）")
        }
        if let usage = json["usage"] as? [String: Any],
           let out = usage["completion_tokens"] as? Int {
            parts.append("completion_tokens=\(out)")
        }
        // Ollama 的统计字段长这样
        if let out = json["eval_count"] as? Int {
            parts.append("eval_count=\(out)")
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

    /// 从响应里取 token 用量。三种协议的字段各不相同，取不到就算了——
    /// 这里只是给用户一个「这次花了多少」的量级，不参与任何决策
    private static func recordUsage(from json: [String: Any], into usage: UsageBox?) {
        guard let usage else { return }
        if let u = json["usage"] as? [String: Any] {
            // OpenAI: prompt_tokens / completion_tokens；Anthropic: input_tokens / output_tokens
            let input = u["prompt_tokens"] as? Int ?? u["input_tokens"] as? Int ?? 0
            let output = u["completion_tokens"] as? Int ?? u["output_tokens"] as? Int ?? 0
            usage.add(input: input, output: output)
            return
        }
        // Ollama 把计数放在顶层
        if let input = json["prompt_eval_count"] as? Int {
            usage.add(input: input, output: json["eval_count"] as? Int ?? 0)
        }
    }

    private static func localTimeout(_ kind: ProviderKind) -> TimeInterval {
        kind == .ollama ? 180 : 90
    }

    /// Ollama 默认闲置 5 分钟就把模型卸出内存，下一次提问又要重新加载。
    /// 一次问答里本来就有好几轮工具调用，中途被卸载会白等一大截，所以让它多留一会儿。
    private static func applyKeepAlive(_ body: inout [String: Any], kind: ProviderKind) {
        guard kind == .ollama else { return }
        body["keep_alive"] = "30m"
    }

    private static func chatBody(kind: ProviderKind, model: String, system: String, user: String) -> [String: Any] {
        switch kind {
        case .openai, .ollama:
            var body: [String: Any] = [
                "model": model,
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user", "content": user],
                ],
                "temperature": 0.4,
                "stream": false,
            ]
            applyKeepAlive(&body, kind: kind)
            return body
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

    /// 本地模型第一次要先把几 GB 的权重读进内存，90 秒对 27B 这种不够用
    private static func send(url: URL,
                             method: String,
                             headers: [String: String],
                             body: [String: Any]?,
                             timeout: TimeInterval = 90) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
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
            throw AIError.emptyResponse("响应不是 JSON（\(data.count) 字节）")
        }
        let message: [String: Any]?
        switch kind {
        case .openai:
            message = (json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
        case .anthropic:
            // Anthropic 的正文是顶层的 content 块数组，包一层好复用 messageText
            message = ["content": json["content"] ?? []]
        case .ollama:
            message = json["message"] as? [String: Any]
        }
        guard let message else { throw AIError.emptyResponse(describeResponse(json, data)) }
        guard let text = messageText(message) else {
            throw AIError.emptyResponse(emptyDiagnostic(json, message))
        }
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
