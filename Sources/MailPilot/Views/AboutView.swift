import AppKit
import SwiftUI

struct AboutView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                infoCard
                privacyCard
            }
            .padding(22)
        }
        .scrollIndicators(.visible)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "envelope.badge.shield.check")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(Theme.aiGradient)
                .frame(width: 60, height: 60)
                .background(Theme.aiGradient.opacity(0.13), in: RoundedRectangle(cornerRadius: 15, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text("MailPilot")
                    .font(.system(size: 17, weight: .semibold))
                Text("本地优先的邮件工作台")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("版本 0.2.1 · macOS 26+")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            infoRow("数据来源", "「邮件」App 已同步到本机的 .emlx（只读）")
            infoRow("数据位置", "~/Library/Mail")
            infoRow("AI 配置", "本机 UserDefaults，密钥不上传")
            infoRow("构建方式", "SwiftPM · ad-hoc 签名")

            Divider().opacity(0.4)

            Button("在 Finder 中打开数据目录") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: NSHomeDirectory() + "/Library/Mail")
            }
            .buttonStyle(.link)
            .font(.system(size: 11.5))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }

    private var privacyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("隐私")
                .font(.system(size: 12, weight: .medium))
            Text("MailPilot 不收集、不上传任何邮件内容。所有 AI 请求由你的设备直接发向你配置的服务商；选择本地模型（Ollama）时，邮件内容不会离开这台电脑。")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}
