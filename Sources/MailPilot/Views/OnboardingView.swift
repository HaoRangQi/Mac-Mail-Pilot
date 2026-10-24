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
                .font(.app(18, weight: .regular))
                .foregroundStyle(Theme.aiGradient)
                .frame(width: 40, height: 40)
                .background(Theme.aiGradient.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 3) {
                Text("让 MailPilot 读取你的邮件")
                    .font(.app(15, weight: .semibold))
                Text("只读取「邮件」App 已经同步到本机的数据，不上传、不需要登录。")
                    .font(.app(11.5))
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
                    .font(.app(10))
                Text("如果仍然提示无权限，请退出 MailPilot 再重新打开——权限只对新启动的进程生效。")
                    .font(.app(10.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(.tertiary)
            .padding(.top, 2)

            demoHint

            if let hint = ui.hint {
                Text(hint)
                    .font(.app(11))
                    .foregroundStyle(ui.failed ? Theme.brick : Color.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    /// 不授权也能用。第一次接触的人不该被"完全磁盘访问权限"卡住——
    /// 先用演示数据把界面和 AI 功能走一遍，想授权时随时回来。
    private var demoHint: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.app(10))
                    .foregroundStyle(Theme.aiButtonGradient)
                Text("还没准备好授权？")
                    .font(.app(12, weight: .medium))
            }

            Text("先用演示数据把界面和 AI 功能走一遍——它不会读取你的任何邮件。之后随时可以在「设置 → 权限管理」里授权，切回真实邮件。")
                .font(.app(11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                model.useDemoData()
            } label: {
                Text("用演示数据熟悉功能")
                    .font(.app(11.5, weight: .medium))
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .background(Color.primary.opacity(0.07), in: Capsule())
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("不读取任何真实邮件，随时可在设置里授权切换")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.07), lineWidth: 0.5))
    }

    private func step(_ index: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(index)")
                .font(.app(10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .background(Color.primary.opacity(0.07), in: Circle())
            Text(text)
                .font(.app(12.5))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
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
            .tint(Theme.accent)
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
