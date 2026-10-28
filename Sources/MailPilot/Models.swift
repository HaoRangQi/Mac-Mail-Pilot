import Foundation

struct Account: Identifiable, Hashable {
    let id: String
    var name: String
    var email: String
    var provider: String = ""

    /// 侧边栏按服务商归大类用。只按邮箱域名判断，不依赖 Mail 的内部字段
    var service: MailService { MailService.detect(email: email) }
}

/// 邮箱服务商。侧边栏用它把十几个账号收成几个大类，
/// 否则 13 个账号平铺下来就是一堵墙。
enum MailService: String, CaseIterable, Identifiable, Hashable {
    case gmail, outlook, icloud, yahoo, qq, netease, other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .gmail: return "Gmail"
        case .outlook: return "Outlook"
        case .icloud: return "iCloud"
        case .yahoo: return "Yahoo"
        case .qq: return "QQ 邮箱"
        case .netease: return "网易邮箱"
        case .other: return "其他"
        }
    }

    static func detect(email: String) -> MailService {
        let domain = email.split(separator: "@").last.map(String.init)?.lowercased() ?? ""
        guard !domain.isEmpty else { return .other }

        func any(_ suffixes: [String]) -> Bool {
            suffixes.contains { domain == $0 || domain.hasSuffix("." + $0) }
        }

        if any(["gmail.com", "googlemail.com"]) { return .gmail }
        if any(["outlook.com", "hotmail.com", "live.com", "msn.com", "outlook.jp", "hotmail.co.uk"]) {
            return .outlook
        }
        if any(["icloud.com", "me.com", "mac.com"]) { return .icloud }
        if any(["yahoo.com", "ymail.com", "yahoo.co.jp", "yahoo.com.hk"]) { return .yahoo }
        if any(["qq.com", "foxmail.com"]) { return .qq }
        if any(["163.com", "126.com", "yeah.net", "188.com"]) { return .netease }
        return .other
    }
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
    var id: String { "\(partIndex)-\(filename)" }
    var filename: String
    var mime: String = ""
    var size: Int = 0
    /// 在 MIME 里的第几个叶子 part。保存时才按它回原文件取字节，
    /// 不把附件内容一直挂在 Message 上——一封带 20MB 附件的邮件不能占 20MB 内存
    var partIndex: Int = -1

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
    /// 回复链（References 头，从旧到新）
    var references: [String] = []
    /// RFC 2822 Message-ID（含尖括号），AppleScript 在「邮件」App 中定位消息用
    var messageID: String = ""
    var attachments: [Attachment] = []
    /// HTML 正文原文（有才走 WebView 渲染；空则用 body 纯文本显示）。
    /// 清洗、断网、链接策略全在渲染层做，原文不进 WebView
    var htmlBody: String = ""
    /// Content-ID → 内联图片数据（cid: 图片转 data URI 用）
    var inlineImages: [String: Data] = [:]

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
    /// 标记已读 / 未读（走 AppleScript，只有「邮件」App 知道怎么改旗标）
    func setRead(_ read: Bool, for message: Message) async throws
    /// 加 / 取消旗标
    func setFlagged(_ flagged: Bool, for message: Message) async throws
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
