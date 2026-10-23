import AppKit
import SwiftUI

enum AvatarPalette {
    static let colors: [Color] = [
        Color(red: 0.20, green: 0.55, blue: 0.72),
        Color(red: 0.42, green: 0.38, blue: 0.78),
        Color(red: 0.82, green: 0.42, blue: 0.36),
        Color(red: 0.20, green: 0.60, blue: 0.48),
        Color(red: 0.78, green: 0.54, blue: 0.20),
        Color(red: 0.55, green: 0.38, blue: 0.68),
    ]

    /// String.hashValue 每次启动都变，这里用稳定的加权哈希
    static func stableHash(_ value: String) -> Int {
        var h = 0
        for scalar in value.unicodeScalars {
            h = (h &* 31 &+ Int(scalar.value)) & 0x7fff_ffff
        }
        return h
    }

    static func color(for provider: AIProvider) -> Color {
        let seed = provider.avatarSeed ?? stableHash(provider.id)
        return colors[abs(seed) % colors.count]
    }
}

struct ProviderAvatar: View {
    let provider: AIProvider
    var size: CGFloat = 32

    var body: some View {
        Group {
            if let data = provider.avatarImage, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    AvatarPalette.color(for: provider)
                    Text(provider.initial.isEmpty ? "?" : provider.initial)
                        .font(.system(size: size * 0.42, weight: .medium))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
    }
}
