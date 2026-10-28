import Foundation

/// 邮件工具。AI 通过 tool calling 调用这些能力来操作邮件。
///
/// 权限分级与 `TrustPolicy` 同源：工具也分 只读 / 写入 / 破坏性。
/// 不可信模型默认只给只读工具，写入要确认，破坏性一律二次确认。
enum MailTool: String, CaseIterable, Identifiable {
    case searchMessages
    case getMessage
    case listMailboxes
    case markRead
    case setFlag
    case moveToTrash
    case saveDraft
    case sendMessage
    /// 一次提出多封邮件的处理方案，由用户勾选后统一执行。
    /// 逐封调用 moveToTrash 会让用户连点 N 次确认框，点到后面就是无脑点
    case proposeBatch

    var id: String { rawValue }

    var risk: ToolRisk {
        switch self {
        case .searchMessages, .getMessage, .listMailboxes: return .read
        case .markRead, .setFlag, .saveDraft: return .write
        case .moveToTrash, .sendMessage, .proposeBatch: return .destructive
        }
    }

    /// 给模型看的说明。写清楚「什么时候该用这个工具」
    var description: String {
        switch self {
        case .searchMessages:
            return "按关键词搜索邮件，返回匹配邮件的 ID、主题、发件人与日期。这是查找邮件的第一步"
        case .getMessage:
            return "读取一封邮件的完整正文，需要先通过搜索拿到 message_id"
        case .listMailboxes:
            return "列出当前所有账户与邮箱，以及各邮箱的邮件数"
        case .markRead:
            return "把一封邮件标为已读或未读"
        case .setFlag:
            return "给一封邮件加旗标或取消旗标，用于标记重要邮件"
        case .moveToTrash:
            return "把一封邮件移入「邮件」App 的废纸篓。可在邮件 App 中恢复，但需要用户确认"
        case .saveDraft:
            return "把一封邮件存为草稿，需要收件人、主题、正文"
        case .sendMessage:
            return "发送一封邮件，需要收件人、主题、正文。发送后无法撤回，必须用户确认"
        case .proposeBatch:
            return "一次提出对多封邮件的处理方案（删除到废纸篓 / 标已读 / 加旗标）。需要处理 2 封以上时用这个，不要逐封调用"
        }
    }

    var requiresConfirmation: Bool { risk == .destructive }

    // MARK: - 参数 schema（OpenAI function calling 格式）

    var parameterSchema: [String: Any] {
        func obj(_ properties: [String: Any], _ required: [String]) -> [String: Any] {
            ["type": "object", "properties": properties, "required": required]
        }
        func str(_ desc: String) -> [String: Any] { ["type": "string", "description": desc] }

        switch self {
        case .searchMessages:
            return obj(["query": str("搜索关键词，可匹配主题、发件人或正文")], ["query"])
        case .getMessage:
            return obj(["message_id": str("邮件 ID，来自搜索结果")], ["message_id"])
        case .listMailboxes:
            return obj([:], [])
        case .markRead:
            return obj([
                "message_id": str("邮件 ID"),
                "read": ["type": "boolean", "description": "true 标为已读，false 标为未读"],
            ], ["message_id", "read"])
        case .setFlag:
            return obj([
                "message_id": str("邮件 ID"),
                "flagged": ["type": "boolean", "description": "true 加旗标，false 取消旗标"],
            ], ["message_id", "flagged"])
        case .moveToTrash:
            return obj(["message_id": str("要移入废纸篓的邮件 ID")], ["message_id"])
        case .saveDraft:
            return obj([
                "to": str("收件人邮箱，多个用逗号分隔"),
                "subject": str("邮件主题"),
                "body": str("邮件正文"),
            ], ["to", "subject", "body"])
        case .sendMessage:
            return obj([
                "to": str("收件人邮箱，多个用逗号分隔"),
                "cc": str("抄送，可选"),
                "bcc": str("密送，可选"),
                "subject": str("邮件主题"),
                "body": str("邮件正文"),
            ], ["to", "subject", "body"])
        case .proposeBatch:
            return obj([
                "action": [
                    "type": "string",
                    "enum": ["trash", "markRead", "setFlag"],
                    "description": "trash=移入废纸篓，markRead=标为已读，setFlag=加旗标",
                ],
                "message_ids": [
                    "type": "array",
                    "items": ["type": "string"],
                    "description": "邮件 ID 列表，来自搜索结果。最多 50 封",
                ],
                "reason": str("一句话说明为什么选这些邮件，会显示在确认清单顶部"),
            ], ["action", "message_ids", "reason"])
        }
    }

    /// OpenAI 兼容的 tool 定义
    var toolSchema: [String: Any] {
        [
            "type": "function",
            "function": [
                "name": rawValue,
                "description": description,
                "parameters": parameterSchema,
            ],
        ]
    }
}

enum ToolRisk: String {
    case read = "只读"
    case write = "写入"
    case destructive = "破坏性"
}

/// 模型发起的一次工具调用
struct ToolCall: Identifiable {
    let id: String
    let tool: MailTool
    let arguments: [String: Any]

    /// 给人看的一句话说明，用于确认框
    var humanSummary: String {
        let mid = arguments["message_id"] as? String ?? "?"
        switch tool {
        case .searchMessages:
            return "搜索：\(arguments["query"] as? String ?? "")"
        case .getMessage:
            return "读取邮件 \(mid)"
        case .listMailboxes:
            return "列出所有邮箱"
        case .markRead:
            let read = (arguments["read"] as? Bool) ?? true
            return "把 \(mid) 标为\(read ? "已读" : "未读")"
        case .setFlag:
            let on = (arguments["flagged"] as? Bool) ?? true
            return "给 \(mid) \(on ? "加旗标" : "取消旗标")"
        case .moveToTrash:
            return "把 \(mid) 移入废纸篓"
        case .saveDraft:
            return "存草稿：\(arguments["subject"] as? String ?? "")"
        case .sendMessage:
            return "发送邮件给 \(arguments["to"] as? String ?? "")：\(arguments["subject"] as? String ?? "")"
        case .proposeBatch:
            let count = (arguments["message_ids"] as? [Any])?.count ?? 0
            return "批量处理 \(count) 封：\(arguments["reason"] as? String ?? "")"
        }
    }
}
