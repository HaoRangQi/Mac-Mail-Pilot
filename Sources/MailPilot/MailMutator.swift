import AppKit
import Foundation

enum MailMutatorError: LocalizedError {
    case missingMessageID
    case notFound(String)
    case script(String)

    var errorDescription: String? {
        switch self {
        case .missingMessageID:
            return "这封邮件没有 Message-ID，无法在「邮件」App 中定位"
        case .notFound(let message):
            return message
        case .script(let message):
            return message
        }
    }
}

/// 写操作：移入废纸篓、标记已读、加/取消旗标。
///
/// 实现思路与 Apple Mail MCP 服务器（jayvee6/apple-mail-mcp）一致：
/// 用 AppleScript 让「邮件」App 自己动手——先按 账户 → 邮箱 → RFC 2822 Message-ID
/// 定位消息，再执行动作。「邮件」App 的索引同步更新，本地 `.emlx` 也会跟着变，
/// 刷新后状态是对的。
///
/// 之所以不自己动 `.emlx` 或 Envelope Index：那是「邮件」App 的私有存储，
/// 外部改了它不知道，界面也不会更新。
enum MailMutator {

    // MARK: - 动作

    static func moveToTrash(accountID: String,
                            accountName: String,
                            accountEmail: String,
                            mailboxName: String,
                            messageID: String) async throws {
        let script = """
        tell application "Mail"
        \(location(accountID: accountID,
                   accountName: accountName,
                   accountEmail: accountEmail,
                   mailboxName: mailboxName,
                   messageID: messageID))

            try
                delete m
                return "OK"
            on error delErr
                try
                    set mAcct to account of m
                    set trashBox to missing value
                    repeat with j from 1 to (count of mailboxes of mAcct)
                        set mb to mailbox j of mAcct
                        set mbName to name of mb as string
                        if mbName is "Trash" or mbName is "Deleted Messages" or mbName is "Bin" or mbName is "Deleted Items" then
                            set trashBox to mb
                            exit repeat
                        end if
                        if mbName is "已删除邮件" or mbName is "已删除" or mbName is "废纸篓" then
                            set trashBox to mb
                            exit repeat
                        end if
                    end repeat
                    if trashBox is missing value then return "ERROR: " & (delErr as string)
                    move m to trashBox
                    return "OK"
                on error
                    return "ERROR: " & (delErr as string)
                end try
            end try
        end tell
        """
        try await run(script)
    }

    static func setRead(_ read: Bool,
                        accountID: String,
                        accountName: String,
                        accountEmail: String,
                        mailboxName: String,
                        messageID: String) async throws {
        let script = """
        tell application "Mail"
        \(location(accountID: accountID,
                   accountName: accountName,
                   accountEmail: accountEmail,
                   mailboxName: mailboxName,
                   messageID: messageID))

            set read status of m to \(read ? "true" : "false")
            return "OK"
        end tell
        """
        try await run(script)
    }

    static func setFlagged(_ flagged: Bool,
                           accountID: String,
                           accountName: String,
                           accountEmail: String,
                           mailboxName: String,
                           messageID: String) async throws {
        let script = """
        tell application "Mail"
        \(location(accountID: accountID,
                   accountName: accountName,
                   accountEmail: accountEmail,
                   mailboxName: mailboxName,
                   messageID: messageID))

            set flagged status of m to \(flagged ? "true" : "false")
            return "OK"
        end tell
        """
        try await run(script)
    }

    // MARK: - 定位（三个动作共用）

    /// 定位链：账户 id（UUID）→ 名称 → 邮箱地址 → 唯一账户；
    /// 消息定位：指定邮箱 → 账户下所有邮箱 → 全库按 Message-ID 兜底。
    /// 动作放在后面，定位这块任何改动三个动作一起生效。
    private static func location(accountID: String,
                                 accountName: String,
                                 accountEmail: String,
                                 mailboxName: String,
                                 messageID: String) -> String {
        // 「邮件」App 的 `message id` 属性通常不带尖括号，而 RFC 2822 头里是 <id@host>。
        // 两边都试一遍，避免格式差异导致永远匹配不到。
        let bare = messageID.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))

        return """
            set bareId to "\(escape(bare))"
            set angleId to "<" & bareId & ">"
            set acctIdx to 0

            -- 1. 按账户 id（通常是 Mail 目录的 UUID）匹配，最精确
            repeat with i from 1 to (count of accounts)
                try
                    if (id of account i as string) is "\(escape(accountID))" then
                        set acctIdx to i
                        exit repeat
                    end if
                end try
            end repeat

            -- 2. 按账户显示名匹配
            if acctIdx is 0 then
                repeat with i from 1 to (count of accounts)
                    try
                        if (name of account i as string) is "\(escape(accountName))" then
                            set acctIdx to i
                            exit repeat
                        end if
                    end try
                end repeat
            end if

            -- 3. 按邮箱地址匹配
            if acctIdx is 0 and "\(escape(accountEmail))" is not "" then
                repeat with i from 1 to (count of accounts)
                    try
                        repeat with e in (email addresses of account i)
                            if (e as string) contains "\(escape(accountEmail))" then
                                set acctIdx to i
                                exit repeat
                            end if
                        end repeat
                    end try
                    if acctIdx > 0 then exit repeat
                end repeat
            end if

            -- 4. 只有一个账户时直接用它
            if acctIdx is 0 and (count of accounts) is 1 then set acctIdx to 1

            set m to missing value

            -- 在定位到的账户里找：先指定邮箱，再扫该账户所有邮箱
            if acctIdx > 0 then
                set acct to account acctIdx
                try
                    set m to first message of mailbox "\(escape(mailboxName))" of acct whose (message id is bareId or message id is angleId)
                end try
                if m is missing value then
                    repeat with j from 1 to (count of mailboxes of acct)
                        try
                            -- 跳过空邮箱：Mail 给每个账户都建了草稿/任务/便笺/日记等空目录
                            if (count of messages of mailbox j of acct) > 0 then
                                set m to first message of mailbox j of acct whose (message id is bareId or message id is angleId)
                            end if
                        end try
                        if m is not missing value then exit repeat
                    end repeat
                end if
            end if

            -- 5. 最后兜底：不依赖账户定位，全库按 Message-ID 扫一遍（跳过空邮箱）
            if m is missing value then
                repeat with i from 1 to (count of accounts)
                    set a2 to account i
                    repeat with j from 1 to (count of mailboxes of a2)
                        try
                            if (count of messages of mailbox j of a2) > 0 then
                                set m to first message of mailbox j of a2 whose (message id is bareId or message id is angleId)
                            end if
                        end try
                        if m is not missing value then exit repeat
                    end repeat
                    if m is not missing value then exit repeat
                end repeat
            end if

            set acctFound to "失败"
            if acctIdx > 0 then set acctFound to "成功"
            if m is missing value then
                -- 取一个真实样本 ID，便于判断是不是格式差异（带不带尖括号）
                set sampleId to "（无样本）"
                if acctIdx > 0 then
                    set acct to account acctIdx
                    repeat with j from 1 to (count of mailboxes of acct)
                        try
                            if (count of messages of mailbox j of acct) > 0 then
                                set sampleId to (message id of message 1 of mailbox j of acct) as string
                                exit repeat
                            end if
                        end try
                    end repeat
                end if
                return "ERROR: 找不到 Message-ID " & bareId & "（账户定位" & acctFound & "；样本 " & sampleId & "）"
            end if
        """
    }

    // MARK: - 执行

    private static func run(_ script: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var errorInfo: NSDictionary?
                guard let appleScript = NSAppleScript(source: script) else {
                    continuation.resume(throwing: MailMutatorError.script("无法创建脚本对象"))
                    return
                }
                let result = appleScript.executeAndReturnError(&errorInfo)
                if let errorInfo {
                    let number = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
                    let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "脚本执行失败"
                    if number == -1743 {
                        continuation.resume(throwing: MailMutatorError.script(
                            "未授权控制「邮件」。到 设置 → 权限管理 → 控制「邮件」App 点「申请权限」即可"))
                    } else {
                        continuation.resume(throwing: MailMutatorError.script(message))
                    }
                    return
                }
                let output = result.stringValue ?? ""
                if output == "OK" {
                    continuation.resume()
                } else {
                    let reason = output.hasPrefix("ERROR: ")
                        ? String(output.dropFirst("ERROR: ".count))
                        : (output.isEmpty ? "操作失败，未知原因" : output)
                    continuation.resume(throwing: MailMutatorError.notFound(reason))
                }
            }
        }
    }

    /// 去掉换行等控制字符，转义反斜杠与引号，防止破坏脚本结构
    private static func escape(_ raw: String) -> String {
        var cleaned = ""
        for scalar in raw.unicodeScalars {
            if scalar.value < 0x20 { continue }
            cleaned.unicodeScalars.append(scalar)
        }
        return cleaned
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
