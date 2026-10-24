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

    /// 用户自选色的自适应版本。
    ///
    /// 只有一个色值时，深色模式下容易糊在暗背景里，所以暗色一侧自动提亮 + 略降饱和。
    /// 规则跟内置调色板一致：不指望用户自己去挑一个「深色模式也好看」的颜色。
    static func adaptiveCustom(_ value: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let base = NSColor(
                srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: 1
            )
            guard appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua,
                  let srgb = base.usingColorSpace(.sRGB) else { return base }
            var hue: CGFloat = 0
            var saturation: CGFloat = 0
            var brightness: CGFloat = 0
            var alpha: CGFloat = 0
            srgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
            let lifted = NSColor(
                hue: hue,
                saturation: min(saturation * 0.82, 1),
                brightness: min(brightness * 1.42, 1),
                alpha: 1
            )
            return lifted.usingColorSpace(.sRGB) ?? base
        })
    }

    /// Color → 0xRRGGBB，给「自定义强调色」落盘用
    var hexValue: UInt32 {
        guard let srgb = NSColor(self).usingColorSpace(.sRGB) else { return 0x46734F }
        let r = UInt32((srgb.redComponent * 255).rounded())
        let g = UInt32((srgb.greenComponent * 255).rounded())
        let b = UInt32((srgb.blueComponent * 255).rounded())
        return (r << 16) | (g << 8) | b
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

    /// AI 按钮的强调渐变。
    ///
    /// 和 `aiGradient` 分开：那个是低饱和、给文字着色的；这个要能在玻璃底上认出「这是 AI」。
    /// 但也别调太艳——实底高饱和会把液态玻璃的透感压死，所以只用在图标和描边上，
    /// 底色仍然是玻璃。
    static let aiButtonGradient = LinearGradient(
        colors: [Color.hex(0x2FA98C), Color.hex(0x4B85CB)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

/// 液态玻璃需要背后有内容才能"折射"。玻璃效果要看得见，底色就不能太淡——
/// 这里用三个大色斑做底，左上那个正好落在顶栏按钮后面。
///
/// 强度可在「外观」里调（无 / 柔和 / 标准）。关掉后玻璃面板仍在，但会显得很平，
/// 设置页里对此有说明。
///
/// **必须把设置当参数传进来**，不能让 body 自己去读 `UIState`：
/// 这是个无参数视图，SwiftUI 认为它没变化就不会重跑 body，
/// 结果就是改完背景模糊度要重启 App 才生效。
struct AppBackground: View {
    let settings: UISettings

    private var strength: Double { settings.backdrop.opacity }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(nsColor: .windowBackgroundColor)

                if hasImage,
                   let image = BackgroundImage.rendered(path: settings.backgroundPath,
                                                        blur: settings.backgroundBlur) {
                    // 用 GeometryReader 给死宽高：`aspectRatio(.fill)` 会按图片比例
                    // 反推出一个巨大的理想尺寸，把整个窗口的布局撑大（拉大窗口后排版全乱就是这个）
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: settings.backgroundFill.contentMode)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()

                    // 压一层暗色：不然浅色文字和玻璃面板会糊在图上
                    Color.black.opacity(settings.backgroundDim)
                } else if strength > 0 {
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
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .ignoresSafeArea()
    }

    private var hasImage: Bool {
        !settings.backgroundPath.isEmpty
            && FileManager.default.fileExists(atPath: settings.backgroundPath)
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
        self
            .glassEffect(.regular, in: .rect(cornerRadius: radius))
            // 玻璃本身不会裁子视图：滚动内容（行背景、分隔线）会从圆角处露出方角，
            // 看起来就是面板底部多出一个尖角
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    /// 细滚动条：浮层 3pt，默认不显示，鼠标进入或滚动时淡入，**不改变内容宽度**。
    /// 实现见 `ThinScrollbar.swift`。
    func hoverScrollIndicators() -> some View {
        modifier(ThinScrollbar())
    }

    func faintSeparator() -> some View {
        self.overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 1)
        }
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
