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
    static let sidebarWidth: CGFloat = 216
    static let listWidth: CGFloat = 340

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

    /// 全局强调色（按钮、选中态、控件）
    static let accent = moss

    /// AI 相关渐变（绿 → 蓝灰，替换掉原来不搭的紫蓝）
    static let aiGradient = LinearGradient(
        colors: [moss, slate],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

/// 液态玻璃需要背后有内容才能"折射"。玻璃效果要看得见，底色就不能太淡——
/// 这里用三个大色斑做底，左上那个正好落在顶栏按钮后面。
struct AppBackground: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            Circle()
                .fill(Theme.moss.opacity(0.32))
                .frame(width: 620, height: 620)
                .blur(radius: 120)
                .offset(x: -320, y: -280)
            Circle()
                .fill(Theme.gold.opacity(0.24))
                .frame(width: 520, height: 520)
                .blur(radius: 130)
                .offset(x: 360, y: 300)
            Circle()
                .fill(Theme.slate.opacity(0.22))
                .frame(width: 460, height: 460)
                .blur(radius: 110)
                .offset(x: 150, y: -340)
        }
        .ignoresSafeArea()
    }
}

extension View {
    func glassPanel(radius: CGFloat = Theme.panelRadius) -> some View {
        self.glassEffect(.regular, in: .rect(cornerRadius: radius))
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
            .font(.system(size: 10.5, weight: .medium))
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
            .font(.system(size: 10.5, weight: .medium))
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
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.05), in: Capsule())
    }
}
