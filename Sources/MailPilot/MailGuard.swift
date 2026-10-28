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
        setLocked(locked, for: [message])
    }

    /// 批量上锁 / 解锁。**只写一次盘**——多选可能上千封，
    /// 逐条保存会把 UserDefaults 写成瓶颈。
    func setLocked(_ locked: Bool, for targets: [Message]) {
        var dirty = false
        for message in targets {
            let id = key(for: message)
            guard !id.isEmpty else { continue }
            if locked {
                // 已锁的保持原记录：别把 addedAt 刷成今天，设置页的排序会乱
                if messages[id]?.level != .locked {
                    messages[id] = GuardRecord(
                        level: .locked,
                        subject: message.subject,
                        addedAt: Date(),
                        missingSince: nil,
                        pathHint: message.id
                    )
                    dirty = true
                }
            } else if messages.removeValue(forKey: id) != nil {
                dirty = true
            }
        }
        if dirty { save() }
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

    // MARK: - 问答历史回放

    /// 一轮问答历史能否回放给**不可信**模型。
    ///
    /// 为什么要按「当前」的锁重新核对：用户可能在上次问答之后才锁了某封邮件，
    /// 上一轮的回答里就可能带着它的内容。脱敏按规则走，管不了访问控制。
    /// 原则是**证明不了安全就不带**——历史里的一句原话，可能就是今天才上锁的那封。
    ///
    /// 抽在这里而不是 AppModel：只依赖守卫状态，测试不必拉起整个 App。
    /// - Parameters:
    ///   - accountIDs: 这轮当时选的账号；nil = 所有账号
    ///   - citationsTracked: 这轮是否记录了完整引用清单（老记录没有）
    ///   - citations: 引用邮件的（守卫键 Message-ID, 账号 ID）
    func canReplayHistory(accountIDs: [String]?,
                          citationsTracked: Bool,
                          citations: [(key: String?, accountID: String?)]) -> Bool {
        // 1. 账号级：这轮的范围里现在有上锁的账号 → 答案可能带过它的邮件或元信息
        if let accountIDs {
            if accountIDs.contains(where: { isAccountLocked($0) }) { return false }
        } else if lockedAccountCount > 0 {
            // nil = 「所有账号」；老记录也解不出这个字段，只能按最严处理
            return false
        }

        // 2. 没有引用清单的老记录：只要现在有邮件锁，就无法证明答案没引用过它
        if !citationsTracked {
            return lockedMessageCount == 0
        }

        // 3. 逐条核对引用：账号锁或邮件锁任一命中都不带
        for citation in citations {
            if let accountID = citation.accountID, isAccountLocked(accountID) { return false }
            if let key = citation.key {
                if messages[key]?.level == .locked { return false }
            } else if lockedMessageCount > 0 {
                // 老引用没有守卫键，同样证明不了
                return false
            }
        }
        return true
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
