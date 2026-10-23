import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var ui = OnboardingUI()

    var body: some View {
        ZStack {
            Color.black.opacity(0.28).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                header
                Divider().opacity(0.5)
                content
                Divider().opacity(0.5)
                footer
            }
            .frame(width: 560)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.primary.opacity(0.10), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.28), radius: 40, y: 14)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(Theme.aiGradient)
                .frame(width: 40, height: 40)
                .background(Theme.aiGradient.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 3) {
                Text("让 MailPilot 读取你的邮件")
                    .font(.system(size: 15, weight: .semibold))
                Text("只读取「邮件」App 已经同步到本机的数据，不上传、不需要登录。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(20)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            step(1, "点击下方「打开系统设置」")
            step(2, "进入 隐私与安全性 → 完全磁盘访问权限")
            step(3, "把 MailPilot 加进列表并打开开关")
            step(4, "回到这里点「重新检测」")

            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                Text("如果仍然提示无权限，请退出 MailPilot 再重新打开——权限只对新启动的进程生效。")
                    .font(.system(size: 10.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(.tertiary)
            .padding(.top, 2)

            if let hint = ui.hint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(ui.failed ? Color.red : Color.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private func step(_ index: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(index)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .background(Color.primary.opacity(0.07), in: Circle())
            Text(text)
                .font(.system(size: 12.5))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("先用演示数据") {
                model.useDemoData()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)

            Spacer()

            Button(ui.checking ? "检测中…" : "重新检测") {
                Task { @MainActor in
                    ui.checking = true
                    ui.hint = nil
                    let ok = await model.recheckAccess()
                    ui.checking = false
                    ui.failed = !ok
                    if !ok {
                        ui.hint = "仍未获得权限。确认已在「完全磁盘访问权限」里勾选 MailPilot，必要时重启 App。"
                    }
                }
            }
            .disabled(ui.checking)

            Button("打开系统设置") {
                MailAccess.openPrivacySettings()
                ui.hint = "已打开系统设置，授权后回来点「重新检测」。"
                ui.failed = false
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20)
        .frame(height: 58)
    }
}

final class OnboardingUI: ObservableObject {
    @Published var checking = false
    @Published var hint: String?
    @Published var failed = false
}
