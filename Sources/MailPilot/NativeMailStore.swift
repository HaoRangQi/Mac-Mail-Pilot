import Foundation

/// 直接读 `~/Library/Mail` 下的 .emlx。不做全量索引：列表按修改时间取最近 N 封，正文按需解析。
final class NativeMailStore: MailStore {
    let isDemo = false

    private let root: URL
    private var boxes: [Mailbox] = []
    private var accountNames: [String: String] = [:]
    private var accountNameCache: [String: String] = [:]
    private var accountEmailCache: [String: String] = [:]

    init?() {
        guard case .authorized = MailAccess.status(),
              let version = MailAccess.versionDirectory() else { return nil }
        root = version
        loadAccountNames()
        boxes = discoverMailboxes()
        guard !boxes.isEmpty else { return nil }
        writeDiagnostics()
    }

    // MARK: - MailStore

    func accounts() async throws -> [Account] {
        var result: [Account] = []
        var seen = Set<String>()
        for box in boxes where !seen.contains(box.accountID) {
            seen.insert(box.accountID)
            result.append(Account(
                id: box.accountID,
                name: accountDisplayName(box.accountID),
                email: "",
                provider: "mail"
            ))
        }
        return result
    }

    func mailboxes() async throws -> [Mailbox] {
        for index in boxes.indices where boxes[index].total == 0 {
            boxes[index].total = fileCount(in: boxes[index])
        }
        return boxes
    }

    func messages(mailboxID: String, limit: Int) async throws -> [Message] {
        if let smart = SmartBox(rawValue: mailboxID) {
            return smartMessages(smart, limit: limit)
        }
        guard let box = boxes.first(where: { $0.id == mailboxID }) else { return [] }
        let dir = directory(for: box)
        let files = emlxFiles(in: dir).sorted { $0.1 > $1.1 }.prefix(limit)
        return files.compactMap { makeMessage(url: $0.0, mailbox: box, includeBody: false) }
    }

    func message(id: String) async throws -> Message? {
        let rel = String(id.dropFirst("native:".count))
        let url = root.appendingPathComponent(rel)
        guard let box = box(forFile: url) else { return nil }
        return makeMessage(url: url, mailbox: box, includeBody: true)
    }

    func search(_ query: String, limit: Int) async throws -> [Message] {
        let q = query.lowercased()
        guard !q.isEmpty else { return [] }
        var results: [Message] = []
        for box in boxes where box.role == .inbox || box.role == .archive {
            let files = emlxFiles(in: directory(for: box)).sorted { $0.1 > $1.1 }.prefix(400)
            for (url, _) in files {
                guard let message = makeMessage(url: url, mailbox: box, includeBody: false) else { continue }
                if message.subject.lowercased().contains(q)
                    || message.sender.lowercased().contains(q)
                    || message.senderEmail.lowercased().contains(q)
                    || message.body.lowercased().contains(q) {
                    results.append(message)
                    if results.count >= limit { return results }
                }
            }
        }
        return results
    }

    func badgeCounts() async throws -> [String: Int] {
        var counts: [String: Int] = [:]
        counts[SmartBox.allInbox.rawValue] = boxes.filter { $0.role == .inbox }.reduce(0) { $0 + fileCount(in: $1) }
        counts[SmartBox.allSent.rawValue] = boxes.filter { $0.role == .sent }.reduce(0) { $0 + fileCount(in: $1) }
        counts[SmartBox.allDrafts.rawValue] = boxes.filter { $0.role == .drafts }.reduce(0) { $0 + fileCount(in: $1) }
        counts[SmartBox.allFlagged.rawValue] = 0
        counts[SmartBox.today.rawValue] = 0
        return counts
    }

    // MARK: - 删除（移入「邮件」App 废纸篓）

    func moveToTrash(_ message: Message) async throws {
        guard !message.messageID.isEmpty else {
            throw MailMutatorError.missingMessageID
        }
        guard let box = boxes.first(where: { $0.id == message.mailboxID }) else {
            throw MailMutatorError.notFound("找不到这封邮件所在的邮箱")
        }
        try await MailMutator.moveToTrash(
            accountID: message.accountID,
            accountName: accountDisplayName(message.accountID),
            accountEmail: accountEmail(message.accountID),
            mailboxName: box.rawName,
            messageID: message.messageID
        )
    }

    // MARK: - 聚合邮箱

    private func smartMessages(_ smart: SmartBox, limit: Int) -> [Message] {
        if smart == .allFlagged { return [] }

        let startOfDay = Calendar.current.startOfDay(for: Date())
        var items: [(URL, Date, Mailbox)] = []

        for box in boxes {
            let include: Bool
            switch smart {
            case .allInbox: include = box.role == .inbox
            case .allSent: include = box.role == .sent
            case .allDrafts: include = box.role == .drafts
            case .today: include = box.role == .inbox
            case .allFlagged: include = false
            }
            guard include else { continue }
            for file in emlxFiles(in: directory(for: box)) {
                if smart == .today, file.1 < startOfDay { continue }
                items.append((file.0, file.1, box))
            }
        }

        return items.sorted { $0.1 > $1.1 }.prefix(limit)
            .compactMap { makeMessage(url: $0.0, mailbox: $0.2, includeBody: false) }
    }

    // MARK: - 账户名

    /// 账户的邮箱地址（AppleScript 按地址回退定位账户用）
    private func accountEmail(_ accountID: String) -> String {
        if let cached = accountEmailCache[accountID] { return cached }
        var resolved = plistAccountEmail(accountID) ?? inferAccountAddress(accountID) ?? ""
        accountEmailCache[accountID] = resolved
        return resolved
    }

    private func accountDisplayName(_ accountID: String) -> String {
        if let cached = accountNameCache[accountID] { return cached }
        if let known = accountNames[accountID], !known.isEmpty {
            accountNameCache[accountID] = known
            return known
        }
        if let fromPlist = plistAccountName(accountID) {
            accountNameCache[accountID] = fromPlist
            return fromPlist
        }
        if let inferred = inferAccountAddress(accountID) {
            accountNameCache[accountID] = inferred
            return inferred
        }
        let fallback = "账户 " + String(accountID.prefix(6)).lowercased()
        accountNameCache[accountID] = fallback
        return fallback
    }

    /// 只取邮箱地址，不给显示名兜底
    private func plistAccountEmail(_ accountID: String) -> String? {
        let dir = root.appendingPathComponent(accountID)
        for name in ["Info.plist", "Account.plist", "AccountInfo.plist", "Mailbox.plist"] {
            let url = dir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
                  let dict = object as? [String: Any] else { continue }
            for key in ["EmailAddresses", "Email", "Address", "Username", "AccountAddress"] {
                if let value = dict[key] as? String, value.contains("@") {
                    return value.lowercased()
                }
                if let list = dict[key] as? [String], let first = list.first, first.contains("@") {
                    return first.lowercased()
                }
            }
        }
        return nil
    }

    /// 尝试从账户目录里的 plist 读邮箱地址
    private func plistAccountName(_ accountID: String) -> String? {
        let dir = root.appendingPathComponent(accountID)
        for name in ["Info.plist", "Account.plist", "AccountInfo.plist", "Mailbox.plist"] {
            let url = dir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
                  let dict = object as? [String: Any] else { continue }
            for key in ["AccountName", "EmailAddresses", "Email", "Address", "Username", "AccountAddress"] {
                if let value = dict[key] as? String, value.contains("@") {
                    return value.lowercased()
                }
                if let list = dict[key] as? [String], let first = list.first, first.contains("@") {
                    return first.lowercased()
                }
            }
        }
        return nil
    }

    /// 依次尝试：已发送的 From → Delivered-To → 收件箱 To 的众数
    private func inferAccountAddress(_ accountID: String) -> String? {
        let accountBoxes = boxes.filter { $0.accountID == accountID }
        var scores: [String: Int] = [:]

        for box in accountBoxes where box.role == .sent {
            for (url, _) in emlxFiles(in: directory(for: box)).sorted(by: { $0.1 > $1.1 }).prefix(6) {
                guard let parsed = EmlxParser.parse(url: url, includeBody: false) else { continue }
                let address = parsed.senderEmail.lowercased()
                if address.contains("@") { scores[address, default: 0] += 5 }
            }
        }

        for box in accountBoxes.prefix(3) {
            for (url, _) in emlxFiles(in: directory(for: box)).sorted(by: { $0.1 > $1.1 }).prefix(4) {
                guard let parsed = EmlxParser.parse(url: url, includeBody: false) else { continue }
                let address = parsed.deliveredTo.lowercased()
                if address.contains("@") { scores[address, default: 0] += 3 }
            }
        }

        if let inbox = accountBoxes.first(where: { $0.role == .inbox }) {
            for (url, _) in emlxFiles(in: directory(for: inbox)).sorted(by: { $0.1 > $1.1 }).prefix(10) {
                guard let parsed = EmlxParser.parse(url: url, includeBody: false) else { continue }
                for address in parsed.to where address.contains("@") {
                    scores[address.lowercased(), default: 0] += 1
                }
            }
        }

        return scores.max { $0.value < $1.value }?.key
    }

    // MARK: - 诊断

    /// 把目录结构与样本头部写到 Application Support，方便排查账户命名问题
    func writeDiagnostics() {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let dir = base.appendingPathComponent("MailPilot", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("diagnose.txt")

        var lines: [String] = []
        lines.append("root: \(root.path)")
        lines.append("accounts: \(Set(boxes.map(\.accountID)).count), mailboxes: \(boxes.count)")
        lines.append("")

        let accountDirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for accountDir in accountDirs where accountDir.lastPathComponent != "MailData" {
            let id = accountDir.lastPathComponent
            lines.append("[account] \(id) | display=\(accountDisplayName(id)) | email=\(accountEmail(id))")
            let entries = (try? fm.contentsOfDirectory(atPath: accountDir.path)) ?? []
            lines.append("  entries: \(entries.prefix(12).joined(separator: ", "))")

            let boxesOfAccount = boxes.filter { $0.accountID == id }
            for box in boxesOfAccount {
                lines.append("  - \(box.name) | raw=\(box.rawName) | role=\(box.role.rawValue) | files=\(fileCount(in: box))")
            }

            let sampleBox = boxesOfAccount.first { $0.role == .inbox } ?? boxesOfAccount.first
            if let sampleBox {
                for (url, _) in emlxFiles(in: directory(for: sampleBox)).sorted(by: { $0.1 > $1.1 }).prefix(2) {
                    guard let parsed = EmlxParser.parse(url: url, includeBody: false) else { continue }
                    lines.append("  sample from=\(parsed.senderEmail) to=\(parsed.to.joined(separator: ",")) delivered=\(parsed.deliveredTo) msgid=\(parsed.messageID)")
                }
            }
            lines.append("")
        }

        try? lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    // MARK: - 目录发现

    private func loadAccountNames() {
        let plist = root.appendingPathComponent("MailData/Accounts.plist")
        guard let data = try? Data(contentsOf: plist),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let list = object["MailAccounts"] as? [[String: Any]] else { return }
        for account in list {
            guard let uid = account["UniqueId"] as? String else { continue }
            if let name = account["AccountName"] as? String, !name.isEmpty {
                accountNames[uid] = name
            } else if let emails = account["EmailAddresses"] as? [String], let first = emails.first {
                accountNames[uid] = first
            }
        }
    }

    private func fallbackAccountName(_ id: String) -> String {
        "账户 " + String(id.prefix(6))
    }

    private func discoverMailboxes() -> [Mailbox] {
        let fm = FileManager.default
        guard let accounts = try? fm.contentsOfDirectory(at: root,
                                                         includingPropertiesForKeys: [.isDirectoryKey],
                                                         options: [.skipsHiddenFiles]) else { return [] }
        var result: [Mailbox] = []
        for account in accounts {
            let accountID = account.lastPathComponent
            guard accountID != "MailData", accountID != "MailData.plist" else { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: account.path, isDirectory: &isDir), isDir.boolValue else { continue }
            for boxURL in findMboxDirectories(in: account, depth: 0) {
                let rel = relativePath(boxURL)
                let name = boxURL.deletingPathExtension().lastPathComponent
                result.append(Mailbox(
                    id: "native:" + rel,
                    accountID: accountID,
                    name: displayName(for: name),
                    rawName: name,
                    role: role(for: name)
                ))
            }
        }
        return result.sorted { $0.name < $1.name }
    }

    private func findMboxDirectories(in parent: URL, depth: Int) -> [URL] {
        guard depth < 3 else { return [] }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: parent,
                                                        includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles]) else { return [] }
        var found: [URL] = []
        for entry in entries {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let name = entry.lastPathComponent
            if name.hasSuffix(".mbox") || name.hasSuffix(".imapmbox") {
                found.append(entry)
                found.append(contentsOf: findMboxDirectories(in: entry, depth: depth + 1))
            }
        }
        return found
    }

    private func displayName(for raw: String) -> String {
        let map: [String: String] = [
            "INBOX": "收件箱",
            "SENT": "已发送", "SENT MESSAGES": "已发送", "SENT MAIL": "已发送",
            "DRAFTS": "草稿", "DRAFT": "草稿",
            "TRASH": "已删除", "DELETED MESSAGES": "已删除", "BIN": "已删除",
            "JUNK": "垃圾邮件", "SPAM": "垃圾邮件",
            "ARCHIVE": "归档",
            "ALL MAIL": "所有邮件",
            "IMPORTANT": "重要",
            "STARRED": "星标",
            "BLOCKED": "已屏蔽",
            "NOTES": "备忘录",
            "OUTBOX": "发件箱",
            "TEMPLATES": "模板",
        ]
        return map[raw.uppercased()] ?? raw
    }

    private func role(for raw: String) -> Mailbox.Role {
        switch raw.uppercased() {
        case "INBOX": return .inbox
        case "SENT", "SENT MESSAGES", "SENT MAIL": return .sent
        case "DRAFTS", "DRAFT": return .drafts
        case "TRASH", "DELETED MESSAGES", "BIN": return .trash
        case "ARCHIVE": return .archive
        default: return .custom
        }
    }

    // MARK: - 文件

    private func directory(for box: Mailbox) -> URL {
        root.appendingPathComponent(String(box.id.dropFirst("native:".count)))
    }

    private func box(forFile url: URL) -> Mailbox? {
        let path = relativePath(url)
        return boxes.first { path.hasPrefix(String($0.id.dropFirst("native:".count))) }
    }

    private func relativePath(_ url: URL) -> String {
        var path = url.standardizedFileURL.path
        let base = root.standardizedFileURL.path
        if path.hasPrefix(base) {
            path = String(path.dropFirst(base.count))
            if path.hasPrefix("/") { path.removeFirst() }
        }
        return path
    }

    private func emlxFiles(in directory: URL) -> [(URL, Date)] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: directory,
                                             includingPropertiesForKeys: [.contentModificationDateKey],
                                             options: [.skipsHiddenFiles]) else { return [] }
        var files: [(URL, Date)] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            guard name.hasSuffix(".emlx") else { continue }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            files.append((url, date))
        }
        return files
    }

    private func fileCount(in box: Mailbox) -> Int {
        emlxFiles(in: directory(for: box)).count
    }

    private func makeMessage(url: URL, mailbox: Mailbox, includeBody: Bool) -> Message? {
        guard let parsed = EmlxParser.parse(url: url, includeBody: includeBody) else { return nil }
        let rel = relativePath(url)
        return Message(
            id: "native:" + rel,
            accountID: mailbox.accountID,
            mailboxID: mailbox.id,
            subject: parsed.subject,
            sender: parsed.senderName,
            senderEmail: parsed.senderEmail,
            date: parsed.date ?? .distantPast,
            preview: String(parsed.body.prefix(120)),
            body: parsed.body,
            unread: false,
            flagged: false,
            needsReply: false,
            threadID: parsed.messageID,
            messageID: parsed.messageID,
            attachments: []
        )
    }
}
