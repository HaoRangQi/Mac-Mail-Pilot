import AppKit
import Foundation

enum MailSenderError: LocalizedError {
    case emptyRecipient
    case script(String)

    var errorDescription: String? {
        switch self {
        case .emptyRecipient: return "请填写收件人"
        case .script(let message): return message
        }
    }
}

/// 两条发送路径，用于实测哪条更好用。
/// 1) mailto：零权限，交给「邮件」打开撰写窗口
/// 2) AppleScript：可指定发件账号、后续可带附件，可切换为直接发送
enum MailSender {

    // MARK: - 路径一：mailto

    static func mailtoURL(to: String, subject: String, body: String) -> URL? {
        var comps = URLComponents()
        comps.scheme = "mailto"
        comps.path = to
        comps.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body),
        ]
        return comps.url
    }

    @discardableResult
    static func viaMailto(to: String, subject: String, body: String) -> Bool {
        guard !to.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard let url = mailtoURL(to: to, subject: subject, body: body) else { return false }
        return NSWorkspace.shared.open(url)
    }

    // MARK: - 路径二：AppleScript

    /// 正文与主题走临时文件传入，避免 AppleScript 字符串转义的坑。
    static func viaAppleScript(to: [String], subject: String, body: String, sendNow: Bool) throws {
        let addresses = to.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !addresses.isEmpty else { throw MailSenderError.emptyRecipient }

        let tmp = FileManager.default.temporaryDirectory
        let bodyURL = tmp.appendingPathComponent("mailpilot_body_\(UUID().uuidString).txt")
        let subjectURL = tmp.appendingPathComponent("mailpilot_subject_\(UUID().uuidString).txt")
        try body.write(to: bodyURL, atomically: true, encoding: .utf8)
        try subject.write(to: subjectURL, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: bodyURL)
            try? FileManager.default.removeItem(at: subjectURL)
        }

        let recipientLines = addresses
            .map { "make new to recipient at end of to recipients with properties {address:\"\(escape($0))\"}" }
            .joined(separator: "\n        ")

        let script = """
        set bodyFile to POSIX file "\(bodyURL.path)"
        set subjFile to POSIX file "\(subjectURL.path)"
        set theBody to read bodyFile as «class utf8»
        set theSubject to read subjFile as «class utf8»

        tell application "Mail"
            set newMessage to make new outgoing message with properties {subject:theSubject, content:theBody, visible:true}
            tell newMessage
                \(recipientLines)
            end tell
            activate
            \(sendNow ? "send newMessage" : "")
        end tell
        """

        var errorInfo: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else {
            throw MailSenderError.script("无法创建脚本对象")
        }
        appleScript.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "脚本执行失败"
            let number = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
            if number == -1743 {
                throw MailSenderError.script("未授权控制「邮件」。请到 系统设置 → 隐私与安全性 → 自动化 中勾选 MailPilot")
            }
            throw MailSenderError.script(message)
        }
    }

    private static func escape(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
