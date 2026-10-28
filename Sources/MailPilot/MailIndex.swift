import Foundation
import SQLite3

/// 索引里的一条邮件元数据。
///
/// `body` 只用于全文索引，查询结果不会回传——正文永远从 `.emlx` 现读，
/// 索引里不留副本（除了 FTS 需要的那一段，见 `bodyLimit`）。
struct IndexedMessage {
    var path: String          // `native:<相对路径>`
    var mailboxID: String
    var accountID: String
    var messageID: String
    var subject: String
    var sender: String
    var senderEmail: String
    var date: Date
    var preview: String
    var body: String
    var mtime: Double
    var size: Int
    /// 线程根（References 的第一个 / In-Reply-To / 自己的 Message-ID）
    var threadRoot: String
}

/// 邮件元数据索引（SQLite）。
///
/// 存在的理由：现在每次列表、每次搜索都要重新解析 `.emlx`。
/// 一万封邮件按 24KB 读一遍就是 240MB I/O。索引只做两件事：
/// 1. 记住「哪个文件已经解析过」（path + mtime + size 三元组），下次只 stat
/// 2. 让搜索能在内存级速度上跑（FTS5）
///
/// **索引是缓存，可以随便删**：用户的决策（上锁、豁免）存在别处，不在这里。
final class MailIndex {

    /// FTS 里最多保留的正文长度。全文索引体积约为正文 3 倍，
    /// 不截断的话一个几万封的邮箱能撑出几个 G
    static let bodyLimit = 16_000

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "mailpilot.index")
    private let path: String

    init?(fileURL: URL) {
        path = fileURL.path
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard sqlite3_open_v2(path, &db,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                              nil) == SQLITE_OK else { return nil }
        guard createSchema() else {
            sqlite3_close(db)
            db = nil
            return nil
        }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - 建表

    private func createSchema() -> Bool {
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA synchronous=NORMAL;")

        // 索引是缓存：结构变了就整份重建，不做迁移
        var version = 0
        query("PRAGMA user_version;", []) { version = Int(sqlite3_column_int($0, 0)) }
        if version != 0, version != Self.schemaVersion {
            exec("DROP TABLE IF EXISTS messages;")
            exec("DROP TABLE IF EXISTS fts;")
        }

        exec("""
        CREATE TABLE IF NOT EXISTS messages (
            path          TEXT PRIMARY KEY,
            mailbox_id    TEXT NOT NULL,
            account_id    TEXT NOT NULL,
            message_id    TEXT,
            thread_root   TEXT,
            subject       TEXT,
            sender        TEXT,
            sender_email  TEXT,
            date          REAL,
            preview       TEXT,
            mtime         REAL,
            size          INTEGER,
            missing_since REAL
        );
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_msg_box ON messages(mailbox_id, date DESC);")
        exec("CREATE INDEX IF NOT EXISTS idx_msg_mid ON messages(message_id);")
        // trigram 才能切中文；unicode61 会把整句当成一个词，中文查询直接失效
        exec("""
        CREATE VIRTUAL TABLE IF NOT EXISTS fts USING fts5(
            path UNINDEXED, subject, sender, body, tokenize='trigram'
        );
        """)
        exec("PRAGMA user_version = \(Self.schemaVersion);")
        return ftsAvailable()
    }

    private static let schemaVersion = 2

    private func ftsAvailable() -> Bool {
        guard let db else { return false }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db,
                                 "SELECT sqlite_compileoption_used('ENABLE_FTS5');",
                                 -1, &statement, nil) == SQLITE_OK else { return false }
        return sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int(statement, 0) == 1
    }

    // MARK: - 写入

    /// 解析过一批文件后写回索引。同 path 覆盖，FTS 同步替换
    func upsert(_ rows: [IndexedMessage]) {
        guard !rows.isEmpty else { return }
        queue.sync {
            exec("BEGIN;")
            for row in rows {
                let bodyForIndex = String(row.body.prefix(Self.bodyLimit))
                run("""
                INSERT INTO messages
                    (path, mailbox_id, account_id, message_id, thread_root, subject, sender, sender_email,
                     date, preview, mtime, size, missing_since)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,NULL)
                ON CONFLICT(path) DO UPDATE SET
                    mailbox_id=excluded.mailbox_id, account_id=excluded.account_id,
                    message_id=excluded.message_id, thread_root=excluded.thread_root,
                    subject=excluded.subject,
                    sender=excluded.sender, sender_email=excluded.sender_email,
                    date=excluded.date, preview=excluded.preview,
                    mtime=excluded.mtime, size=excluded.size, missing_since=NULL;
                """, [
                    row.path, row.mailboxID, row.accountID, row.messageID, row.threadRoot,
                    row.subject, row.sender, row.senderEmail,
                    String(row.date.timeIntervalSince1970), row.preview,
                    String(row.mtime), String(row.size),
                ])

                run("DELETE FROM fts WHERE path = ?;", [row.path])
                run("INSERT INTO fts (path, subject, sender, body) VALUES (?,?,?,?);",
                    [row.path, row.subject, row.sender + " " + row.senderEmail, bodyForIndex])
            }
            exec("COMMIT;")
        }
    }

    struct IndexedFile {
        var mtime: Double
        var size: Int
        var missingSince: Double?
    }

    /// 本邮箱里已解析过的路径及其文件状态（用于跳过重复解析）
    func indexedFiles(mailboxID: String) -> [String: IndexedFile] {
        queue.sync { indexedFilesLocked(mailboxID: mailboxID) }
    }

    private func indexedFilesLocked(mailboxID: String) -> [String: IndexedFile] {
        var out: [String: IndexedFile] = [:]
        query("SELECT path, mtime, size, missing_since FROM messages WHERE mailbox_id = ?;",
              [mailboxID]) { statement in
            let missing = sqlite3_column_type(statement, 3) == SQLITE_NULL
                ? nil
                : sqlite3_column_double(statement, 3)
            out[text(statement, 0)] = IndexedFile(mtime: sqlite3_column_double(statement, 1),
                                                  size: Int(sqlite3_column_int(statement, 2)),
                                                  missingSince: missing)
        }
        return out
    }

    /// 这一轮没见到的文件记一笔，但**不删**——Mail 迁移、IMAP 重同步都会让文件短暂消失
    func markMissing(notIn paths: Set<String>, mailboxID: String, now: Date = .now) {
        queue.sync {
            let existing = indexedFilesLocked(mailboxID: mailboxID)
            let stamp = String(now.timeIntervalSince1970)
            for (path, info) in existing {
                if !paths.contains(path), info.missingSince == nil {
                    run("UPDATE messages SET missing_since = ? WHERE path = ?;", [stamp, path])
                } else if paths.contains(path), info.missingSince != nil {
                    run("UPDATE messages SET missing_since = NULL WHERE path = ?;", [path])
                }
            }
        }
    }

    /// 消失超过 TTL 的清掉（含 FTS）
    @discardableResult
    func purgeMissing(olderThan cutoff: Date) -> Int {
        queue.sync {
            var doomed: [String] = []
            query("SELECT path FROM messages WHERE missing_since IS NOT NULL AND missing_since < ?;",
                  [String(cutoff.timeIntervalSince1970)]) { statement in
                doomed.append(text(statement, 0))
            }
            guard !doomed.isEmpty else { return 0 }
            exec("BEGIN;")
            for path in doomed {
                run("DELETE FROM messages WHERE path = ?;", [path])
                run("DELETE FROM fts WHERE path = ?;", [path])
            }
            exec("COMMIT;")
            return doomed.count
        }
    }

    // MARK: - 查询

    func messages(mailboxID: String, limit: Int) -> [IndexedMessage] {
        queue.sync {
            var rows: [IndexedMessage] = []
            query("""
            SELECT path, mailbox_id, account_id, message_id, thread_root, subject, sender, sender_email, date, preview
            FROM messages
            WHERE mailbox_id = ? AND missing_since IS NULL
            ORDER BY date DESC LIMIT ?;
            """, [mailboxID, String(limit)]) { statement in
                rows.append(row(from: statement))
            }
            return rows
        }
    }

    /// 全文搜索。FTS5 的 trigram 最少要 3 个字符，更短的查询退回 LIKE
    func search(_ keyword: String, limit: Int) -> [IndexedMessage] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        return queue.sync {
            var rows: [IndexedMessage] = []
            if trimmed.count >= 3 {
                // FTS5 的 MATCH 里，双引号包起来才按整句短语匹配
                let phrase = "\"" + trimmed.replacingOccurrences(of: "\"", with: "") + "\""
                query("""
                SELECT m.path, m.mailbox_id, m.account_id, m.message_id, m.thread_root, m.subject,
                       m.sender, m.sender_email, m.date, m.preview
                FROM fts f JOIN messages m ON m.path = f.path
                WHERE fts MATCH ? AND m.missing_since IS NULL
                ORDER BY m.date DESC LIMIT ?;
                """, [phrase, String(limit)]) { statement in
                    rows.append(row(from: statement))
                }
            }
            if rows.isEmpty {
                rows = []
                let pattern = "%\(trimmed)%"
                query("""
                SELECT path, mailbox_id, account_id, message_id, thread_root, subject, sender, sender_email, date, preview
                FROM messages
                WHERE missing_since IS NULL
                  AND (subject LIKE ? OR sender LIKE ? OR sender_email LIKE ? OR preview LIKE ?)
                ORDER BY date DESC LIMIT ?;
                """, [pattern, pattern, pattern, pattern, String(limit)]) { statement in
                    rows.append(row(from: statement))
                }
            }
            return rows
        }
    }

    /// 全部 Message-ID（上锁记录的存活检查用）
    func allMessageIDs() -> Set<String> {
        queue.sync {
            var ids = Set<String>()
            query("SELECT message_id FROM messages WHERE message_id IS NOT NULL AND message_id <> '';",
                  []) { statement in
                ids.insert(text(statement, 0))
            }
            return ids
        }
    }

    func rowCount() -> Int {
        queue.sync {
            var count = 0
            query("SELECT COUNT(*) FROM messages;", []) { statement in
                count = Int(sqlite3_column_int(statement, 0))
            }
            return count
        }
    }

    /// 索引对应的数据库大小，设置页展示用
    func fileSize() -> Int {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
    }

    // MARK: - 底层

    private func row(from statement: OpaquePointer?) -> IndexedMessage {
        IndexedMessage(
            path: text(statement, 0),
            mailboxID: text(statement, 1),
            accountID: text(statement, 2),
            messageID: text(statement, 3),
            subject: text(statement, 5),
            sender: text(statement, 6),
            senderEmail: text(statement, 7),
            date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 8)),
            preview: text(statement, 9),
            body: "",
            mtime: 0,
            size: 0,
            threadRoot: text(statement, 4)
        )
    }

    private func text(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let cString = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: cString)
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        guard let db else { return false }
        return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private func run(_ sql: String, _ values: [String]) {
        guard let db else { return }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        for (offset, value) in values.enumerated() {
            sqlite3_bind_text(statement, Int32(offset + 1), value, -1, SQLITE_TRANSIENT)
        }
        sqlite3_step(statement)
    }

    private func query(_ sql: String, _ values: [String], _ each: (OpaquePointer?) -> Void) {
        guard let db else { return }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        for (offset, value) in values.enumerated() {
            sqlite3_bind_text(statement, Int32(offset + 1), value, -1, SQLITE_TRANSIENT)
        }
        while sqlite3_step(statement) == SQLITE_ROW {
            each(statement)
        }
    }
}

/// SQLite 要求调用方声明字符串的生命周期；传 -1 让 SQLite 自己拷贝一份
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// 目录扫描 → 索引行。
///
/// 单独抽出来是为了能脱离 `NativeMailStore` 测试：
/// 给一个目录和一批已知状态，返回「这次需要解析哪些」和「现在还剩哪些」。
enum MailIndexer {

    struct ScanResult {
        /// 新增或变更、需要写进索引的
        var fresh: [IndexedMessage]
        /// 这一轮在磁盘上见到的全部路径
        var present: Set<String>
    }

    static func scan(directory: URL,
                     root: URL,
                     mailboxID: String,
                     accountID: String,
                     known: [String: MailIndex.IndexedFile],
                     includeBody: Bool = false) -> ScanResult {
        var fresh: [IndexedMessage] = []
        var present = Set<String>()
        let base = root.standardizedFileURL.path

        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ScanResult(fresh: [], present: [])
        }

        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            guard name.hasSuffix(".emlx") || name.hasSuffix(".emlx.partial") else { continue }

            var path = url.standardizedFileURL.path
            if path.hasPrefix(base) {
                path = String(path.dropFirst(base.count))
                if path.hasPrefix("/") { path.removeFirst() }
            }
            let id = "native:" + path
            present.insert(id)

            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let mtime = (values?.contentModificationDate ?? .distantPast).timeIntervalSince1970
            let size = values?.fileSize ?? 0

            // 三重比对：路径已知 + 时间没变 + 大小没变 → 不必再解析
            if let cached = known[id],
               abs(cached.mtime - mtime) < 1,
               cached.size == size,
               cached.missingSince == nil {
                continue
            }

            guard let parsed = EmlxParser.parse(url: url, includeBody: includeBody) else { continue }
            fresh.append(IndexedMessage(
                path: id,
                mailboxID: mailboxID,
                accountID: accountID,
                messageID: parsed.messageID,
                subject: parsed.subject,
                sender: parsed.senderName,
                senderEmail: parsed.senderEmail,
                date: parsed.date ?? Date(timeIntervalSince1970: mtime),
                preview: String(parsed.body.prefix(120)),
                body: parsed.body,
                mtime: mtime,
                size: size,
                threadRoot: parsed.threadRoot
            ))
        }

        return ScanResult(fresh: fresh, present: present)
    }
}
