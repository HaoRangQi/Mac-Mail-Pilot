import Foundation

/// 问答的可见范围：账号选择 + 时间窗口。
///
/// 这两个控件以前只有一部分路径认——时间范围在 `searchMessages` / `getMessage`
/// 两个分支里各写了一遍判断，账号选择更是只有旧的直连上下文那条路在管，
/// 走工具的那条根本不看。结果就是「控件动了，功能没动」。
///
/// 现在两者收进同一个值类型，由 `AskScopeStore` 统一执行。
struct AskScope {
    /// nil 表示「忽略」，不限时间
    var window: DateInterval?
    /// nil 表示所有账号；空集合表示一个都没选（调用方应当提前挡掉）
    var accountIDs: Set<String>?

    func allows(_ message: Message) -> Bool {
        if let window, !window.contains(message.date) { return false }
        if let accountIDs, !accountIDs.contains(message.accountID) { return false }
        return true
    }

    func allows(accountID: String) -> Bool {
        guard let accountIDs else { return true }
        return accountIDs.contains(accountID)
    }

    /// 有没有加任何限制。没限制时不必多取，省一次扫描
    var isRestricted: Bool { window != nil || accountIDs != nil }
}

enum AskScopeError: LocalizedError {
    case outside

    var errorDescription: String? {
        "这封邮件不在本次问答的可见范围内（账号或时间范围），不能操作"
    }
}

/// 带范围过滤的 `MailStore` 装饰器，叠在 `GuardedMailStore` 外面。
///
/// 为什么不在每个工具分支里各判一次：范围是**数据层**的属性，不是某个工具的选项。
/// 分支判断漏一处，用户就会看到「明明选了今日，AI 还是读到了去年的邮件」；
/// 而且新加工具时没人会记得补。装饰器只写一遍，fail-closed。
final class AskScopeStore: MailStore {
    private let inner: MailStore
    private let scope: AskScope

    /// 本轮真正交到模型手里的不同邮件数。气泡上要显示——
    /// 范围限制看不见摸不着，用户只能靠这个数字确认它确实生效了
    private let lock = NSLock()
    private var seen: Set<String> = []
    /// 按首次读到的顺序留一份，回答下方要列「这次读了哪几封」并支持点回去
    private var order: [String] = []
    private var byID: [String: Message] = [:]

    init(inner: MailStore, scope: AskScope) {
        self.inner = inner
        self.scope = scope
    }

    var isDemo: Bool { inner.isDemo }

    var scannedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return seen.count
    }

    /// 本轮真正读过的邮件（去重、按首次读到排序）。
    /// 这是「回答可溯源」的数据来源——不依赖模型自己在正文里写对 ID
    var citations: [Message] {
        lock.lock()
        defer { lock.unlock() }
        return order.compactMap { byID[$0] }
    }

    private func note(_ rows: [Message]) {
        guard !rows.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        for row in rows where seen.insert(row.id).inserted {
            order.append(row.id)
            byID[row.id] = row
        }
    }

    func accounts() async throws -> [Account] {
        let rows = try await inner.accounts()
        return rows.filter { scope.allows(accountID: $0.id) }
    }

    func mailboxes() async throws -> [Mailbox] {
        let rows = try await inner.mailboxes()
        return rows.filter { scope.allows(accountID: $0.accountID) }
    }

    func messages(mailboxID: String, limit: Int) async throws -> [Message] {
        try await collect(limit: limit) { want in
            try await self.inner.messages(mailboxID: mailboxID, limit: want)
        }
    }

    func message(id: String) async throws -> Message? {
        guard let message = try await inner.message(id: id) else { return nil }
        // 就算模型从别处拿到了 id（上一轮对话、模型自己编的），窗口外照样读不到
        guard scope.allows(message) else { return nil }
        note([message])
        return message
    }

    func search(_ query: String, limit: Int) async throws -> [Message] {
        try await collect(limit: limit) { want in
            try await self.inner.search(query, limit: want)
        }
    }

    /// 过滤会让条数变少，所以多取几轮再收口。
    /// 但必须设上限：选了「今日」时绝大多数命中都在窗口外，
    /// 不封顶的「加倍到凑够为止」会把整箱邮件读一遍。
    private func collect(limit: Int,
                         fetch: (Int) async throws -> [Message]) async throws -> [Message] {
        guard scope.isRestricted else {
            let rows = try await fetch(limit)
            note(rows)
            return rows
        }
        let ceiling = 400
        var want = min(max(limit, 40), ceiling)
        var attempts = 0
        while true {
            let rows = try await fetch(want)
            let visible = rows.filter { scope.allows($0) }
            attempts += 1
            if visible.count >= limit || rows.count < want || attempts >= 3 || want >= ceiling {
                let capped = Array(visible.prefix(limit))
                note(capped)
                return capped
            }
            want = min(want * 2, ceiling)
        }
    }

    func moveToTrash(_ message: Message) async throws {
        // 范围既是读限制也是写限制：窗口外的邮件不许删
        guard scope.allows(message) else { throw AskScopeError.outside }
        try await inner.moveToTrash(message)
    }

    func setRead(_ read: Bool, for message: Message) async throws {
        guard scope.allows(message) else { throw AskScopeError.outside }
        try await inner.setRead(read, for: message)
    }

    func setFlagged(_ flagged: Bool, for message: Message) async throws {
        guard scope.allows(message) else { throw AskScopeError.outside }
        try await inner.setFlagged(flagged, for: message)
    }

    func badgeCounts() async throws -> [String: Int] {
        [:]
    }
}
