import Foundation

/// What Settings → Appearance offers: a theme, or following the system.
public enum ThemeChoice: String, CaseIterable, Identifiable, Sendable {
    case system
    case graphite
    case paper
    case ink

    public var id: String { rawValue }

    /// Whether the theme is drawn as a dark appearance, so system controls
    /// match it. `nil` follows the system.
    public var isDark: Bool? {
        switch self {
        case .system: nil
        case .graphite, .ink: true
        case .paper: false
        }
    }

    /// The palette to draw in, for an appearance. A view forced light or dark
    /// (a settings preview, say) gets that side's palette; Match System uses
    /// Ink when macOS's "Increase contrast" is on in Dark mode.
    public func theme(dark: Bool, increasedContrast: Bool) -> Theme {
        switch self {
        case .graphite, .paper: dark ? .graphite : .paper
        case .ink: dark ? .ink : .paper
        case .system: dark ? (increasedContrast ? .ink : .graphite) : .paper
        }
    }

    /// The palette the window draws in: a named theme is itself whatever
    /// the Mac is set to (Graphite stays dark on a Mac set to Light); only
    /// Match System follows the Mac's appearance.
    public func resolved(systemDark: Bool, increasedContrast: Bool) -> Theme {
        theme(dark: isDark ?? systemDark, increasedContrast: increasedContrast)
    }

    /// Paper's borders strengthen under Match System when "Increase contrast"
    /// is on; picking a theme by name keeps it as it is.
    public func strongerBorders(dark: Bool, increasedContrast: Bool) -> Bool {
        self == .system && !dark && increasedContrast
    }
}

/// The palettes Abstract draws in.
public enum Theme: String, CaseIterable, Sendable {
    /// Dark gray.
    case graphite
    /// White.
    case paper
    /// True black with high contrast.
    case ink
}

/// An sRGB colour with its opacity.
public struct Swatch: Equatable, Sendable {
    public let hex: UInt32
    public let alpha: Double

    public init(_ hex: UInt32, alpha: Double = 1) {
        self.hex = hex
        self.alpha = alpha
    }

    public var red: Double { Double((hex >> 16) & 0xFF) / 255 }
    public var green: Double { Double((hex >> 8) & 0xFF) / 255 }
    public var blue: Double { Double(hex & 0xFF) / 255 }

    /// This colour drawn over an opaque one.
    public func over(_ background: Swatch) -> Swatch {
        func mix(_ top: Double, _ bottom: Double) -> UInt32 { UInt32(((top * alpha + bottom * (1 - alpha)) * 255).rounded()) }
        return Swatch(mix(red, background.red) << 16 | mix(green, background.green) << 8 | mix(blue, background.blue))
    }

    /// WCAG relative luminance.
    public var luminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG contrast ratio of this colour drawn over an opaque background.
    public func contrast(on background: Swatch) -> Double {
        let a = over(background).luminance, b = background.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

/// Every semantic colour in the app, with its value in each theme.
public enum PaletteRole: String, CaseIterable, Sendable {
    // Surfaces, back to front.
    case canvas, sidebar, surface, surfaceRaised, code, inset
    // Interaction washes.
    case hover, selection
    // Text inputs.
    case field, fieldBorder, fieldBorderFocused
    // Hairlines.
    case border, borderStrong
    // Text.
    case text, prose, textSecondary, textTertiary
    // Usage chart series.
    case usageClaude, usageCodex, usageOpenCode, usageMuse
    // Pull request states, and text on their washes.
    case pullRequestOpen, pullRequestDraft, pullRequestMerged, pullRequestClosed
    case pullRequestOpenInk, pullRequestDraftInk, pullRequestMergedInk, pullRequestClosedInk
    // Syntax.
    case syntaxKeyword, syntaxString, syntaxLiteral, syntaxType, syntaxFunction
    case syntaxComment, syntaxOperator, syntaxTag, syntaxPlain
    // Emphasis.
    case accent, onAccent
    // Meaning.
    case added, removed, warning, attention, addedWash, removedWash, findMatch, findCurrent

    /// The value in a theme.
    public func swatch(in theme: Theme, strongerBorders: Bool = false) -> Swatch {
        let values = self.values
        switch theme {
        case .graphite: return values.graphite
        case .paper: return strongerBorders ? (strongPaper ?? values.paper) : values.paper
        case .ink: return values.ink
        }
    }

    /// Text and status colours, which must read on the surfaces they sit on.
    public static let foregrounds: [PaletteRole] = [
        .text, .prose, .textSecondary, .textTertiary,
        .usageClaude, .usageCodex, .usageOpenCode, .usageMuse,
        .pullRequestOpenInk, .pullRequestDraftInk, .pullRequestMergedInk, .pullRequestClosedInk,
        .syntaxKeyword, .syntaxString, .syntaxLiteral, .syntaxType, .syntaxFunction,
        .syntaxComment, .syntaxOperator, .syntaxTag, .syntaxPlain,
        .added, .removed, .warning, .attention,
    ]

    /// The opaque surfaces text is drawn on.
    public static let backgrounds: [PaletteRole] = [.canvas, .sidebar, .surface, .surfaceRaised, .code, .inset]

    // Paper under Match System with "Increase contrast": hairlines and field
    // edges you can see without looking for them.
    private var strongPaper: Swatch? {
        switch self {
        case .border: Swatch(0x000000, alpha: 0.2)
        case .borderStrong: Swatch(0x000000, alpha: 0.32)
        case .fieldBorder: Swatch(0x000000, alpha: 0.32)
        case .fieldBorderFocused: Swatch(0x000000, alpha: 0.6)
        default: nil
        }
    }

    private var values: (graphite: Swatch, paper: Swatch, ink: Swatch) {
        switch self {
        case .canvas: (Swatch(0x1E1E21), Swatch(0xFFFFFF), Swatch(0x000000))
        case .sidebar: (Swatch(0x19191C), Swatch(0xF5F5F7), Swatch(0x000000))
        case .surface: (Swatch(0x252529), Swatch(0xF6F6F8), Swatch(0x0B0B0C))
        case .surfaceRaised: (Swatch(0x2B2B30), Swatch(0xFFFFFF), Swatch(0x141416))
        case .code: (Swatch(0x18181B), Swatch(0xFAFAFB), Swatch(0x000000))
        case .inset: (Swatch(0x303036), Swatch(0xEFEFF2), Swatch(0x1C1C1F))

        case .hover: (Swatch(0xFFFFFF, alpha: 0.05), Swatch(0x000000, alpha: 0.04), Swatch(0xFFFFFF, alpha: 0.10))
        case .selection: (Swatch(0xFFFFFF, alpha: 0.085), Swatch(0x000000, alpha: 0.065), Swatch(0xFFFFFF, alpha: 0.18))

        case .field: (Swatch(0x232327), Swatch(0xFFFFFF), Swatch(0x0B0B0C))
        case .fieldBorder: (Swatch(0xFFFFFF, alpha: 0.11), Swatch(0x000000, alpha: 0.13), Swatch(0xFFFFFF, alpha: 0.40))
        case .fieldBorderFocused: (Swatch(0xFFFFFF, alpha: 0.34), Swatch(0x000000, alpha: 0.38), Swatch(0xFFFFFF, alpha: 0.80))

        case .border: (Swatch(0xFFFFFF, alpha: 0.075), Swatch(0x000000, alpha: 0.08), Swatch(0xFFFFFF, alpha: 0.25))
        case .borderStrong: (Swatch(0xFFFFFF, alpha: 0.12), Swatch(0x000000, alpha: 0.13), Swatch(0xFFFFFF, alpha: 0.40))

        case .text: (Swatch(0xECECEF), Swatch(0x1D1D1F), Swatch(0xFFFFFF))
        case .prose: (Swatch(0xDCDCE1), Swatch(0x242428), Swatch(0xF2F2F4))
        case .textSecondary: (Swatch(0xA4A4AD), Swatch(0x5C5C66), Swatch(0xD0D0D6))
        case .textTertiary: (Swatch(0x75757E), Swatch(0x8C8C96), Swatch(0xA6A6AF))

        case .usageClaude: (Swatch(0xD97757), Swatch(0xC2613F), Swatch(0xE58A6A))
        case .usageCodex: (Swatch(0x8E9DB5), Swatch(0x5B6B82), Swatch(0xA3B2C9))
        case .usageOpenCode: (Swatch(0x6FC2AB), Swatch(0x3D8B78), Swatch(0x7FD6BE))
        case .usageMuse: (Swatch(0xB49BDB), Swatch(0x7556A8), Swatch(0xC6B1EC))

        case .pullRequestOpen: (Swatch(0x238636), Swatch(0x1F883D), Swatch(0x2EA043))
        case .pullRequestDraft: (Swatch(0x6E7681), Swatch(0x6E7781), Swatch(0x8B949E))
        case .pullRequestMerged: (Swatch(0x8957E5), Swatch(0x8250DF), Swatch(0xA371F7))
        case .pullRequestClosed: (Swatch(0xDA3633), Swatch(0xCF222E), Swatch(0xF85149))
        case .pullRequestOpenInk: (Swatch(0x6BC98A), Swatch(0x1A7F37), Swatch(0x7EE2A0))
        case .pullRequestDraftInk: (Swatch(0xA0A8B2), Swatch(0x59636E), Swatch(0xB4BCC6))
        case .pullRequestMergedInk: (Swatch(0xB79CF0), Swatch(0x7A48C9), Swatch(0xC9B2FF))
        case .pullRequestClosedInk: (Swatch(0xF08A84), Swatch(0xC0262E), Swatch(0xFF9A94))

        // One Dark on Graphite, One Light on Paper, as Paseo colours code;
        // a brightened One Dark on Ink.
        case .syntaxKeyword: (Swatch(0xC678DD), Swatch(0xA626A4), Swatch(0xD49BF2))
        case .syntaxString: (Swatch(0x98C379), Swatch(0x50A14F), Swatch(0xA8D88A))
        case .syntaxLiteral: (Swatch(0xD19A66), Swatch(0x986801), Swatch(0xE8A872))
        case .syntaxType: (Swatch(0xE5C07B), Swatch(0xC18401), Swatch(0xF0CC86))
        case .syntaxFunction: (Swatch(0x61AFEF), Swatch(0x4078F2), Swatch(0x7CC0FF))
        case .syntaxComment: (Swatch(0x5C6370), Swatch(0xA0A1A7), Swatch(0x9AA3B4))
        case .syntaxOperator: (Swatch(0x56B6C2), Swatch(0x0184BC), Swatch(0x6ED3DD))
        case .syntaxTag: (Swatch(0xE06C75), Swatch(0xE45649), Swatch(0xFF8A92))
        case .syntaxPlain: (Swatch(0xABB2BF), Swatch(0x383A42), Swatch(0xD4D9E2))

        case .accent: (Swatch(0xECECEF), Swatch(0x1D1D1F), Swatch(0xFFFFFF))
        case .onAccent: (Swatch(0x1E1E21), Swatch(0xFFFFFF), Swatch(0x000000))

        case .added: (Swatch(0x4CC38A), Swatch(0x1A7F37), Swatch(0x5BE49B))
        case .removed: (Swatch(0xEF6461), Swatch(0xCF222E), Swatch(0xFF7A75))
        case .warning: (Swatch(0xD2D2D8), Swatch(0x3A3A40), Swatch(0xE8E8EC))
        case .attention: (Swatch(0xF2F2F4), Swatch(0x1D1D1F), Swatch(0xFFFFFF))
        case .addedWash: (Swatch(0x4CC38A, alpha: 0.10), Swatch(0x1A7F37, alpha: 0.07), Swatch(0x5BE49B, alpha: 0.18))
        case .removedWash: (Swatch(0xEF6461, alpha: 0.10), Swatch(0xCF222E, alpha: 0.06), Swatch(0xFF7A75, alpha: 0.18))
        case .findMatch: (Swatch(0xFFFFFF, alpha: 0.16), Swatch(0x000000, alpha: 0.11), Swatch(0xFFFFFF, alpha: 0.26))
        case .findCurrent: (Swatch(0xE2C044, alpha: 0.55), Swatch(0xF5D547, alpha: 0.8), Swatch(0xF5D547, alpha: 0.5))
        }
    }
}
