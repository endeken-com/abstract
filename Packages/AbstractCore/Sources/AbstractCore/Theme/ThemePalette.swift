import Foundation

/// Whether a theme is drawn light or dark, so system controls match it.
public enum ThemeAppearance: String, Sendable, Hashable, Codable, CaseIterable {
    case light, dark

    public var isDark: Bool { self == .dark }
}

/// What Settings → Appearance offers: an installed theme by its id, or
/// following the system with a light and a dark pick (ABS-185).
public struct ThemeChoice: RawRepresentable, Sendable, Hashable, Identifiable {
    public let rawValue: String

    /// Names saved before themes were plugins read as the bundled themes,
    /// so nobody's choice changes.
    public init(rawValue: String) {
        switch rawValue {
        case "graphite": self.rawValue = ThemeCatalog.graphiteId
        case "paper": self.rawValue = ThemeCatalog.paperId
        case "ink": self.rawValue = ThemeCatalog.inkId
        default: self.rawValue = rawValue
        }
    }

    public init(_ theme: Theme) { self.init(rawValue: theme.id) }

    public var id: String { rawValue }

    public static let system = ThemeChoice(rawValue: "system")
    /// What a new Mac starts in.
    public static let `default` = ThemeChoice(rawValue: ThemeCatalog.graphiteId)

    public var isSystem: Bool { self == .system }
}

/// The light and dark theme Match System switches between.
public struct ThemePicks: Sendable, Hashable {
    public var light: String
    public var dark: String

    public init(light: String = ThemeCatalog.paperId, dark: String = ThemeCatalog.graphiteId) {
        self.light = ThemeChoice(rawValue: light).rawValue
        self.dark = ThemeChoice(rawValue: dark).rawValue
    }

    public static let standard = ThemePicks()
}

public extension ThemeChoice {
    /// Whether the theme is drawn as a dark appearance, so system controls
    /// match it. `nil` follows the system.
    func isDark(in catalog: ThemeCatalog) -> Bool? {
        isSystem ? nil : catalog.theme(rawValue).isDark
    }

    /// The palette to draw in, for an appearance. A view forced light or dark
    /// (a settings preview, say) gets that side's Match System pick when the
    /// theme is the other side's; Match System uses Ink when macOS's
    /// "Increase contrast" is on in Dark mode, while the dark pick is the
    /// standard one.
    func theme(dark: Bool, increasedContrast: Bool, catalog: ThemeCatalog, picks: ThemePicks = .standard) -> Theme {
        if !isSystem {
            let theme = catalog.theme(rawValue)
            if theme.isDark == dark { return theme }
        }
        guard dark else { return catalog.theme(picks.light, appearance: .light) }
        if isSystem, increasedContrast, picks.dark == ThemeCatalog.graphiteId {
            return catalog.theme(ThemeCatalog.inkId, appearance: .dark)
        }
        return catalog.theme(picks.dark, appearance: .dark)
    }

    /// The palette the window draws in: a named theme is itself whatever
    /// the Mac is set to (Graphite stays dark on a Mac set to Light); only
    /// Match System follows the Mac's appearance.
    func resolved(systemDark: Bool, increasedContrast: Bool, catalog: ThemeCatalog, picks: ThemePicks = .standard) -> Theme {
        theme(dark: isDark(in: catalog) ?? systemDark, increasedContrast: increasedContrast, catalog: catalog, picks: picks)
    }

    /// A light theme's borders strengthen under Match System when "Increase
    /// contrast" is on; picking a theme by name keeps it as it is.
    func strongerBorders(dark: Bool, increasedContrast: Bool) -> Bool {
        isSystem && !dark && increasedContrast
    }
}

/// A palette Abstract draws in: one installed theme, every role derived
/// from its plugin's colours (`ThemeDerivation`).
public struct Theme: Sendable, Hashable, Identifiable {
    /// `<plugin id>/theme/<theme id>`, as Paseo names a plugin's theme.
    public let id: String
    public let name: String
    public let appearance: ThemeAppearance
    /// The plugin's own id for it, like `graphite`: what plugin pages see
    /// as `data-abstract-theme`.
    public let shortId: String
    public let pluginId: String
    let palette: [PaletteRole: Swatch]
    let strongPalette: [PaletteRole: Swatch]

    public init(pluginId: String, contribution: ThemeContribution) {
        self.pluginId = pluginId
        id = Self.id(pluginId: pluginId, themeId: contribution.id)
        name = contribution.name.trimmingCharacters(in: .whitespacesAndNewlines)
        appearance = contribution.appearance
        shortId = contribution.id
        palette = ThemeDerivation.palette(for: contribution)
        strongPalette = ThemeDerivation.strongerBorders(appearance: contribution.appearance)
    }

    public static func id(pluginId: String, themeId: String) -> String { "\(pluginId)/theme/\(themeId)" }

    public var isDark: Bool { appearance.isDark }

    /// The value of a role. `strongerBorders` applies to light themes only.
    public func swatch(_ role: PaletteRole, strongerBorders: Bool = false) -> Swatch {
        if strongerBorders, let strong = strongPalette[role] { return strong }
        return palette[role] ?? Swatch(0x000000)
    }

    public var canvas: Swatch { swatch(.canvas) }
}

/// An sRGB colour with its opacity.
public struct Swatch: Equatable, Hashable, Sendable {
    public let hex: UInt32
    public let alpha: Double

    public init(_ hex: UInt32, alpha: Double = 1) {
        self.hex = hex
        self.alpha = alpha
    }

    /// `#rgb`, `#rrggbb` or `#rrggbbaa`, the colours a theme plugin writes.
    public init?(css: String) {
        guard ThemeContribution.isHexColor(css) else { return nil }
        var digits = String(css.dropFirst())
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard let value = UInt64(digits, radix: 16) else { return nil }
        if digits.count == 8 {
            self.init(UInt32(value >> 8), alpha: Double(value & 0xFF) / 255)
        } else {
            self.init(UInt32(value))
        }
    }

    /// `#rrggbb`, or `#rrggbbaa` when it's see-through.
    public var css: String {
        let hex = String(format: "%06x", hex)
        return alpha >= 1 ? "#\(hex)" : "#\(hex)\(String(format: "%02x", Int((alpha * 255).rounded())))"
    }

    public var red: Double { Double((hex >> 16) & 0xFF) / 255 }
    public var green: Double { Double((hex >> 8) & 0xFF) / 255 }
    public var blue: Double { Double(hex & 0xFF) / 255 }

    /// This colour drawn over an opaque one.
    public func over(_ background: Swatch) -> Swatch {
        func mix(_ top: Double, _ bottom: Double) -> UInt32 { UInt32(((top * alpha + bottom * (1 - alpha)) * 255).rounded()) }
        return Swatch(mix(red, background.red) << 16 | mix(green, background.green) << 8 | mix(blue, background.blue))
    }

    /// This colour moved `amount` of the way to `other`, opacity kept.
    public func mixed(toward other: Swatch, by amount: Double) -> Swatch {
        func mix(_ a: Double, _ b: Double) -> UInt32 { UInt32(((a + (b - a) * amount) * 255).rounded()) }
        return Swatch(mix(red, other.red) << 16 | mix(green, other.green) << 8 | mix(blue, other.blue), alpha: alpha)
    }

    public func withAlpha(_ alpha: Double) -> Swatch { Swatch(hex, alpha: alpha) }

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

/// Every semantic colour in the app. Its value in a theme comes from the
/// theme's plugin, through `ThemeDerivation`.
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
    // The terminal's 16 colours: black, red, green, yellow, blue, magenta,
    // cyan, white, then the bright set.
    case terminalBlack, terminalRed, terminalGreen, terminalYellow
    case terminalBlue, terminalMagenta, terminalCyan, terminalWhite
    case terminalBrightBlack, terminalBrightRed, terminalBrightGreen, terminalBrightYellow
    case terminalBrightBlue, terminalBrightMagenta, terminalBrightCyan, terminalBrightWhite

    /// The value in a theme.
    public func swatch(in theme: Theme, strongerBorders: Bool = false) -> Swatch {
        theme.swatch(self, strongerBorders: strongerBorders)
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

    /// The terminal's colours, in ANSI order.
    public static let terminal: [PaletteRole] = [
        .terminalBlack, .terminalRed, .terminalGreen, .terminalYellow,
        .terminalBlue, .terminalMagenta, .terminalCyan, .terminalWhite,
        .terminalBrightBlack, .terminalBrightRed, .terminalBrightGreen, .terminalBrightYellow,
        .terminalBrightBlue, .terminalBrightMagenta, .terminalBrightCyan, .terminalBrightWhite,
    ]
}
