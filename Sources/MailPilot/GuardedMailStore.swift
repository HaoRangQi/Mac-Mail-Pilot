import Foundation

/// 一次 AI 请求的可见范围。
///
/// 信任级别在**每次请求**时重新算（可信 / 本地模型可以看全部），
/// 不要在会话开始时缓存——模型中途切换会用到旧范围。
struct MailAccessScope {
    let trusted: Bool
    let guards: MailGuardStore

    func canRead(_ message: Message) -> Bool {
        trusted || !guards.isLocked(message)
    }

    func canRead(accountID: String) -> Bool {
        trusted || !guards.isAccountLocked(accountID)
    }
}

enum MailAccessError: LocalizedError {
    case locked

    var errorDescription: String? {
        "这封邮件已上锁，不可信模型无法操作它"
    }
}

/// 带访问控制的 `MailStore` 装饰器。
///
/// 为什么要在数据层拦而不是在每个工具里写 if：
/// 锁的意义是**模型根本拿不到这封邮件**，而不是「拿到了但被要求别提」。
/// 装饰器只写一遍过滤，以后新增任何工具只要走这个 store 就自动受保护——
/// fail-closed，不依赖调用方记得加检查。
final class GuardedMailStore: MailStore {
    private let inner: MailStore
    private let scope: MailAccessScope

    init(inner: MailStore, scope: MailAccessScope) {
        self.inner = inner
        self.scope = scope
    }

    var isDemo: Bool { inner.isDemo }

    func accounts() async throws -> [Account] {
        let rows = try await inner.accounts()
        return rows.filter { scope.canRead(accountID: $0.id) }
    }

    func mailboxes() async throws -> [Mailbox] {
        let rows = try await inner.mailboxes()
        return rows.filter { scope.canRead(accountID: $0.accountID) }
    }

    func messages(mailboxID: String, limit: Int) async throws -> [Message] {
        // 过滤会让条数变少，所以多取几轮再收口，不能简单地在 limit 之后 filter。
        // 但必须设上限：整箱都被锁时，「一直加倍直到凑够」会反复全量解析同一个目录。
        var want = max(limit, 20)
        var attempts = 0
        while true {
            let rows = try await inner.messages(mailboxID: mailboxID, limit: want)
            let visible = rows.filter { scope.canRead($0) }
            attempts += 1
            if visible.count >= limit || rows.count < want || attempts >= 3 {
                return Array(visible.prefix(limit))
            }
            want *= 2
        }
    }

    func message(id: String) async throws -> Message? {
        guard let message = try await inner.message(id: id) else { return nil }
        // 就算模型从别处拿到了 id（上一轮对话、用户粘贴），这里也读不到
        return scope.canRead(message) ? message : nil
    }

    func search(_ query: String, limit: Int) async throws -> [Message] {
        var want = max(limit, 20)
        var attempts = 0
        while true {
            let rows = try await inner.search(query, limit: want)
            let visible = rows.filter { scope.canRead($0) }
            attempts += 1
            if visible.count >= limit || rows.count < want || attempts >= 3 {
                return Array(visible.prefix(limit))
            }
            want *= 2
        }
    }

    func moveToTrash(_ message: Message) async throws {
        // 锁既是读锁也是写锁：看不见的邮件也不许删
        guard scope.canRead(message) else { throw MailAccessError.locked }
        try await inner.moveToTrash(message)
    }

    func setRead(_ read: Bool, for message: Message) async throws {
        guard scope.canRead(message) else { throw MailAccessError.locked }
        try await inner.setRead(read, for: message)
    }

    func setFlagged(_ flagged: Bool, for message: Message) async throws {
        guard scope.canRead(message) else { throw MailAccessError.locked }
        try await inner.setFlagged(flagged, for: message)
    }

    func badgeCounts() async throws -> [String: Int] {
        // 角标是界面用的，AI 不该从计数里反推出「还有一封你看不到」
        [:]
    }
}
