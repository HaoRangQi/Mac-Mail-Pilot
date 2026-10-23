import AppKit
import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            content
            Divider().opacity(0.5)
            footer
        }
        .frame(width: 420)
        .background(.regularMaterial)
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "envelope.badge.shield.check")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(Theme.aiGradient)
                .frame(width: 64, height: 64)
                .background(Theme.aiGradient.opacity(0.13), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            Text("MailPilot")
                .font(.system(size: 17, weight: .semibold))
            Text("本地优先的邮件工作台 · 0.2.0")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 26)
        .padding(.bottom, 20)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            infoRow("数据来源", "「邮件」App 已同步到本机的 .emlx（只读）")
            infoRow("数据位置", "~/Library/Mail")
            infoRow("AI 配置", "本机 UserDefaults，密钥不上传")
            infoRow("构建方式", "SwiftPM · ad-hoc 签名")
            infoRow("系统要求", "macOS 26+")

            Divider().opacity(0.4)

            VStack(alignment: .leading, spacing: 6) {
                Text("MailPilot 不收集、不上传任何邮件内容。所有 AI 请求直接由你的设备发向你配置的服务商。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
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

    private var footer: some View {
        HStack(spacing: 10) {
            Button("打开数据目录") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: NSHomeDirectory() + "/Library/Mail")
            }
            Button("好") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding(.horizontal, 22)
        .frame(height: 56)
    }
}
