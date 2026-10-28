import Foundation

var failures = 0

func check(_ ok: Bool, _ name: String) {
    print((ok ? "✅ " : "❌ ") + name)
    if !ok { failures += 1 }
}

enum AIAction: String, Hashable {
    case summarize, reply, classify, translate, ask
    var label: String { rawValue }
}

let toolSchema: [[String: Any]] = [[
    "type": "function",
    "function": [
        "name": "searchMessages",
        "description": "查邮件",
        "parameters": [
            "type": "object",
            "properties": ["query": ["type": "string"]],
            "required": ["query"],
        ],
    ],
]]

@main
struct MockTest {
    static func main() async {
        let port = ProcessInfo.processInfo.environment["PORT"] ?? "8765"
        let host = "http://127.0.0.1:\(port)"

        let openai = AIProvider(name: "mock-openai", kind: .openai,
                                baseURL: host + "/v1", apiKey: "k", selectedModel: "plain")
        let ollama = AIProvider(name: "mock-ollama", kind: .ollama,
                                baseURL: host, selectedModel: "plain")
        let anthropic = AIProvider(name: "mock-anthropic", kind: .anthropic,
                                   baseURL: host + "/v1", apiKey: "k", selectedModel: "plain")

        // 1. OpenAI 纯聊天流式
        do {
            var deltas: [String] = []
            let text = try await AIService.chat(provider: openai, model: "plain",
                                                system: "s", user: "hi") { deltas.append($0) }
            check(text == "查询完成：3 封", "OpenAI 纯聊天：返回完整文本（\(text)）")
            check(deltas.last == "查询完成：3 封", "OpenAI 纯聊天：最后一次回调是完整文本")
            check(deltas.count >= 3, "OpenAI 纯聊天：分多次回调（\(deltas.count) 次）")
            check(deltas.dropFirst().allSatisfy { !$0.isEmpty }, "OpenAI 纯聊天：增量拼接非空")
        } catch {
            check(false, "OpenAI 纯聊天抛错：\(error)")
        }

        // 2. OpenAI 工具调用：arguments 分片必须拼装成合法 JSON 并回传上下文
        do {
            var lastDelta = ""
            let answer = try await AIService.chatWithTools(
                provider: openai, model: "tools", system: "s", user: "查周报",
                tools: toolSchema,
                onDelta: { lastDelta = $0 }
            ) { call in
                check(call.tool == .searchMessages, "OpenAI 工具：工具名正确")
                check(call.arguments["query"] as? String == "周报", "OpenAI 工具：分片 arguments 拼装正确")
                return "3 封邮件"
            }
            check(answer == "查询完成：3 封", "OpenAI 工具：第二轮上下文正确（服务端回显校验）")
            check(lastDelta == "查询完成：3 封", "OpenAI 工具：最终回答走了流式")
        } catch {
            check(false, "OpenAI 工具链路抛错：\(error)")
        }

        // 3. Ollama：NDJSON + 对象型 arguments + tool_name 回传
        do {
            let answer = try await AIService.chatWithTools(
                provider: ollama, model: "tools", system: "s", user: "查周报",
                tools: toolSchema,
                onDelta: { _ in }
            ) { call in
                check(call.arguments["query"] as? String == "周报", "Ollama 工具：arguments 解析正确")
                return "3 封邮件"
            }
            check(answer == "查询完成：3 封", "Ollama 工具：tool_name 回传正确（服务端回显校验）")
        } catch {
            check(false, "Ollama 链路抛错：\(error)")
        }

        // 4. Anthropic：tool_use 流式拼装 + tool_result 回传 + usage
        do {
            let usage = UsageBox()
            let answer = try await AIService.chatWithTools(
                provider: anthropic, model: "tools", system: "s", user: "查周报",
                tools: toolSchema,
                usage: usage,
                onDelta: { _ in }
            ) { call in
                check(call.tool == .searchMessages, "Anthropic 工具：工具名正确")
                check(call.arguments["query"] as? String == "周报", "Anthropic 工具：input_json_delta 拼装正确")
                return "3 封邮件"
            }
            check(answer == "查询完成：3 封", "Anthropic 工具：tool_result 回传正确（服务端回显校验）")
            check(usage.total > 0, "Anthropic 工具：流式 usage 被记录（\(usage.total)）")
        } catch {
            check(false, "Anthropic 链路抛错：\(error)")
        }

        // 5. 网关不认 stream：回退非流式
        do {
            var deltas: [String] = []
            let text = try await AIService.chat(provider: openai, model: "fallback",
                                                system: "s", user: "hi") { deltas.append($0) }
            check(text == "非流式回退", "回退：网关忽略 stream 时自动走非流式（\(text)）")
        } catch {
            check(false, "回退链路抛错：\(error)")
        }

        // 6. 流式请求的 401 必须当成密钥错误往上抛
        do {
            _ = try await AIService.chat(provider: openai, model: "unauthorized",
                                         system: "s", user: "hi") { _ in }
            check(false, "401：应该抛错但没抛")
        } catch let error as AIError {
            if case .http(let code, _) = error {
                check(code == 401, "401：流式路径正确上报 HTTP 401")
            } else {
                check(false, "401：错误类型不对（\(error)）")
            }
        } catch {
            check(false, "401：错误类型不对（\(error)）")
        }

        print(failures == 0 ? "\n全部通过" : "\n有 \(failures) 项失败")
        exit(failures == 0 ? 0 : 1)
    }
}
