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
        case .small: return 0.90
        case .standard: return 1.00
        case .large: return 1.12
        case .xlarge: return 1.24
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

/// 强调色。只从既有五个色里挑，保证与液态玻璃底纹、状态色不打架
enum UIAccent: String, Codable, CaseIterable, Identifiable {
    case moss, slate, gold, brick

    var id: String { rawValue }

    var label: String {
        switch self {
        case .moss: return "苔绿"
        case .slate: return "蓝灰"
        case .gold: return "金黄"
        case .brick: return "砖红"
        }
    }

    /// 注意这里直接取调色板常量，不能走 `Theme.accent`（会绕回自己）
    var color: Color {
        switch self {
        case .moss: return Theme.moss
        case .slate: return Theme.slate
        case .gold: return Theme.gold
        case .brick: return Theme.brick
        }
    }
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

    /// 是否与默认值完全一致（页面用来显示「恢复默认」是否可点）
    var isDefault: Bool { self == UISettings() }
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
    static var accentColor: Color { current.accent.color }
    static var rowPadding: CGFloat { current.density.rowPadding }
    static var previewLines: Int { current.density.previewLines }
    static var sidebarWidth: CGFloat { current.panelWidth.sidebar }
    static var listWidth: CGFloat { current.panelWidth.list }
    static var backdropOpacity: Double { current.backdrop.opacity }
    static var readerFontSize: CGFloat { current.readerSize.points }
    static var readerLineSpacing: CGFloat { current.readerSpacing.points }
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
