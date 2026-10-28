import Foundation

var passed = 0
var failed = 0

func check(_ condition: Bool, _ name: String) {
    if condition { passed += 1; print("  ✅ \(name)") }
    else { failed += 1; print("  ❌ \(name)") }
}

// MARK: - 造一个假的信箱目录

// 每次跑用独立临时目录，互不干扰
let workDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("mailpilot-index-test-\(UUID().uuidString)", isDirectory: true)
try! FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: workDir) }

let base = workDir.appendingPathComponent("mail", isDirectory: true)
let boxDir = base.appendingPathComponent("INBOX.mbox/Data/1/Messages", isDirectory: true)
try! FileManager.default.createDirectory(at: boxDir, withIntermediateDirectories: true)

func writeEmlx(name: String,
               subject: String,
               from: String,
               messageID: String,
               date: String,
               body: String) {
    let mime = """
    Subject: \(subject)
    From: \(from)
    To: me@example.com
    Date: \(date)
    Message-ID: \(messageID)
    Content-Type: text/plain; charset=utf-8

    \(body)
    """
    let data = mime.data(using: .utf8)!
    var file = Data("\(data.count)\n".utf8)
    file.append(data)
    try! file.write(to: boxDir.appendingPathComponent(name))
}

writeEmlx(name: "1.emlx", subject: "Q4 采购合同讨论", from: "Alice <alice@corp.com>",
          messageID: "<m1@x>", date: "Mon, 27 Oct 2026 10:00:00 +0800",
          body: "合同金额是 128 万元，请确认。")
writeEmlx(name: "2.emlx", subject: "Weekly report", from: "Bob <bob@other.com>",
          messageID: "<m2@x>", date: "Tue, 28 Oct 2026 09:00:00 +0800",
          body: "本期没有异常。")
writeEmlx(name: "3.emlx", subject: "会议纪要", from: "Carol <carol@corp.com>",
          messageID: "<m3@x>", date: "Wed, 29 Oct 2026 11:00:00 +0800",
          body: "讨论了排期与合同细节。")

// MARK: - 1. 首次扫描

print("\n[1] 首次扫描")
let indexURL = workDir.appendingPathComponent("index.sqlite")

guard let index = MailIndex(fileURL: indexURL) else {
    print("索引打不开，终止")
    exit(1)
}

let first = MailIndexer.scan(directory: boxDir, root: base,
                             mailboxID: "mb-in", accountID: "acc",
                             known: [:])
check(first.fresh.count == 3, "首次扫描解析 3 封")
check(first.present.count == 3, "记录到 3 个存在的路径")
index.upsert(first.fresh)
index.markMissing(notIn: first.present, mailboxID: "mb-in")
check(index.rowCount() == 3, "索引里 3 行")

// MARK: - 2. 列表查询

print("\n[2] 列表查询")
let rows = index.messages(mailboxID: "mb-in", limit: 10)
check(rows.count == 3, "查回 3 封")
check(rows.first?.subject == "会议纪要", "按日期倒序，最新在前")
check(rows.first?.messageID == "<m3@x>", "Message-ID 正确")

// MARK: - 3. 搜索

print("\n[3] 搜索")
let chinese = index.search("合同", limit: 10)
check(chinese.count == 2, "两字中文查询走 LIKE 回退，命中 2 封")
let fts = index.search("合同讨论", limit: 10)
check(fts.count >= 1, "四字查询走 trigram，至少命中 1 封")
let english = index.search("Weekly", limit: 10)
check(english.count == 1, "英文查询命中 1 封")

// MARK: - 4. 增量扫描不重复解析

print("\n[4] 增量")
let known = index.indexedFiles(mailboxID: "mb-in")
let second = MailIndexer.scan(directory: boxDir, root: base,
                              mailboxID: "mb-in", accountID: "acc",
                              known: known)
check(second.fresh.isEmpty, "文件没变时不再解析（fresh 为空）")
check(second.present.count == 3, "仍看到 3 个路径")

// MARK: - 5. 删除检测

print("\n[5] 删除与墓碑")
try! FileManager.default.removeItem(at: boxDir.appendingPathComponent("2.emlx"))
let third = MailIndexer.scan(directory: boxDir, root: base,
                             mailboxID: "mb-in", accountID: "acc",
                             known: index.indexedFiles(mailboxID: "mb-in"))
check(third.present.count == 2, "磁盘上只剩 2 个")
index.markMissing(notIn: third.present, mailboxID: "mb-in")
check(index.messages(mailboxID: "mb-in", limit: 10).count == 2, "缺失的文件不再返回")
check(index.search("Weekly", limit: 10).isEmpty, "缺失的文件也搜不到")
check(index.indexedFiles(mailboxID: "mb-in").count == 3, "记录还在（墓碑），没有立刻删")

// MARK: - 6. TTL 清理

print("\n[6] TTL 清理")
let purged = index.purgeMissing(olderThan: Date().addingTimeInterval(60))
check(purged == 1, "超过期限的墓碑被清掉")
check(index.indexedFiles(mailboxID: "mb-in").count == 2, "清理后只剩 2 条")

// MARK: - 7. 文件恢复后自动复活

print("\n[7] 恢复")
writeEmlx(name: "4.emlx", subject: "新邮件", from: "Dan <dan@corp.com>",
          messageID: "<m4@x>", date: "Thu, 30 Oct 2026 12:00:00 +0800",
          body: "新到一封。")
let fourth = MailIndexer.scan(directory: boxDir, root: base,
                              mailboxID: "mb-in", accountID: "acc",
                              known: index.indexedFiles(mailboxID: "mb-in"))
index.upsert(fourth.fresh)
index.markMissing(notIn: fourth.present, mailboxID: "mb-in")
check(index.messages(mailboxID: "mb-in", limit: 10).count == 3, "新增文件后回到 3 封")

print("\n========================================")
print("通过 \(passed) · 失败 \(failed)")
exit(failed == 0 ? 0 : 1)
