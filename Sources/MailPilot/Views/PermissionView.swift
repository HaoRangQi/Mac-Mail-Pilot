import SwiftUI

final class PermissionForm: ObservableObject {
    @Published var busy = false
    @Published var hint: String?
    @Published var failed = false
    @Published var automationBusy = false
    @Published var automation: MailAutomation.Status = .notDetermined
    @Published var automationHint: String?
}

struct PermissionView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var form = PermissionForm()

    private var status: MailAccess.Status {
        MailAccess.status()
    }

    private var authorized: Bool {
        if case .authorized = status { return true }
        return false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                statusCard
                automationCard
                explainCard
                actionRow
                footnote
            }
            .padding(22)
        }
        .scrollIndicators(.visible)
        .task {
            form.automation = await MailAutomation.probe()
        }
    }

    // MARK: - 状态

    private var statusCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: authorized ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                .font(.system(size: 22))
                .foregroundStyle(authorized ? Theme.moss : Theme.gold)
                .frame(width: 44, height: 44)
                .background(
                    (authorized ? Theme.moss : Theme.gold).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 11)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(authorized ? "已获得完全磁盘访问权限" : "尚未获得完全磁盘访问权限")
                    .font(.system(size: 13, weight: .semibold))
                Text(statusDetail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }

    private var statusDetail: String {
        switch status {
        case .authorized(let version):
            if model.isDemo {
                return "已授权（\(version)），但当前仍在使用演示数据。"
            }
            return "\(version) · \(model.accounts.count) 个账号 · \(model.mailboxes.count) 个邮箱"
        case .denied:
            return "需要在系统设置里把 MailPilot 加入「完全磁盘访问权限」。"
        case .noMailData:
            return "本机没有找到「邮件」App 的数据目录。"
        }
    }

    // MARK: - 控制「邮件」的自动化权限

    private var automationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: automationIcon)
                    .font(.system(size: 22))
                    .foregroundStyle(automationColor)
                    .frame(width: 44, height: 44)
                    .background(
                        automationColor.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 11)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text("控制「邮件」App")
                        .font(.system(size: 13, weight: .semibold))
                    Text(automationDetail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }

            HStack(spacing: 10) {
                if !form.automation.isAuthorized {
                    Button(form.automationBusy ? "等待系统确认…" : "申请权限") {
                        requestAutomation()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(form.automationBusy)
                }
                Button("打开自动化设置") { MailAutomation.openAutomationSettings() }
                    .buttonStyle(.bordered)
                Spacer()
            }

            if let hint = form.automationHint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }

    private var automationIcon: String {
        switch form.automation {
        case .authorized: return "checkmark.shield.fill"
        case .denied: return "xmark.shield.fill"
        case .notDetermined: return "questionmark.circle.fill"
        case .mailNotRunning: return "moon.zzz.fill"
        case .failed: return "exclamationmark.shield.fill"
        }
    }

    private var automationColor: Color {
        switch form.automation {
        case .authorized: return .green
        case .denied, .failed: return .red
        case .notDetermined: return .orange
        case .mailNotRunning: return .secondary
        }
    }

    private var automationDetail: String {
        switch form.automation {
        case .authorized:
            return "已授权。删除邮件时「邮件」App 会直接执行，不再弹框。"
        case .denied:
            return "上次选择了「不允许」。需要到 系统设置 → 隐私与安全性 → 自动化 手动打开。"
        case .notDetermined:
            return "删除与发送邮件需要这项权限，由 macOS 单独管理，无法与磁盘访问一起授予。"
        case .mailNotRunning:
            return "「邮件」当前没运行，系统无法弹出确认框。点「申请权限」会自动打开它。"
        case .failed(let code):
            return "查询失败（错误码 \(code)）。"
        }
    }

    private func requestAutomation() {
        Task { @MainActor in
            form.automationBusy = true
            form.automationHint = nil
            let result = await MailAutomation.request()
            form.automationBusy = false
            form.automation = result
            switch result {
            case .authorized:
                form.automationHint = "已授权，之后删除邮件不会再弹框。"
            case .denied:
                form.automationHint = "你选择了「不允许」。可到 系统设置 → 隐私与安全性 → 自动化 里把 MailPilot → 邮件 打开。"
            case .notDetermined:
                form.automationHint = "系统没有弹出确认框。稍后再试一次，或到自动化设置里手动添加。"
            case .mailNotRunning:
                form.automationHint = "「邮件」没有启动，无法询问。请先打开「邮件」App 再试。"
            case .failed(let code):
                form.automationHint = "询问失败（错误码 \(code)）。"
            }
        }
    }

    // MARK: - 说明

    private var explainCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("MailPilot 会读什么")
                .font(.system(size: 12, weight: .medium))

            bullet("checkmark", "读取「邮件」App 已同步到本机的 .emlx 文件（只读）", color: .green)
            bullet("checkmark", "所有数据都留在本机，不上传、不需要登录账号", color: .green)
            bullet("xmark", "不读取私有的 Envelope Index，不获取未读与旗标状态", color: .secondary)
            bullet("xmark", "不会自动删除或发送任何邮件，写操作都必须你亲手确认", color: .secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }

    private func bullet(_ icon: String, _ text: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 14)
                .padding(.top, 2)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 操作

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button {
                MailAccess.openPrivacySettings()
                form.hint = "已打开系统设置。授权后回来点「重新检测」。"
                form.failed = false
            } label: {
                Label("打开系统设置", systemImage: "gear")
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            Button(form.busy ? "检测中…" : "重新检测") {
                Task { @MainActor in
                    form.busy = true
                    form.hint = nil
                    let ok = await model.recheckAccess()
                    form.busy = false
                    form.failed = !ok
                    form.hint = ok ? "已切换为真实邮件数据。" : "仍未获得权限。确认已勾选 MailPilot，必要时重启 App。"
                }
            }
            .disabled(form.busy)

            if !authorized {
                Button("先用演示数据") { model.useDemoData() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    private var footnote: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let hint = form.hint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(form.failed ? Theme.brick : Color.secondary)
            }
            Text("修改权限后如果仍检测不到，请退出 MailPilot 再重新打开——权限只对新启动的进程生效。")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
    }
}
