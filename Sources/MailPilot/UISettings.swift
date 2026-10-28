import AppKit
import Combine
import Foundation
import SwiftUI

// MARK: - 可调项
//
// 每个枚举自己带 label / 取值，页面只负责摆控件，不写换算逻辑。
// 新增一个可调项的顺序：在这里加枚举 → 加进 UISettings → 在 UIState 暴露 → 页面加一行。

/// 整体字号：所有界面文字的缩放系数
enum UIScale: String, Codable, CaseIterable, Identifiable {
    case small, standard, large, xlarge

    var id: String { rawValue }

    var label: String {
        switch self {
        case .small: return "小"
        case .standard: return "标准"
        case .large: return "大"
        case .xlarge: return "特大"
        }
    }

    var factor: CGFloat {
        switch self {
        // 基准整体上移：原来的 100% 在实际使用中偏小（正文 12.5pt / 说明 10.5pt，
        // 比 macOS 系统正文 13pt 还小），现在「小」就是原来的标准，默认「标准」放大 12%
        case .small: return 1.00
        case .standard: return 1.12
        case .large: return 1.26
        case .xlarge: return 1.40
        }
    }

    /// 给页面显示用，让用户知道点下去具体变多少
    var hint: String {
        "\(Int((factor * 100).rounded()))%"
    }
}

/// 字体族。等宽只影响拉丁字符，中文会退回系统黑体
enum UIFontFamily: String, Codable, CaseIterable, Identifiable {
    case system, rounded, serif, mono

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "系统"
        case .rounded: return "圆体"
        case .serif: return "衬线"
        case .mono: return "等宽"
        }
    }

    var design: Font.Design {
        switch self {
        case .system: return .default
        case .rounded: return .rounded
        case .serif: return .serif
        case .mono: return .monospaced
        }
    }
}

/// 强调色。内置四个取自调色板，另可自定义（调色盘）
enum UIAccent: String, Codable, CaseIterable, Identifiable {
    case moss, slate, gold, brick, custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .moss: return "苔绿"
        case .slate: return "蓝灰"
        case .gold: return "金黄"
        case .brick: return "砖红"
        case .custom: return "自定义"
        }
    }

    /// 内置色块。自定义色不在这里取，走 `UIState.accentColor`
    var color: Color {
        switch self {
        case .moss: return Theme.moss
        case .slate: return Theme.slate
        case .gold: return Theme.gold
        case .brick: return Theme.brick
        case .custom: return Theme.moss
        }
    }

    /// 设置页里画色块用的列表（自定义单独用一个调色盘控件）
    static var presets: [UIAccent] { [.moss, .slate, .gold, .brick] }
}

/// 列表密度：行内边距 + 摘要行数
enum UIDensity: String, Codable, CaseIterable, Identifiable {
    case compact, standard, relaxed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .compact: return "紧凑"
        case .standard: return "标准"
        case .relaxed: return "宽松"
        }
    }

    var rowPadding: CGFloat {
        switch self {
        case .compact: return 6
        case .standard: return 9
        case .relaxed: return 13
        }
    }

    var previewLines: Int {
        switch self {
        case .compact: return 1
        case .standard, .relaxed: return 2
        }
    }
}

/// 面板宽度：侧边栏与列表一起变，保持三栏比例
enum UIPanelWidth: String, Codable, CaseIterable, Identifiable {
    case narrow, standard, wide

    var id: String { rawValue }

    var label: String {
        switch self {
        case .narrow: return "窄"
        case .standard: return "标准"
        case .wide: return "宽"
        }
    }

    var sidebar: CGFloat {
        switch self {
        case .narrow: return 188
        case .standard: return 216
        case .wide: return 246
        }
    }

    var list: CGFloat {
        switch self {
        case .narrow: return 296
        case .standard: return 340
        case .wide: return 388
        }
    }
}

/// 背景色斑强度。液态玻璃要靠背后有内容才看得见折射，全关会显得很平
enum UIBackdrop: String, Codable, CaseIterable, Identifiable {
    case none, soft, standard

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "无"
        case .soft: return "柔和"
        case .standard: return "标准"
        }
    }

    var opacity: Double {
        switch self {
        case .none: return 0
        case .soft: return 0.5
        case .standard: return 1
        }
    }
}

/// 阅读正文的字号。跟着整体字号一起缩放，这里定基准
enum ReaderFontSize: String, Codable, CaseIterable, Identifiable {
    case small, standard, large, xlarge

    var id: String { rawValue }

    var label: String {
        switch self {
        case .small: return "小"
        case .standard: return "标准"
        case .large: return "大"
        case .xlarge: return "特大"
        }
    }

    var points: CGFloat {
        switch self {
        case .small: return 12.5
        case .standard: return 13.5
        case .large: return 15
        case .xlarge: return 16.5
        }
    }
}

/// 正文行距
enum ReaderLineSpacing: String, Codable, CaseIterable, Identifiable {
    case tight, standard, relaxed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .tight: return "紧凑"
        case .standard: return "标准"
        case .relaxed: return "宽松"
        }
    }

    var points: CGFloat {
        switch self {
        case .tight: return 2
        case .standard: return 5
        case .relaxed: return 9
        }
    }
}

/// HTML 邮件远程图片策略。远程图片是跟踪像素与已读回执的主要通道，默认阻止；
/// 「总是加载」也走 App 代理 fetch（限大小/限类型），WebView 始终零外联
enum RemoteImagePolicy: String, Codable, CaseIterable, Identifiable {
    case block, ask, allow

    var id: String { rawValue }

    var label: String {
        switch self {
        case .block: return "始终阻止"
        case .ask: return "每次询问"
        case .allow: return "总是加载"
        }
    }

    var help: String {
        switch self {
        case .block:
            return "所有远程图片一律替换为占位，不发起任何网络请求。跟踪像素与已读回执都发不出去"
        case .ask:
            return "默认替换为占位，正文顶部显示「加载图片」按钮，由你决定这封图不图"
        case .allow:
            return "打开邮件时自动加载远程图片。仍由 App 代理下载（限 2MB/张、限图片格式），WebView 不直接出网"
        }
    }
}

/// 背景图铺法
enum BackgroundFill: String, Codable, CaseIterable, Identifiable {
    case fill, fit

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fill: return "填充"
        case .fit: return "适应"
        }
    }

    var contentMode: ContentMode {
        switch self {
        case .fill: return .fill
        case .fit: return .fit
        }
    }
}

// MARK: - 配置

struct UISettings: Codable, Equatable {
    var scale: UIScale = .standard
    var fontFamily: UIFontFamily = .system
    var accent: UIAccent = .moss
    var density: UIDensity = .standard
    var panelWidth: UIPanelWidth = .standard
    var backdrop: UIBackdrop = .standard
    var readerSize: ReaderFontSize = .standard
    var readerSpacing: ReaderLineSpacing = .standard
    /// HTML 邮件远程图片策略（默认阻止）
    var remoteImages: RemoteImagePolicy = .block

    /// 自定义强调色（0xRRGGBB）。只有 `accent == .custom` 时才生效
    var customAccentHex: UInt32 = 0x46734F

    // MARK: 背景图

    /// 背景图总开关。关掉只是不显示，图片路径、模糊度、压暗、铺法全部保留，
    /// 想用时再打开即可——所以它是独立开关，不是「移除」
    var backgroundEnabled: Bool = true
    /// 已缓存到本机支持目录的图片路径（空 = 不用背景图）
    var backgroundPath: String = ""
    /// 用户看到的来源：本地原文件路径或远程 URL，只用于界面显示
    var backgroundSource: String = ""
    var backgroundBlur: Double = 16
    /// 图片上压一层暗色，保证浅色文字与面板能读
    var backgroundDim: Double = 0.35
    var backgroundFill: BackgroundFill = .fill

    /// 是否与默认值完全一致（页面用来显示「恢复默认」是否可点）
    var isDefault: Bool { self == UISettings() }

    /// 手写解码：新增字段时旧配置不能整份作废
    init() {}

    private enum CodingKeys: String, CodingKey {
        case scale, fontFamily, accent, density, panelWidth, backdrop
        case readerSize, readerSpacing
        case remoteImages
        case backgroundPath, backgroundSource, backgroundBlur, backgroundDim, backgroundFill
        case backgroundEnabled
        case customAccentHex
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scale = try c.decodeIfPresent(UIScale.self, forKey: .scale) ?? .standard
        fontFamily = try c.decodeIfPresent(UIFontFamily.self, forKey: .fontFamily) ?? .system
        accent = try c.decodeIfPresent(UIAccent.self, forKey: .accent) ?? .moss
        density = try c.decodeIfPresent(UIDensity.self, forKey: .density) ?? .standard
        panelWidth = try c.decodeIfPresent(UIPanelWidth.self, forKey: .panelWidth) ?? .standard
        backdrop = try c.decodeIfPresent(UIBackdrop.self, forKey: .backdrop) ?? .standard
        readerSize = try c.decodeIfPresent(ReaderFontSize.self, forKey: .readerSize) ?? .standard
        readerSpacing = try c.decodeIfPresent(ReaderLineSpacing.self, forKey: .readerSpacing) ?? .standard
        remoteImages = try c.decodeIfPresent(RemoteImagePolicy.self, forKey: .remoteImages) ?? .block
        backgroundPath = try c.decodeIfPresent(String.self, forKey: .backgroundPath) ?? ""
        backgroundSource = try c.decodeIfPresent(String.self, forKey: .backgroundSource) ?? ""
        backgroundBlur = try c.decodeIfPresent(Double.self, forKey: .backgroundBlur) ?? 16
        backgroundDim = try c.decodeIfPresent(Double.self, forKey: .backgroundDim) ?? 0.35
        backgroundFill = try c.decodeIfPresent(BackgroundFill.self, forKey: .backgroundFill) ?? .fill
        // 旧配置没这个键：已经设了图的人要继续看到图，所以缺省是「开」
        backgroundEnabled = try c.decodeIfPresent(Bool.self, forKey: .backgroundEnabled) ?? true
        customAccentHex = try c.decodeIfPresent(UInt32.self, forKey: .customAccentHex) ?? 0x46734F
    }
}

// MARK: - 运行时快照

/// 主题与布局只读这里，不直接读 UserDefaults。
///
/// 原因：`Font.app()` 在整个界面里被调用几百次/帧，每次都解 JSON 会明显拖慢滚动。
/// 这里存一份内存快照，配置变更时由 `UISettingsStore` 覆盖。
///
/// 刷新链路：改设置 → store 的 didSet 更新 UIState → store 发 objectWillChange
/// → AppModel 转发 → 观察 model 的视图重算 body，此时读到新的 UIState。
enum UIState {
    static var current = UISettings()

    static var scale: CGFloat { current.scale.factor }
    static var fontDesign: Font.Design { current.fontFamily.design }
    static var accentColor: Color {
        current.accent == .custom
            ? Color.adaptiveCustom(current.customAccentHex)
            : current.accent.color
    }
    static var rowPadding: CGFloat { current.density.rowPadding }
    static var previewLines: Int { current.density.previewLines }
    static var sidebarWidth: CGFloat { current.panelWidth.sidebar }
    static var listWidth: CGFloat { current.panelWidth.list }
    static var backdropOpacity: Double { current.backdrop.opacity }
    static var readerFontSize: CGFloat { current.readerSize.points }
    static var readerLineSpacing: CGFloat { current.readerSpacing.points }
    /// HTML 邮件远程图片策略。`current` 快照由 store didSet 刷新，改设置会触发重绘
    static var remoteImagePolicy: RemoteImagePolicy { current.remoteImages }

    // 背景图
    static var backgroundEnabled: Bool { current.backgroundEnabled }
    static var backgroundPath: String { current.backgroundPath }
    static var backgroundBlur: Double { current.backgroundBlur }
    static var backgroundDim: Double { current.backgroundDim }
    static var backgroundFill: BackgroundFill { current.backgroundFill }
    /// 是否已经设了可用的图。**不看总开关**——设置页要靠它显示「移除」按钮
    static var hasBackgroundImage: Bool {
        !current.backgroundPath.isEmpty && FileManager.default.fileExists(atPath: current.backgroundPath)
    }
}

// MARK: - 存储

final class UISettingsStore: ObservableObject {
    @Published var settings: UISettings {
        didSet {
            UIState.current = settings
            persist()
        }
    }

    private let storageKey = "mailpilot.ui.settings"

    init() {
        let loaded: UISettings
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(UISettings.self, from: data) {
            loaded = decoded
        } else {
            loaded = UISettings()
        }
        settings = loaded
        // init 里 didSet 不触发，必须手动同步一次快照
        UIState.current = loaded
    }

    func reset() {
        settings = UISettings()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}
