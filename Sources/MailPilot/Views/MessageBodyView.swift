import AppKit
import SwiftUI

/// 正文区状态（ObservableObject：本环境 `@State` 宏编不过，统一用 @StateObject）
final class MailBodyUIState: ObservableObject {
    @Published var prepared: MailBodyRenderer.Prepared?
    @Published var renderFailed = false
    @Published var pendingLink: URL?
    @Published var linkReason = ""
    /// 已渲染完的邮件 id。用来区分「换邮件」（要清空旧内容）和「只调了字号」（保留旧内容不闪 loading）
    var loadedMessageID: String?
}

/// HTML 正文视图。渲染在后台线程做（SwiftSoup 解析 + 清洗），
/// 完成前显示 loading；清洗/解析任何一步失败 → 退回纯文本，绝不给用户看原始 HTML。
struct MailBodyView: View {
    let message: Message
    @StateObject private var ui = MailBodyUIState()

    var body: some View {
        // 这三个值必须参与 body 求值：父视图（ReaderView 观察 AppModel）在设置变化时重算，
        // 本视图随之重建；renderKey 变了 → .task 重跑 → 按新字号重新渲染。
        // 少了这一环，改字号后 HTML 正文不会变大（task(id:) 只认 message.id）
        let fontPoints = UIState.readerFontSize
        let dark = isDarkAppearance()
        let renderKey = "\(message.id)|\(fontPoints)|\(dark ? 1 : 0)"

        ZStack {
            if let prepared = ui.prepared {
                MailWebView(html: prepared.html, onSuspiciousLink: { url, reason in
                    ui.pendingLink = url
                    ui.linkReason = reason
                })
            } else if ui.renderFailed {
                plainTextFallback
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: renderKey) {
            // 只在切换邮件时清空；单纯调字号/深浅色时保留旧内容，避免闪一下 loading
            if ui.loadedMessageID != message.id {
                ui.prepared = nil
                ui.renderFailed = false
                ui.loadedMessageID = message.id
            }
            guard !message.htmlBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                ui.renderFailed = true
                return
            }
            let raw = message.htmlBody
            let images = message.inlineImages
            let prepared = await Task.detached(priority: .userInitiated) {
                MailBodyRenderer.prepare(rawHTML: raw, inlineImages: images, fontPoints: fontPoints, dark: dark)
            }.value
            if let prepared {
                ui.prepared = prepared
            } else {
                // 清洗失败是「邮件太怪」，不是 bug——安静退回纯文本
                ui.renderFailed = true
            }
        }
        .alert(
            "这个链接有风险，确认打开吗？",
            isPresented: Binding(
                get: { ui.pendingLink != nil },
                set: { presented in if !presented { ui.pendingLink = nil } }
            ),
            presenting: ui.pendingLink
        ) { url in
            Button("在浏览器打开") {
                NSWorkspace.shared.open(url)
                ui.pendingLink = nil
            }
            Button("复制地址") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
                ui.pendingLink = nil
            }
            Button("取消", role: .cancel) { ui.pendingLink = nil }
        } message: { url in
            Text("\(ui.linkReason)\n\n真实地址：\n\(url.absoluteString)")
        }
    }

    /// HTML 清洗失败时的退路。复用纯文本模式的排版与字号设置
    private var plainTextFallback: some View {
        ScrollView {
            Text(message.body.isEmpty ? "（这封邮件没有可显示的正文）" : message.body)
                .font(.app(UIState.readerFontSize))
                .lineSpacing(UIState.readerLineSpacing)
                .textSelection(.enabled)
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, 26)
                .padding(.vertical, 22)
        }
        .hoverScrollIndicators()
    }

    private func isDarkAppearance() -> Bool {
        let name = NSApp.effectiveAppearance.name
        return name == .darkAqua || name == .vibrantDark || name == .accessibilityHighContrastDarkAqua
    }
}
