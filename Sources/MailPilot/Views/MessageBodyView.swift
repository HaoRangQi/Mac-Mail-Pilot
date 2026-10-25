import AppKit
import SwiftUI

/// 正文区状态（ObservableObject：本环境 `@State` 宏编不过，统一用 @StateObject）
final class MailBodyUIState: ObservableObject {
    @Published var prepared: MailBodyRenderer.Prepared?
    @Published var renderFailed = false
    @Published var pendingLink: URL?
    @Published var linkReason = ""
    /// 远程图片正在代理下载中（横幅上转圈）
    @Published var loadingRemote = false
    /// 已渲染完的邮件 id。用来区分「换邮件」（要清空旧内容）和「只调了字号」（保留旧内容不闪 loading）
    var loadedMessageID: String?
    /// 用户已放行的远程图片：原始 URL → 数据。放行后重渲染即内联，WebView 仍零外联
    var remoteData: [String: Data] = [:]
}

/// HTML 正文视图。渲染在后台线程做（SwiftSoup 解析 + 清洗），
/// 完成前显示 loading；清洗/解析任何一步失败 → 退回纯文本，绝不给用户看原始 HTML。
struct MailBodyView: View {
    let message: Message
    @StateObject private var ui = MailBodyUIState()

    var body: some View {
        // 这几个值必须参与 body 求值：父视图（ReaderView 观察 AppModel）在设置变化时重算，
        // 本视图随之重建；renderKey 变了 → .task 重跑 → 按新字号重新渲染。
        // 少了这一环，改字号后 HTML 正文不会变大（task(id:) 只认 message.id）
        let fontPoints = UIState.readerFontSize
        let dark = isDarkAppearance()
        let policy = UIState.remoteImagePolicy
        let renderKey = "\(message.id)|\(fontPoints)|\(dark ? 1 : 0)|\(policy.rawValue)"

        VStack(spacing: 0) {
            // 远程图片横幅：仅在「每次询问」策略且有被剥的图时出现。
            // 「始终阻止」不显示（用户不想被问），「总是加载」不显示（已经自动在拉）
            if let prepared = ui.prepared, !prepared.remoteImageURLs.isEmpty, policy == .ask {
                remoteBanner(count: prepared.remoteImageURLs.count)
            }

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
        }
        .task(id: renderKey) {
            // 只在切换邮件时清空；单纯调字号/深浅色/图片策略时保留旧内容，避免闪一下 loading
            if ui.loadedMessageID != message.id {
                ui.prepared = nil
                ui.renderFailed = false
                ui.loadedMessageID = message.id
            }
            guard !message.htmlBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                ui.renderFailed = true
                return
            }
            await render(fontPoints: fontPoints, dark: dark, policy: policy)

            // 「总是加载」：首屏渲染完自动拉图，不再打扰用户
            if policy == .allow, let prepared = ui.prepared, !prepared.remoteImageURLs.isEmpty {
                await loadRemoteImages(fontPoints: fontPoints, dark: dark, policy: policy)
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

    // MARK: - 渲染与远程图片

    /// 跑一遍渲染管线。策略为「始终阻止」时不带已放行数据——切回阻止要立刻还原成占位
    private func render(fontPoints: CGFloat, dark: Bool, policy: RemoteImagePolicy) async {
        let raw = message.htmlBody
        let images = message.inlineImages
        let remote = policy == .block ? [:] : ui.remoteData
        let prepared = await Task.detached(priority: .userInitiated) {
            MailBodyRenderer.prepare(rawHTML: raw, inlineImages: images, loadedRemote: remote,
                                     fontPoints: fontPoints, dark: dark)
        }.value
        if let prepared {
            ui.prepared = prepared
        } else {
            // 清洗失败是「邮件太怪」，不是 bug——安静退回纯文本
            ui.renderFailed = true
        }
    }

    /// 代理下载当前邮件剩下的远程图片，回来后重渲染（内联成 data URI）
    private func loadRemoteImages(fontPoints: CGFloat, dark: Bool, policy: RemoteImagePolicy) async {
        guard let prepared = ui.prepared, !prepared.remoteImageURLs.isEmpty else { return }
        ui.loadingRemote = true
        let urls = prepared.remoteImageURLs
        // 直接 await：load 是非隔离 async 函数，网络等待本就会让出线程，
        // 不需要（也不能）再包一层 Task.detached——它的闭包里同样要 await
        let data = await RemoteImageLoader.load(urls)
        ui.remoteData.merge(data) { current, _ in current }
        ui.loadingRemote = false
        await render(fontPoints: fontPoints, dark: dark, policy: policy)
    }

    /// 远程图片横幅：说清拦了多少、为什么拦，动作只有一个——加载
    private func remoteBanner(count: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.app(10))
            Text("已阻止 \(count) 张远程图片（防止跟踪与已读回执）")
                .font(.app(11))
            Spacer(minLength: 8)
            if ui.loadingRemote {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            } else {
                Button {
                    Task { await loadRemoteImages(fontPoints: UIState.readerFontSize,
                                                  dark: isDarkAppearance(),
                                                  policy: UIState.remoteImagePolicy) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle")
                            .font(.app(9.5))
                        Text("加载图片")
                            .font(.app(11))
                    }
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .help("由 App 代理下载后显示（限 2MB/张、限图片格式），网页本身仍不会直接联网")
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 26)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.045))
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
