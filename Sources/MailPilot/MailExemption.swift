import Combine
import Foundation

/// 单封邮件的「不敏感」名单。
///
/// 用途：用户主观判断某封邮件敏感度不高、外泄可接受，允许它在不可信模型上
/// 跳过脱敏与确认（见 `TrustPolicy.decide(exempted:)`）。
///
/// 三个设计取舍：
/// 1. **按 Message-ID 存，不按文件路径**——邮件挪到别的邮箱后路径会变，ID 不变
/// 2. **只存本机**，不进任何请求，不上传
/// 3. **状态必须一直可见**：标记过的邮件在阅读页常驻显示，AI 结果区也会再提示一次。
///    用户「绕晕」的根源不是开关多，而是不知道当前生效的是哪一层——
///    所以宁可多显示一行字，也不让状态藏在设置里
final class MailExemptionStore: ObservableObject {
    @Published private(set) var ids: Set<String> = []

    private let storageKey = "mailpilot.exempt.messages"

    init() {
        ids = Set(UserDefaults.standard.stringArray(forKey: storageKey) ?? [])
    }

    func contains(_ id: String) -> Bool {
        !id.isEmpty && ids.contains(id)
    }

    func set(_ exempt: Bool, id: String) {
        guard !id.isEmpty else { return }
        if exempt {
            ids.insert(id)
        } else {
            ids.remove(id)
        }
        UserDefaults.standard.set(Array(ids), forKey: storageKey)
    }

    func toggle(_ id: String) {
        set(!contains(id), id: id)
    }

    func clear() {
        ids.removeAll()
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}
