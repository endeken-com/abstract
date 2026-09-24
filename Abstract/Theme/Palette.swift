import AppKit
import SwiftUI

/// The two themes Abstract ships with, plus following the system.
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

    // Text inputs: a steady fill; only the border answers focus.
    static let btField = dynamic(light: 0xFFFFFF, dark: 0x232327)
    static let btFieldBorder = dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.13, darkAlpha: 0.11)
    static let btFieldBorderFocused = dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.38, darkAlpha: 0.34)

    // Hairlines.
    static let btBorder = dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.075)
    static let btBorderStrong = dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.13, darkAlpha: 0.12)

    // Text.
    static let btText = dynamic(light: 0x1D1D1F, dark: 0xECECEF)
    /// Long-form prose: a touch softer than `btText` so paragraphs don't glare.
    static let btProse = dynamic(light: 0x242428, dark: 0xDCDCE1)
    static let btTextSecondary = dynamic(light: 0x5C5C66, dark: 0xA4A4AD)
    static let btTextTertiary = dynamic(light: 0x8C8C96, dark: 0x75757E)

    // Usage chart series: Claude's clay, and a quiet slate for Codex.
    static let btUsageClaude = dynamic(light: 0xC2613F, dark: 0xD97757)
    static let btUsageCodex = dynamic(light: 0x5B6B82, dark: 0x8E9DB5)

    // Pull request states, as GitHub colours them (only the title's menu uses these, as a wash).
    static let btPullRequestOpen = dynamic(light: 0x1F883D, dark: 0x238636)
    static let btPullRequestDraft = dynamic(light: 0x6E7781, dark: 0x6E7681)
    static let btPullRequestMerged = dynamic(light: 0x8250DF, dark: 0x8957E5)
    static let btPullRequestClosed = dynamic(light: 0xCF222E, dark: 0xDA3633)
    /// Text on those colours' washes: the same hue, readable on the canvas.
    static let btPullRequestOpenInk = dynamic(light: 0x1A7F37, dark: 0x6BC98A)
    static let btPullRequestDraftInk = dynamic(light: 0x59636E, dark: 0xA0A8B2)
    static let btPullRequestMergedInk = dynamic(light: 0x7A48C9, dark: 0xB79CF0)
    static let btPullRequestClosedInk = dynamic(light: 0xC0262E, dark: 0xF08A84)

    // Syntax: One Dark on Graphite, One Light on Paper, as Paseo colours code
    // (see `SyntaxStyle`).
    static let btSyntaxKeyword = dynamic(light: 0xA626A4, dark: 0xC678DD)
    static let btSyntaxString = dynamic(light: 0x50A14F, dark: 0x98C379)
    static let btSyntaxLiteral = dynamic(light: 0x986801, dark: 0xD19A66)
    static let btSyntaxType = dynamic(light: 0xC18401, dark: 0xE5C07B)
    static let btSyntaxFunction = dynamic(light: 0x4078F2, dark: 0x61AFEF)
    static let btSyntaxComment = dynamic(light: 0xA0A1A7, dark: 0x5C6370)
    static let btSyntaxOperator = dynamic(light: 0x0184BC, dark: 0x56B6C2)
    static let btSyntaxTag = dynamic(light: 0xE45649, dark: 0xE06C75)
    static let btSyntaxPlain = dynamic(light: 0x383A42, dark: 0xABB2BF)

    /// The single emphasis colour: near-black on Paper, near-white on
    /// Graphite. Primary buttons, the working spinner, focus, selection marks.
    static let btAccent = dynamic(light: 0x1D1D1F, dark: 0xECECEF)
    /// Text and icons drawn on `btAccent`.
    static let btOnAccent = dynamic(light: 0xFFFFFF, dark: 0x1E1E21)

    // Meaning. Tuned per theme instead of raw system colours, so diffs and
    // status stay legible on both white and gray.
    static let btAdded = dynamic(light: 0x1A7F37, dark: 0x4CC38A)
    static let btRemoved = dynamic(light: 0xCF222E, dark: 0xEF6461)
    /// Caution, as a strong neutral: warnings carry an icon and plain words,
    /// never orange.
    static let btWarning = dynamic(light: 0x3A3A40, dark: 0xD2D2D8)
    /// "Needs you": the strongest neutral, not a colour. Abstract uses no
    /// orange or blue; emphasis comes from contrast and weight.
    static let btAttention = dynamic(light: 0x1D1D1F, dark: 0xF2F2F4)
    static let btAddedWash = dynamic(light: 0x1A7F37, dark: 0x4CC38A, lightAlpha: 0.07, darkAlpha: 0.10)
    static let btRemovedWash = dynamic(light: 0xCF222E, dark: 0xEF6461, lightAlpha: 0.06, darkAlpha: 0.10)

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
