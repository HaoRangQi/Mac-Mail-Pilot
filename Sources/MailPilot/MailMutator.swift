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

/// 破坏性操作：把邮件移入「邮件」App 的废纸篓。
///
/// 实现思路与 Apple Mail MCP 服务器（jayvee6/apple-mail-mcp）一致：
/// 用 AppleScript 让「邮件」App 自己执行删除——先按 账户名 → 邮箱名 → RFC 2822 Message-ID
/// 定位消息，再 `delete`。消息会进入账户的废纸篓，「邮件」App 的索引同步更新，
/// 本地 `.emlx` 也会随之移出原邮箱目录——所以刷新后不会再回来，是真实删除。
///
/// 之所以不自己动 `.emlx` 文件：「邮件」App 的存储有私有 Envelope Index，
/// 外部搬文件它不会知道，界面也不会更新。
enum MailMutator {

    /// 账户定位三级回退：Accounts.plist 的名字 → 邮箱地址 → 唯一账户
    /// 消息定位两级回退：指定邮箱 → 扫描账户下所有邮箱
    /// 删除动作两级回退：`delete`（原生，自动进废纸篓）→ 显式 move 到废纸篓邮箱
    static func moveToTrash(accountName: String,
                            accountEmail: String,
                            mailboxName: String,
                            messageID: String) async throws {
        let script = """
        tell application "Mail"
            set acct to missing value
            try
                set acct to first account whose name = "\(escape(accountName))"
            end try
            if acct is missing value and "\(escape(accountEmail))" is not "" then
                repeat with a in accounts
                    try
                        repeat with e in (email addresses of a)
                            if (e as string) contains "\(escape(accountEmail))" then set acct to a
                        end repeat
                    end try
                end repeat
            end if
            if acct is missing value and (count of accounts) is 1 then set acct to first account
            if acct is missing value then return "ERROR: 找不到对应的邮件账户"

            set m to missing value
            try
                set m to first message of mailbox "\(escape(mailboxName))" of acct whose message id = "\(escape(messageID))"
            end try
            if m is missing value then
                repeat with mb in mailboxes of acct
                    try
                        set m to first message of mb whose message id = "\(escape(messageID))"
                        if m is not missing value then exit repeat
                    end try
                end repeat
            end if
            if m is missing value then return "ERROR: 在「邮件」App 里找不到这封邮件，可能已被移动或删除"

            try
                delete m
                return "OK"
            on error delErr
                set trashBox to missing value
                repeat with mb in mailboxes of acct
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
            end try
        end tell
        """

        return try await withCheckedThrowingContinuation { continuation in
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
                        : (output.isEmpty ? "删除失败，未知原因" : output)
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
