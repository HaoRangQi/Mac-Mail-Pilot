import Foundation

/// 测试靶不编译 AIPreferences.swift（它会拖进整个 AppModel），
/// 这里给出 Redactor 实际用到的那几个字段
struct CustomRedactionRule {
    var id: String = UUID().uuidString
    var name: String
    var pattern: String
    var enabled: Bool = true
    var hint: String = ""
}

// MARK: - 断言

var passed = 0
var failed = 0

func check(_ condition: Bool, _ name: String) {
    if condition {
        passed += 1
        print("  ✅ \(name)")
    } else {
        failed += 1
        print("  ❌ \(name)")
    }
}

// MARK: - 假数据源

final class FakeStore: MailStore {
    let isDemo = true

    var accountRows: [Account] = []
    var boxRows: [Mailbox] = []
    var messageRows: [Message] = []

    func accounts() async throws -> [Account] { accountRows }
    func mailboxes() async throws -> [Mailbox] { boxRows }

    func messages(mailboxID: String, limit: Int) async throws -> [Message] {
        Array(messageRows.filter { $0.mailboxID == mailboxID }.prefix(limit))
    }

    func message(id: String) async throws -> Message? {
        messageRows.first { $0.id == id }
    }

    func search(_ query: String, limit: Int) async throws -> [Message] {
        let q = query.lowercased()
        return Array(messageRows.filter {
            $0.subject.lowercased().contains(q) || $0.body.lowercased().contains(q)
        }.prefix(limit))
    }

    func moveToTrash(_ message: Message) async throws {
        messageRows.removeAll { $0.id == message.id }
    }

    func setRead(_ read: Bool, for message: Message) async throws {
        guard let index = messageRows.firstIndex(where: { $0.id == message.id }) else { return }
        messageRows[index].unread = !read
    }

    func setFlagged(_ flagged: Bool, for message: Message) async throws {
        guard let index = messageRows.firstIndex(where: { $0.id == message.id }) else { return }
        messageRows[index].flagged = flagged
    }

    func badgeCounts() async throws -> [String: Int] { [:] }
}

func makeMessage(id: String,
                 account: String,
                 mailbox: String,
                 subject: String,
                 body: String = "正文",
                 messageID: String,
                 date: Date = Date()) -> Message {
    Message(
        id: id,
        accountID: account,
        mailboxID: mailbox,
        subject: subject,
        sender: "测试发件人",
        senderEmail: "sender@example.com",
        date: date,
        preview: String(body.prefix(40)),
        body: body,
        messageID: messageID
    )
}

// MARK: - 准备

UserDefaults.standard.removeObject(forKey: "mailpilot.guard.state")

let store = FakeStore()
store.accountRows = [
    Account(id: "acc-a", name: "普通账号", email: "a@example.com"),
    Account(id: "acc-b", name: "工作账号", email: "b@example.com"),
]
store.boxRows = [
    Mailbox(id: "mb-a-in", accountID: "acc-a", name: "收件箱", role: .inbox, total: 2),
    Mailbox(id: "mb-b-in", accountID: "acc-b", name: "收件箱", role: .inbox, total: 1),
]
let normal = makeMessage(id: "native:1", account: "acc-a", mailbox: "mb-a-in",
                         subject: "普通会议纪要", messageID: "<m1@x>")
let secret = makeMessage(id: "native:2", account: "acc-a", mailbox: "mb-a-in",
                         subject: "采购合同", messageID: "<m2@x>")
let workMail = makeMessage(id: "native:3", account: "acc-b", mailbox: "mb-b-in",
                           subject: "合同审批", messageID: "<m3@x>")
store.messageRows = [normal, secret, workMail]

let guards = MailGuardStore()
guards.setLocked(true, for: secret)
guards.setAccountLocked(true, id: "acc-b")

// MARK: - 1. 非可信模型：锁定的邮件不可见

let untrusted = MailAccessScope(trusted: false, guards: guards)
let guarded = GuardedMailStore(inner: store, scope: untrusted)

print("\n[1] 非可信模型")
let searchHits = (try? await guarded.search("合同", limit: 10)) ?? []
check(searchHits.allSatisfy { $0.messageID != "<m2@x>" }, "search 不返回锁定邮件")
check((try? await guarded.message(id: secret.id)) == nil, "getMessage(锁定ID) 返回 nil")
check((try? await guarded.message(id: normal.id)) != nil, "getMessage(普通ID) 正常返回")
let boxes = (try? await guarded.mailboxes()) ?? []
check(!boxes.contains { $0.id == "mb-b-in" }, "listMailboxes 不含锁定账号")
let visibleAccounts = (try? await guarded.accounts()) ?? []
check(!visibleAccounts.contains { $0.id == "acc-b" }, "accounts 不含锁定账号")
// 问答的账号范围也走这条判定：上锁账号从选中集合里被剔掉，名字进不了提示词
check(!untrusted.canRead(accountID: "acc-b"), "不可信模型看不到上锁账号（问答范围过滤用）")

// MARK: - 2. 可信模型：全部可见

print("\n[2] 可信模型")
let trusted = MailAccessScope(trusted: true, guards: guards)
let trustedStore = GuardedMailStore(inner: store, scope: trusted)
let trustedHits = (try? await trustedStore.search("合同", limit: 10)) ?? []
check(trustedHits.count == 2, "可信模型能搜到全部 2 封含「合同」的邮件")
check(trusted.canRead(accountID: "acc-b"), "可信模型可见上锁账号（不额外屏蔽）")
check((try? await trustedStore.message(id: secret.id)) != nil, "可信模型能读锁定邮件")

// MARK: - 3. 写操作同样受锁约束

print("\n[3] 写操作")
var blocked = false
do {
    try await guarded.moveToTrash(secret)
} catch {
    blocked = true
}
check(blocked, "非可信模型删除锁定邮件被拒绝")
check(store.messageRows.contains { $0.id == secret.id }, "被拒绝的删除没有真的执行")

// MARK: - 4. 账号级与邮件级取最严

print("\n[4] 最严格优先")
check(guards.level(for: workMail) == .locked, "账号上锁后其邮件为 locked")
guards.setLocked(false, for: workMail)
check(guards.level(for: workMail) == .locked, "账号上锁后单封解锁无效（不留例外通道）")
guards.setAccountLocked(false, id: "acc-b")
check(guards.level(for: workMail) == .open, "账号解锁后恢复")

// MARK: - 5. TTL 清理

print("\n[5] TTL 清理")
let key = guards.key(for: secret)
let t0 = Date(timeIntervalSince1970: 1_800_000_000)

guards.reconcile(presence: [:], now: t0)
check(guards.messages[key]?.missingSince == t0, "第一次找不到时记下 missingSince")
check(guards.orphanedCount == 1, "失效记录计入概览")

guards.reconcile(presence: [:], now: t0.addingTimeInterval(19 * 86_400))
check(guards.messages[key] != nil, "19 天时保留（还没到期限）")

guards.reconcile(presence: [key: "native:2"], now: t0.addingTimeInterval(19 * 86_400))
check(guards.messages[key]?.missingSince == nil, "邮件重新出现时清除失效标记（废纸篓恢复场景）")

guards.reconcile(presence: [:], now: t0.addingTimeInterval(25 * 86_400))
let removed = guards.reconcile(presence: [:], now: t0.addingTimeInterval(46 * 86_400))
check(removed == 1, "超过 20 天记录被清理")
check(guards.messages[key] == nil, "清理后记录消失")

// MARK: - 6. 路径变化不会误判为删除

print("\n[6] 挪邮箱")
let moved = makeMessage(id: "native:9", account: "acc-a", mailbox: "mb-a-in",
                        subject: "归档的合同", messageID: "<m9@x>")
guards.setLocked(true, for: moved)
let movedKey = guards.key(for: moved)
guards.reconcile(presence: [movedKey: "native:99"], now: t0)
check(guards.messages[movedKey]?.pathHint == "native:99", "扫描到新路径后更新 pathHint")
check(guards.messages[movedKey]?.missingSince == nil, "路径变化的邮件不算失效")

// MARK: - 7. 会话级脱敏（RedactionContext）

print("\n[7] 会话级脱敏")
let ctx = RedactionContext(enabled: true)
let first = ctx.mask("联系 alice@corp.com 或 13800138000")
let second = ctx.mask("再次联系 alice@corp.com")
check(first.contains("⟨邮箱1⟩"), "第一段命中邮箱并分配占位符")
check(second.contains("⟨邮箱1⟩"), "同一实体在第二段复用同一占位符")
check(!second.contains("⟨邮箱2⟩"), "没有重复分配新编号")
check(ctx.mappings.filter { $0.original == "alice@corp.com" }.count == 1, "映射表里同一实体只有一条")
check(ctx.restore("请回复 ⟨邮箱1⟩") == "请回复 alice@corp.com", "最终回答能还原回真值")
check(ctx.mappings.count == 2, "两段合计 2 条映射（邮箱 + 手机号）")

let off = RedactionContext(enabled: false)
check(off.mask("alice@corp.com") == "alice@corp.com", "关闭时不改动任何内容")
check(off.mappings.isEmpty, "关闭时没有映射")

// MARK: - 8. 问答范围（账号 + 时间窗口）

print("\n[8] 问答范围")
let scopeStore = FakeStore()
scopeStore.accountRows = [
    Account(id: "acc-a", name: "普通账号", email: "a@example.com"),
    Account(id: "acc-b", name: "工作账号", email: "b@example.com"),
]
scopeStore.boxRows = [
    Mailbox(id: "mb-a-in", accountID: "acc-a", name: "收件箱", role: .inbox, total: 2),
    Mailbox(id: "mb-b-in", accountID: "acc-b", name: "收件箱", role: .inbox, total: 1),
]
let now = Date()
let todayStart = Calendar.current.startOfDay(for: now)
let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: todayStart) ?? now
let todayMail = makeMessage(id: "scope:1", account: "acc-a", mailbox: "mb-a-in",
                            subject: "今天的合同", messageID: "<s1@x>",
                            date: todayStart.addingTimeInterval(3600))
let oldMail = makeMessage(id: "scope:2", account: "acc-a", mailbox: "mb-a-in",
                          subject: "去年的合同", messageID: "<s2@x>",
                          date: todayStart.addingTimeInterval(-200 * 86_400))
let otherAccountMail = makeMessage(id: "scope:3", account: "acc-b", mailbox: "mb-b-in",
                                   subject: "另一个账号的合同", messageID: "<s3@x>",
                                   date: todayStart.addingTimeInterval(3600))
scopeStore.messageRows = [todayMail, oldMail, otherAccountMail]

let windowed = AskScopeStore(
    inner: scopeStore,
    scope: AskScope(window: DateInterval(start: todayStart, end: tomorrow), accountIDs: ["acc-a"])
)
let windowHits = (try? await windowed.search("合同", limit: 10)) ?? []
check(windowHits.map(\.id) == ["scope:1"], "只返回窗口内、选中账号的邮件")
check((try? await windowed.message(id: oldMail.id)) == nil, "窗口外的邮件按 ID 也读不到")
check((try? await windowed.message(id: otherAccountMail.id)) == nil, "账号外的邮件按 ID 读不到")
check(windowed.scannedCount == 1, "scannedCount 只数真正交出去的邮件")

let scopedBoxes = (try? await windowed.mailboxes()) ?? []
check(!scopedBoxes.contains { $0.accountID == "acc-b" }, "邮箱列表按账号收口")
let scopedAccounts = (try? await windowed.accounts()) ?? []
check(scopedAccounts.map(\.id) == ["acc-a"], "账号列表按选择收口")

var refused = false
do {
    try await windowed.moveToTrash(oldMail)
} catch {
    refused = true
}
check(refused, "窗口外的邮件不能删")
check(scopeStore.messageRows.contains { $0.id == oldMail.id }, "被拒绝的删除没有真的执行")

// 「忽略」+ 所有账号：什么都不该挡
let openScope = AskScopeStore(inner: scopeStore, scope: AskScope(window: nil, accountIDs: nil))
let openHits = (try? await openScope.search("合同", limit: 10)) ?? []
check(openHits.count == 3, "不限范围时三封都能搜到")

// MARK: - 9. 问答历史回放的上锁核对

print("\n[9] 历史回放")
// 用一套干净的状态，避免前面几节留下的锁影响断言
let replayGuards = MailGuardStore()
replayGuards.clearAll()
replayGuards.setLocked(true, for: secret)

check(replayGuards.canReplayHistory(accountIDs: ["acc-a"], citationsTracked: true, citations: []),
      "没读过邮件的轮次可以回放（账号未锁）")
check(!replayGuards.canReplayHistory(accountIDs: ["acc-a"], citationsTracked: true,
                                     citations: [(key: "<m2@x>", accountID: "acc-a")]),
      "引用里含已上锁邮件 → 不回放")
check(replayGuards.canReplayHistory(accountIDs: ["acc-a"], citationsTracked: true,
                                    citations: [(key: "<m1@x>", accountID: "acc-a")]),
      "引用全是未锁邮件 → 可回放")
check(!replayGuards.canReplayHistory(accountIDs: ["acc-a"], citationsTracked: false, citations: []),
      "老记录（无引用清单）+ 存在邮件锁 → 不回放")

replayGuards.setAccountLocked(true, id: "acc-b")
check(!replayGuards.canReplayHistory(accountIDs: ["acc-b"], citationsTracked: true, citations: []),
      "账号上锁 → 该账号的轮次不回放")
check(!replayGuards.canReplayHistory(accountIDs: nil, citationsTracked: true, citations: []),
      "「所有账号」+ 有账号上锁 → 不回放")
check(replayGuards.canReplayHistory(accountIDs: ["acc-a"], citationsTracked: true, citations: []),
      "其他未锁账号的轮次不受影响")
replayGuards.setAccountLocked(false, id: "acc-b")
check(replayGuards.canReplayHistory(accountIDs: nil, citationsTracked: true, citations: []),
      "账号解锁后「所有账号」恢复回放")
replayGuards.setLocked(false, for: secret)
check(replayGuards.canReplayHistory(accountIDs: ["acc-a"], citationsTracked: false, citations: []),
      "没有任何锁时老记录照常回放")

// MARK: - 结果

print("\n========================================")
print("通过 \(passed) · 失败 \(failed)")
exit(failed == 0 ? 0 : 1)
