import Foundation

/// 外发与写操作的审计日志。
///
/// 两条铁律：
/// 1. **只记元数据，绝不记正文**——日志本身不能再变成第二份泄密源
/// 2. **追加写、不阻塞**——记录失败不能影响正常功能
///
/// 按大小轮转：`audit.jsonl` 超过 5MB 就滚成 `audit.1.jsonl`，最多留 3 份。
enum AuditLog {

    struct Entry: Codable {
        var time: Date = Date()
        /// ai / tool / send / delete / deny
        var kind: String
        var action: String
        var provider: String? = nil
        var model: String? = nil
        var accountIDs: [String]? = nil
        var messageIDs: [String]? = nil
        var chars: Int? = nil
        var redactions: Int? = nil
        var confirmed: Bool? = nil
        /// 一句话补充说明，仍然不放正文
        var detail: String? = nil
    }

    private static let queue = DispatchQueue(label: "mailpilot.audit")
    private static let maxBytes = 5 * 1024 * 1024
    private static let maxFiles = 3

    /// `~/Library/Application Support/MailPilot/audit.jsonl`
    static var fileURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("MailPilot/audit.jsonl")
    }

    static func append(_ entry: Entry) {
        queue.async {
            guard let url = fileURL else { return }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard var data = try? encoder.encode(entry) else { return }
            data.append(0x0A)

            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)

            rotateIfNeeded(url: url)

            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    static func clear() {
        queue.async {
            guard let url = fileURL else { return }
            let fm = FileManager.default
            try? fm.removeItem(at: url)
            for index in 1..<maxFiles {
                try? fm.removeItem(at: rotated(url, index: index))
            }
        }
    }

    /// 当前占用字节数，设置页用来告诉用户日志有多大
    static var totalBytes: Int {
        guard let url = fileURL else { return 0 }
        let fm = FileManager.default
        var total = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        for index in 1..<maxFiles {
            total += (try? fm.attributesOfItem(atPath: rotated(url, index: index).path)[.size] as? Int) ?? 0
        }
        return total
    }

    // MARK: - 轮转

    private static func rotated(_ url: URL, index: Int) -> URL {
        url.deletingLastPathComponent()
            .appendingPathComponent("audit.\(index).jsonl")
    }

    private static func rotateIfNeeded(url: URL) {
        let fm = FileManager.default
        guard let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int,
              size >= maxBytes else { return }

        for index in stride(from: maxFiles - 1, through: 1, by: -1) {
            let source = index == 1 ? url : rotated(url, index: index - 1)
            try? fm.removeItem(at: rotated(url, index: index))
            try? fm.moveItem(at: source, to: rotated(url, index: index))
        }
    }
}
