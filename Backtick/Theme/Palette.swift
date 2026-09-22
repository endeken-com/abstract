import AppKit
import SwiftUI

/// The two themes Backtick ships with, plus following the system.
enum ThemeChoice: String, CaseIterable, Identifiable {
    case system
    case graphite
    case paper

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "Match System"
        case .graphite: "Graphite"
        case .paper: "Paper"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .graphite: .dark
        case .paper: .light
        }
    }
}

/// Semantic colours. Each resolves per appearance, so a view written once
/// reads well in Graphite (dark gray) and Paper (white) alike. `nonisolated`
/// because AppKit resolves dynamic colours on whatever thread draws.
nonisolated extension Color {
    // Surfaces, back to front.
    static let btCanvas = dynamic(light: 0xFFFFFF, dark: 0x1E1E21)
    static let btSidebar = dynamic(light: 0xF5F5F7, dark: 0x19191C)
    static let btSurface = dynamic(light: 0xF6F6F8, dark: 0x252529)
    static let btSurfaceRaised = dynamic(light: 0xFFFFFF, dark: 0x2B2B30)
    static let btCode = dynamic(light: 0xFAFAFB, dark: 0x18181B)
    static let btInset = dynamic(light: 0xEFEFF2, dark: 0x303036)

    // Interaction washes.
    static let btHover = dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.04, darkAlpha: 0.05)
    static let btSelection = dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.065, darkAlpha: 0.085)

    // Hairlines.
    static let btBorder = dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.075)
    static let btBorderStrong = dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.13, darkAlpha: 0.12)

    // Text.
    static let btText = dynamic(light: 0x1D1D1F, dark: 0xECECEF)
    static let btTextSecondary = dynamic(light: 0x5C5C66, dark: 0xA4A4AD)
    static let btTextTertiary = dynamic(light: 0x8C8C96, dark: 0x75757E)

    // Meaning. Tuned per theme instead of raw system colours, so diffs and
    // status stay legible on both white and gray.
    static let btAdded = dynamic(light: 0x1A7F37, dark: 0x4CC38A)
    static let btRemoved = dynamic(light: 0xCF222E, dark: 0xEF6461)
    static let btWarning = dynamic(light: 0x9A6700, dark: 0xE5A33A)
    static let btAttention = dynamic(light: 0xD4560B, dark: 0xF28C38)
    static let btAddedWash = dynamic(light: 0xDAFBE1, dark: 0x4CC38A, lightAlpha: 1, darkAlpha: 0.13)
    static let btRemovedWash = dynamic(light: 0xFFEBE9, dark: 0xEF6461, lightAlpha: 1, darkAlpha: 0.13)

    private static func dynamic(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { @Sendable appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight]) == .darkAqua
                || appearance.bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight]) == .vibrantDark
            return NSColor(hex: isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }
}

nonisolated extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}
