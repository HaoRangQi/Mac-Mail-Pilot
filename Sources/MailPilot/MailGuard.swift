import Combine
import Foundation

/// 邮件对 AI 的可见性。
///
/// 和 `MailExemption` 是**两条不同的轴**，不要混：
/// - 豁免管「能不能原样发送」（脱敏策略）
/// - 上锁管「能不能进入上下文」（访问控制）
/// 冲突时锁优先——访问控制强于脱敏策略，否则给敏感邮件打码后仍然外发，等于没锁。
enum MailProtection: String, Codable {
    case open
    case locked
}

/// 一条上锁记录。
///
/// 存 `subject` 是为了邮件被删之后还能告诉用户「你锁的是哪封」；
/// 存 `pathHint` 是为了每次启动用 `fileExists` 快速判断存活，不必扫全盘。
struct GuardRecord: Codable, Equatable {
    var level: MailProtection
    var subject: String
    var addedAt: Date
    /// 第一次发现邮件不在磁盘上的时间。nil = 正常。
    /// **不能拿邮件日期当 TTL 时钟**：一封 2024 年的对账单今天被删，
    /// 用邮件日期会立刻清掉锁，而它可能还躺在废纸篓里等着恢复。
    var missingSince: Date?
    var pathHint: String
}

/// 邮件 / 账号的上锁名单。
///
/// 三个设计取舍：
/// 1. **按 Message-ID 存**，和单封豁免同口径——邮件挪邮箱后路径会变，ID 不变
/// 2. **账号级与邮件级取最严**：账号上锁后单封不能被解锁，安全策略不留例外通道
/// 3. **记录永不自动删除，只标 missingSince**：邮件清了废纸篓、又从备份恢复时，
///    锁会自动重新生效；反之若在消失瞬间就删记录，恢复回来的邮件就是裸奔的
final class MailGuardStore: ObservableObject {

    /// 消失多久之后认定「真的没了」。Mail 默认 30 天清废纸篓，20 天留了余量。
    static let ttl: TimeInterval = 20 * 24 * 3600

    @Published private(set) var accounts: [String: MailProtection] = [:]
    @Published private(set) var messages: [String: GuardRecord] = [:]

    private let storageKey = "mailpilot.guard.state"

    private struct State: Codable {
        var accounts: [String: MailProtection] = [:]
        var messages: [String: GuardRecord] = [:]
    }

    init() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let state = try? JSONDecoder().decode(State.self, from: data) else { return }
        accounts = state.accounts
        messages = state.messages
    }

    // MARK: - 查询

    /// 账号级与邮件级取最严
    func level(messageID: String, accountID: String) -> MailProtection {
        if accounts[accountID] == .locked { return .locked }
        if messages[messageID]?.level == .locked { return .locked }
        return .open
    }

    func level(for message: Message) -> MailProtection {
        level(messageID: key(for: message), accountID: message.accountID)
    }

    func isLocked(_ message: Message) -> Bool {
        level(for: message) == .locked
    }

    func isAccountLocked(_ accountID: String) -> Bool {
        accounts[accountID] == .locked
    }

    /// 记录的键：优先 Message-ID（挪邮箱不变），缺失时才退回路径 id
    func key(for message: Message) -> String {
        message.messageID.isEmpty ? message.id : message.messageID
    }

    // MARK: - 设置

    func setLocked(_ locked: Bool, for message: Message) {
        let id = key(for: message)
        guard !id.isEmpty else { return }
        if locked {
            messages[id] = GuardRecord(
                level: .locked,
                subject: message.subject,
                addedAt: Date(),
                missingSince: nil,
                pathHint: message.id
            )
        } else {
            messages.removeValue(forKey: id)
        }
        save()
    }

    func setAccountLocked(_ locked: Bool, id: String) {
        guard !id.isEmpty else { return }
        if locked {
            accounts[id] = .locked
        } else {
            accounts.removeValue(forKey: id)
        }
        save()
    }

    func clearMessages() {
        messages.removeAll()
        save()
    }

    func clearAll() {
        accounts.removeAll()
        messages.removeAll()
        save()
    }

    // MARK: - 概览（供设置页展示）

    var lockedMessageCount: Int { messages.count }
    var lockedAccountCount: Int { accounts.count }
    var orphanedCount: Int { messages.values.filter { $0.missingSince != nil }.count }

    /// 失效记录：邮件已经不在磁盘上，但还没到清理期限
    var orphaned: [(key: String, record: GuardRecord)] {
        messages
            .filter { $0.value.missingSince != nil }
            .map { (key: $0.key, record: $0.value) }
            .sorted { $0.record.addedAt > $1.record.addedAt }
    }

    // MARK: - 启动同步

    /// 用一轮扫描结果校正记录，并清掉确认已经消失太久的。
    ///
    /// - Parameter presence: 记录键 → 邮件当前路径（`native:xxx`）。
    ///   **不在表里就等于找不到**，所以调用方必须保证这是一轮完整扫描的结果；
    ///   扫描失败时应该干脆不调用，而不是传空表进来——那会把所有锁一次清光。
    /// - Returns: 本轮清掉的记录数
    @discardableResult
    func reconcile(presence: [String: String], now: Date = .now) -> Int {
        var next: [String: GuardRecord] = [:]
        var removed = 0
        var dirty = false

        for (id, record) in messages {
            var updated = record

            if let path = presence[id] {
                // 还在：清掉失效标记；挪了邮箱的顺手把路径更新掉，下次快速判断才准
                if updated.missingSince != nil {
                    updated.missingSince = nil
                    dirty = true
                }
                if updated.pathHint != path {
                    updated.pathHint = path
                    dirty = true
                }
            } else if updated.missingSince == nil {
                updated.missingSince = now
                dirty = true
            } else if now.timeIntervalSince(updated.missingSince ?? now) > Self.ttl {
                removed += 1
                dirty = true
                continue
            }

            next[id] = updated
        }

        if dirty {
            messages = next
            save()
        }
        return removed
    }

    // MARK: - 持久化

    private func save() {
        let state = State(accounts: accounts, messages: messages)
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
