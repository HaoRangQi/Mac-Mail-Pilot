import Foundation

struct Account: Identifiable, Hashable {
    let id: String
    var name: String
    var email: String
    var provider: String = ""
}

struct Mailbox: Identifiable, Hashable {
    let id: String
    var accountID: String
    var name: String
    /// 「邮件」App 里的原始邮箱名（AppleScript 定位用，如 INBOX / 已删除邮件 / All Mail）
    var rawName: String = ""
    var role: Role = .custom
    var unread: Int = 0
    var total: Int = 0

    enum Role: String, Hashable {
        case inbox, sent, drafts, archive, trash, custom
    }
}

struct Attachment: Identifiable, Hashable {
    var id: String { filename }
    var filename: String
    var mime: String = ""
    var size: Int = 0

    var sizeText: String {
        guard size > 0 else { return "" }
        if size > 1_048_576 { return String(format: "%.1f MB", Double(size) / 1_048_576) }
        return "\(max(1, size / 1024)) KB"
    }
}

struct Message: Identifiable, Hashable {
    let id: String
    var accountID: String
    var mailboxID: String
    var subject: String
    var sender: String
    var senderEmail: String
    /// 收件人（To）。多账户下要能看出这封信是发给哪个地址的
    var recipients: [String] = []
    /// 抄送（Cc）
    var cc: [String] = []
    /// 密送（Bcc）。收到的邮件一般没有这个头，只有自己发出的副本才带
    var bcc: [String] = []
    var date: Date
    var preview: String
    var body: String
    var unread: Bool = false
    var flagged: Bool = false
    var needsReply: Bool = false
    var threadID: String = ""
    /// RFC 2822 Message-ID（含尖括号），AppleScript 在「邮件」App 中定位消息用
    var messageID: String = ""
    var attachments: [Attachment] = []

    var displaySender: String {
        sender.isEmpty ? senderEmail : sender
    }
}

/// 数据来源抽象。演示实现与真实实现共用同一套视图。
protocol MailStore: AnyObject {
    var isDemo: Bool { get }
    func accounts() async throws -> [Account]
    func mailboxes() async throws -> [Mailbox]
    func messages(mailboxID: String, limit: Int) async throws -> [Message]
    func message(id: String) async throws -> Message?
    func search(_ query: String, limit: Int) async throws -> [Message]
    /// 把邮件移入「邮件」App 的废纸篓（真实删除，走 AppleScript）
    func moveToTrash(_ message: Message) async throws
    /// 侧边栏「个人收藏」与「智能邮箱」的角标
    func badgeCounts() async throws -> [String: Int]
}

enum SmartBox: String, CaseIterable, Identifiable {
    case allInbox = "fav:inbox"
    case allFlagged = "fav:flagged"
    case allDrafts = "fav:drafts"
    case allSent = "fav:sent"
    case today = "smart:today"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allInbox: return "所有收件箱"
        case .allFlagged: return "所有旗标"
        case .allDrafts: return "所有草稿"
        case .allSent: return "所有已发送"
        case .today: return "今天"
        }
    }

    var icon: String {
        switch self {
        case .allInbox: return "tray.2"
        case .allFlagged: return "flag"
        case .allDrafts: return "square.and.pencil"
        case .allSent: return "paperplane"
        case .today: return "calendar"
        }
    }
}
