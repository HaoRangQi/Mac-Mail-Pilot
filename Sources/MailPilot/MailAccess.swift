import AppKit
import Foundation

enum MailAccess {
    enum Status {
        case authorized(version: String)
        case denied
        case noMailData
    }

    static var mailRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mail")
    }

    /// 找版本目录（V10 / V9 …），取最高版本
    static func versionDirectory() -> URL? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: mailRoot,
                                                        includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles]) else { return nil }
        let versions = entries.filter { url in
            let name = url.lastPathComponent
            guard name.hasPrefix("V"), name.count > 1 else { return false }
            return Int(name.dropFirst()) != nil
        }
        return versions.sorted { $0.lastPathComponent > $1.lastPathComponent }.first
    }

    static func status() -> Status {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: mailRoot.path, isDirectory: &isDir), isDir.boolValue else {
            return .noMailData
        }
        // 能 stat 不等于能列目录：无完全磁盘访问权限时 listdir 会抛错
        do {
            _ = try fm.contentsOfDirectory(atPath: mailRoot.path)
        } catch {
            return .denied
        }
        guard let version = versionDirectory() else { return .noMailData }
        return .authorized(version: version.lastPathComponent)
    }

    static var isAuthorized: Bool {
        if case .authorized = status() { return true }
        return false
    }

    static func openPrivacySettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
        ]
        for string in candidates {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }
}
