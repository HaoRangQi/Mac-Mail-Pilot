import SwiftUI

enum Theme {
    static let panelRadius: CGFloat = 18
    static let gap: CGFloat = 10
    static let sidebarWidth: CGFloat = 216
    static let listWidth: CGFloat = 340

    /// AI 相关的统一渐变（紫 → 蓝）
    static let aiGradient = LinearGradient(
        colors: [
            Color(red: 0.55, green: 0.45, blue: 0.95),
            Color(red: 0.36, green: 0.66, blue: 0.96),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

/// 液态玻璃需要背后有内容才能"折射"，这里用极淡的色块做底。
struct AppBackground: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            Circle()
                .fill(Color(red: 0.36, green: 0.55, blue: 0.95).opacity(0.18))
                .frame(width: 560, height: 560)
                .blur(radius: 130)
                .offset(x: -340, y: -300)
            Circle()
                .fill(Color(red: 0.62, green: 0.42, blue: 0.92).opacity(0.14))
                .frame(width: 520, height: 520)
                .blur(radius: 140)
                .offset(x: 380, y: 320)
            Circle()
                .fill(Color(red: 0.30, green: 0.78, blue: 0.72).opacity(0.10))
                .frame(width: 420, height: 420)
                .blur(radius: 120)
                .offset(x: 120, y: -360)
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
