import AppKit
import Carbon
import Foundation

/// 控制「邮件」App 的自动化授权（TCC 的 kTCCServiceAppleEvents）。
///
/// 这项权限与「完全磁盘访问权限」是**两套独立**的 TCC 服务，不能合并申请：
/// - 磁盘访问：读 `~/Library/Mail` 里的 .emlx
/// - 自动化：让「邮件」App 替你执行删除 / 发送
///
/// macOS 没有「预先在设置里勾选」的入口——系统设置里的自动化列表**只显示已经触发过的配对**，
/// 没弹过框的配对根本不在列表里。唯一的主动申请方式是
/// `AEDeterminePermissionToAutomateTarget(..., askUserIfNeeded: true)`，
/// 它会把系统弹框提前到我们指定的时机（设置页点按钮），而不是删除那一刻。
enum MailAutomation {
    enum Status: Equatable {
        case authorized
        case denied
        case notDetermined
        case mailNotRunning
        case failed(Int32)

        var isAuthorized: Bool { self == .authorized }
    }

    static let mailBundleID = "com.apple.mail"

    /// TCC 错误码（Carbon 常量在 Swift 里类型不统一，这里直接写字面值）
    private enum AEStatus {
        static let notPermitted: OSStatus = -1743      // errAEEventNotPermitted
        static let wouldRequireConsent: OSStatus = -1744 // errAEEventWouldRequireUserConsent
        static let procNotFound: OSStatus = -600      // procNotFound
    }

    static var isMailRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == mailBundleID }
    }

    static func openMail() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: mailBundleID) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
    }

    /// 查询当前授权状态。`askUserIfNeeded = true` 时会弹系统授权框并**同步阻塞**，
    /// 必须在后台队列调用，不能放主线程。
    static func status(askUserIfNeeded: Bool) -> Status {
        var address = AEAddressDesc()
        guard let data = mailBundleID.data(using: .utf8) else { return .failed(-1) }
        let created: OSErr = data.withUnsafeBytes { raw in
            AECreateDesc(DescType(typeApplicationBundleID), raw.baseAddress, data.count, &address)
        }
        guard created == noErr else { return .failed(Int32(created)) }

        let result = AEDeterminePermissionToAutomateTarget(
            &address,
            AEEventClass(typeWildCard),
            AEEventID(typeWildCard),
            askUserIfNeeded
        )
        AEDisposeDesc(&address)

        switch result {
        case noErr: return .authorized
        case AEStatus.notPermitted: return .denied
        case AEStatus.wouldRequireConsent: return .notDetermined
        case AEStatus.procNotFound: return .mailNotRunning
        default: return .failed(result)
        }
    }

    /// 只查询、不弹框、不启动「邮件」，用于界面初始化
    static func probe() async -> Status {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: status(askUserIfNeeded: false))
            }
        }
    }

    /// 主动申请：先确保「邮件」在运行（目标没启动时系统不会弹框，只返回 procNotFound），
    /// 再触发系统授权框。
    static func request() async -> Status {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                if !isMailRunning {
                    openMail()
                    Thread.sleep(forTimeInterval: 2.0)
                }
                continuation.resume(returning: status(askUserIfNeeded: true))
            }
        }
    }

    static func openAutomationSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Automation",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation",
        ]
        for string in candidates {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }
}

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
