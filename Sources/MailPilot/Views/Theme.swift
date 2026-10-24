import AppKit
import SwiftUI

extension Color {
    /// 十六进制字面量 → Color
    static func hex(_ value: UInt32, opacity: Double = 1) -> Color {
        Color(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: opacity
        )
    }

    /// 随系统外观（浅色 / 深色）自动切换的颜色。
    /// 深色模式不能直接沿用浅色值——低饱和的深绿、砖红在暗背景上会糊成一团，
    /// 所以深色一侧统一提亮、降饱和。
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let value = isDark ? dark : light
            return NSColor(
                srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

enum Theme {
    static let panelRadius: CGFloat = 18
    static let gap: CGFloat = 10

    /// 三栏宽度可在「外观」设置里调，这里只做转发
    static var sidebarWidth: CGFloat { UIState.sidebarWidth }
    static var listWidth: CGFloat { UIState.listWidth }

    // MARK: - 调色板
    // 取自「9 个超好看的高级感配色」那一组：
    // 深绿 #46734F / 金黄 #CAAB6C / 米灰 #D0CCAF / 蓝灰 #617F97 / 砖红 #9A352D
    // 五个色各司其职，不要互相抢：绿是主，蓝灰是次，金是点缀，砖红只用于破坏性操作

    /// 主色 · 深绿：强调、选中、发送
    static let moss = Color.adaptive(light: 0x46734F, dark: 0x7FAE8B)

    /// 次色 · 蓝灰：次级操作、AI、信息
    static let slate = Color.adaptive(light: 0x617F97, dark: 0x8FA9C0)

    /// 点缀 · 金黄：旗标、未读提示、需要注意的项
    static let gold = Color.adaptive(light: 0xCAAB6C, dark: 0xDCC28E)

    /// 中性 · 米灰：分隔、底纹、禁用态
    static let sand = Color.adaptive(light: 0xD0CCAF, dark: 0x8C8874)

    /// 警示 · 砖红：删除等不可逆操作
    static let brick = Color.adaptive(light: 0x9A352D, dark: 0xCC6E63)

    /// 全局强调色（按钮、选中态、控件）。默认苔绿，可在「外观」里换
    static var accent: Color { UIState.accentColor }

    /// AI 相关渐变（绿 → 蓝灰，替换掉原来不搭的紫蓝）
    static let aiGradient = LinearGradient(
        colors: [moss, slate],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

/// 液态玻璃需要背后有内容才能"折射"。玻璃效果要看得见，底色就不能太淡——
/// 这里用三个大色斑做底，左上那个正好落在顶栏按钮后面。
///
/// 强度可在「外观」里调（无 / 柔和 / 标准）。关掉后玻璃面板仍在，但会显得很平，
/// 设置页里对此有说明。
struct AppBackground: View {
    private var strength: Double { UIState.backdropOpacity }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if strength > 0 {
                Group {
                    Circle()
                        .fill(Theme.moss.opacity(0.20))
                        .frame(width: 620, height: 620)
                        .blur(radius: 120)
                        .offset(x: -320, y: -280)
                    Circle()
                        .fill(Theme.gold.opacity(0.15))
                        .frame(width: 520, height: 520)
                        .blur(radius: 130)
                        .offset(x: 360, y: 300)
                    Circle()
                        .fill(Theme.slate.opacity(0.14))
                        .frame(width: 460, height: 460)
                        .blur(radius: 110)
                        .offset(x: 150, y: -340)
                }
                .opacity(strength)
            }
        }
        .ignoresSafeArea()
    }
}

extension Font {
    /// 全局字号入口。
    ///
    /// 界面上所有文字都必须走这里，不要直接写 `.system(size:)`——否则「整体字号」
    /// 设置对它无效，会出现同一屏里一半大一半小的割裂感。
    ///
    /// - Parameters:
    ///   - size: 基准字号（标准字号下的实际 pt）
    ///   - design: 调用方显式指定的字体族。传 nil 表示「跟随全局字体设置」
    static func app(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design? = nil) -> Font {
        .system(size: size * UIState.scale, weight: weight, design: design ?? UIState.fontDesign)
    }
}

extension View {
    func glassPanel(radius: CGFloat = Theme.panelRadius) -> some View {
        self.glassEffect(.regular, in: .rect(cornerRadius: radius))
    }

    /// 滚动条默认不显示，鼠标移入才出现。
    func hoverScrollIndicators() -> some View {
        modifier(HoverScrollIndicators())
    }

    func faintSeparator() -> some View {
        self.overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 1)
        }
    }
}

final class ScrollHoverState: ObservableObject {
    @Published var hovering = false
}

/// 滚动条默认不显示，鼠标移入才出现。
///
/// 两个关键点：
/// 1. 用 `.never` 而不是 `.hidden` —— macOS 上 `.hidden` 会被系统偏好覆盖，`.never` 才是强制不画
/// 2. 只能走这个 API：SwiftUI 在 macOS 26 用的是**自绘滚动容器**，视图层级里根本没有
///    NSScrollView（实测探针的 superview 链只有 `_NSGraphicsView`），拿 AppKit 的
///    `hasVerticalScroller` 调不到
struct HoverScrollIndicators: ViewModifier {
    @StateObject private var state = ScrollHoverState()

    func body(content: Content) -> some View {
        content
            .scrollIndicators(state.hovering ? .visible : .never)
            .onHover { state.hovering = $0 }
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.app(10.5, weight: .medium))
            .foregroundStyle(.secondary)
            .kerning(0.4)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

struct UnreadBadge: View {
    let count: Int
    var body: some View {
        Text("\(count)")
            .font(.app(10.5, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .frame(minWidth: 18, minHeight: 16)
            .background(Color.primary.opacity(0.06), in: Capsule())
    }
}

struct Chip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.app(11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.05), in: Capsule())
    }
}
