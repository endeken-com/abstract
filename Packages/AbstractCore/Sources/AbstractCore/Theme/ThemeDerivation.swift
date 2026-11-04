import Foundation

// Themes are plugin contributions (ABS-185). The schema is Paseo's theme
// contribution, and the eight colours expand into the full palette the way
// Paseo's `buildDarkPluginTheme` / `buildLightPluginTheme` expand them
// (packages/app/src/plugins/themes/index.ts, packages/app/src/styles/theme.ts
// in getpaseo/paseo, Apache-2.0; see THIRD_PARTY_NOTICES.md), adapted to
// Abstract's palette roles.

/// One theme in a plugin's `contributes.themes`: Paseo's schema, plus
/// `tokens`, which sets any of Abstract's palette roles outright.
public struct ThemeContribution: Sendable, Hashable, Codable {
    public var id: String
    public var name: String
    public var appearance: ThemeAppearance
    public var colors: Colors
    /// Palette roles by name, each a hex colour, taken as written.
    public var tokens: [String: String]?

    public struct Colors: Sendable, Hashable, Codable {
        public var background: String
        public var foreground: String
        public var raised: String
        public var control: String
        public var border: String
        /// Optional, as in Paseo: `foreground` when left out.
        public var accent: String?
        public var mutedForeground: String
        public var ring: String

        public init(background: String, foreground: String, raised: String, control: String, border: String,
                    accent: String? = nil, mutedForeground: String, ring: String) {
            self.background = background; self.foreground = foreground; self.raised = raised
            self.control = control; self.border = border; self.accent = accent
            self.mutedForeground = mutedForeground; self.ring = ring
        }

        static let keys: Set<String> = ["background", "foreground", "raised", "control", "border", "accent",
                                        "mutedForeground", "ring"]

        // Strict, like Paseo's `z.strictObject`: a colour this host doesn't
        // know fails the install instead of being dropped.
        public init(from decoder: Decoder) throws {
            try ThemeContribution.refuseUnknownKeys(decoder, allowed: Self.keys)
            let box = try decoder.container(keyedBy: CodingKeys.self)
            background = try box.decode(String.self, forKey: .background)
            foreground = try box.decode(String.self, forKey: .foreground)
            raised = try box.decode(String.self, forKey: .raised)
            control = try box.decode(String.self, forKey: .control)
            border = try box.decode(String.self, forKey: .border)
            accent = try box.decodeIfPresent(String.self, forKey: .accent)
            mutedForeground = try box.decode(String.self, forKey: .mutedForeground)
            ring = try box.decode(String.self, forKey: .ring)
        }

        var all: [(String, String)] {
            [("background", background), ("foreground", foreground), ("raised", raised), ("control", control),
             ("border", border), ("mutedForeground", mutedForeground), ("ring", ring)]
                + (accent.map { [("accent", $0)] } ?? [])
        }
    }

    public init(id: String, name: String, appearance: ThemeAppearance, colors: Colors, tokens: [String: String]? = nil) {
        self.id = id; self.name = name; self.appearance = appearance; self.colors = colors; self.tokens = tokens
    }

    static let keys: Set<String> = ["id", "name", "appearance", "colors", "tokens"]

    public init(from decoder: Decoder) throws {
        try Self.refuseUnknownKeys(decoder, allowed: Self.keys)
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decode(String.self, forKey: .id)
        name = try box.decode(String.self, forKey: .name)
        appearance = try box.decode(ThemeAppearance.self, forKey: .appearance)
        colors = try box.decode(Colors.self, forKey: .colors)
        tokens = try box.decodeIfPresent([String: String].self, forKey: .tokens)
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    static func refuseUnknownKeys(_ decoder: Decoder, allowed: Set<String>) throws {
        let keys = try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue)
        if let unknown = keys.first(where: { !allowed.contains($0) }) {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown key \(unknown)"))
        }
    }

    /// Paseo's rule: `#rgb`, `#rrggbb` or `#rrggbbaa`.
    public static func isHexColor(_ value: String) -> Bool {
        value.range(of: #"^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$"#, options: .regularExpression) != nil
    }

    public static let limit = 8

    /// Fails closed: a bad colour, an unknown role or a missing name refuses
    /// the plugin, like an unknown capability.
    public func validate() throws {
        guard !id.isEmpty, id.count <= 40, !id.contains("/"),
              id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }) else {
            throw PluginValidationError.invalidManifest("a theme needs an id of letters, digits, -, _ or .")
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 60 else {
            throw PluginValidationError.invalidManifest("theme \(id) needs a name of at most 60 characters")
        }
        for (key, value) in colors.all where !Self.isHexColor(value) {
            throw PluginValidationError.invalidManifest("theme \(id): \(key) must be a hex colour")
        }
        for (role, value) in tokens ?? [:] {
            guard PaletteRole(rawValue: role) != nil else {
                throw PluginValidationError.invalidManifest("theme \(id): unknown token \(role)")
            }
            guard Self.isHexColor(value) else {
                throw PluginValidationError.invalidManifest("theme \(id): \(role) must be a hex colour")
            }
        }
    }
}

/// Every palette role from a theme's eight colours.
public enum ThemeDerivation {
    /// The palette a theme draws in: derived from its colours, then its
    /// `tokens` on top, as written.
    public static func palette(for theme: ThemeContribution) -> [PaletteRole: Swatch] {
        var palette = derived(theme.colors, appearance: theme.appearance)
        for (name, value) in theme.tokens ?? [:] {
            if let role = PaletteRole(rawValue: name), let swatch = Swatch(css: value) { palette[role] = swatch }
        }
        return palette
    }

    /// The palette from the eight colours alone.
    public static func derived(_ colors: ThemeContribution.Colors, appearance: ThemeAppearance) -> [PaletteRole: Swatch] {
        func color(_ value: String?) -> Swatch? { value.flatMap(Swatch.init(css:)) }
        let dark = appearance.isDark
        let black = Swatch(0x000000)
        let background = color(colors.background) ?? (dark ? black : Swatch(0xFFFFFF))
        let foreground = color(colors.foreground) ?? (dark ? Swatch(0xFFFFFF) : black)
        let raised = color(colors.raised) ?? background
        let control = color(colors.control) ?? raised
        let border = color(colors.border) ?? foreground.withAlpha(0.1)
        let accent = color(colors.accent) ?? foreground
        let muted = color(colors.mutedForeground) ?? foreground
        let ring = color(colors.ring) ?? muted

        // A see-through hairline gets stronger by opacity; an opaque one by
        // moving toward the text.
        func stronger(_ swatch: Swatch) -> Swatch {
            swatch.alpha < 1 ? swatch.withAlpha(min(1, swatch.alpha * 1.6)) : swatch.mixed(toward: foreground, by: 0.15)
        }

        var palette: [PaletteRole: Swatch] = [
            .canvas: background,
            .code: dark ? background.mixed(toward: black, by: 0.2) : background.mixed(toward: raised, by: 0.5),
            .sidebar: dark ? background.mixed(toward: black, by: 0.17) : raised,
            .surface: raised,
            .surfaceRaised: dark ? raised.mixed(toward: control, by: 0.5) : background,
            .inset: control,
            .field: dark ? background.mixed(toward: raised, by: 0.5) : background,
            .border: border,
            .borderStrong: stronger(border),
            .fieldBorder: stronger(border),
            .fieldBorderFocused: ring,
            .hover: foreground.withAlpha(dark ? 0.05 : 0.04),
            .selection: foreground.withAlpha(dark ? 0.085 : 0.065),
            .findMatch: foreground.withAlpha(dark ? 0.16 : 0.11),
            .text: foreground,
            .attention: foreground,
            .accent: accent,
            .onAccent: background,
            .prose: foreground.mixed(toward: background, by: 0.08),
            .textSecondary: muted,
            .textTertiary: muted.mixed(toward: ring, by: 0.5),
            .warning: muted.mixed(toward: foreground, by: 0.65),
        ]
        for (role, darkValue, lightValue) in constants {
            palette[role] = Swatch(css: dark ? darkValue : lightValue)
        }
        lift(&palette, toward: dark ? Swatch(0xFFFFFF) : black)
        return palette
    }

    /// A derived text or status colour that doesn't read is moved toward
    /// white on a dark theme, black on a light one, until it clears 4.5:1
    /// on every surface (text and prose 7:1): the bar Ink is held to
    /// (ABS-68). A wash text sits on fades until the text reads on it.
    /// Colours a theme writes in `tokens` are never moved.
    static func lift(_ palette: inout [PaletteRole: Swatch], toward target: Swatch) {
        guard let canvas = palette[.canvas] else { return }
        let surfaces = PaletteRole.backgrounds.compactMap { palette[$0]?.over(canvas) }
        for role in PaletteRole.foregrounds {
            guard var swatch = palette[role] else { continue }
            let floor = role == .text || role == .prose ? 7.0 : 4.5
            var steps = 0
            while steps < 40, surfaces.contains(where: { swatch.contrast(on: $0) < floor }) {
                swatch = swatch.mixed(toward: target, by: 0.05)
                steps += 1
            }
            palette[role] = swatch
        }
        // A wash text is drawn on fades until the text reads on it.
        guard let text = palette[.text] else { return }
        for role in [PaletteRole.hover, .selection, .findMatch, .findCurrent, .addedWash, .removedWash] {
            guard var wash = palette[role] else { continue }
            var steps = 0
            while steps < 20, wash.alpha > 0.05, text.contrast(on: wash.over(canvas)) < 4.5 {
                wash = wash.withAlpha(wash.alpha * 0.9)
                steps += 1
            }
            palette[role] = wash
        }
    }

    /// A light theme's hairlines and field edges under Match System with
    /// "Increase contrast" on: edges you can see without looking for them.
    public static func strongerBorders(appearance: ThemeAppearance) -> [PaletteRole: Swatch] {
        guard !appearance.isDark else { return [:] }
        return [
            .border: Swatch(0x000000, alpha: 0.2),
            .borderStrong: Swatch(0x000000, alpha: 0.32),
            .fieldBorder: Swatch(0x000000, alpha: 0.32),
            .fieldBorderFocused: Swatch(0x000000, alpha: 0.6),
        ]
    }

    /// Colours that don't come from a theme's eight, per appearance, as
    /// Paseo keeps its diff, status and terminal colours: Graphite's on a
    /// dark theme, Paper's on a light one. A theme overrides any of them in
    /// `tokens`.
    static let constants: [(PaletteRole, dark: String, light: String)] = [
        (.usageClaude, "#d97757", "#c2613f"),
        (.usageCodex, "#8e9db5", "#5b6b82"),
        (.usageOpenCode, "#6fc2ab", "#3d8b78"),
        (.usageMuse, "#b49bdb", "#7556a8"),
        // Pull request states, as GitHub colours them.
        (.pullRequestOpen, "#238636", "#1f883d"),
        (.pullRequestDraft, "#6e7681", "#6e7781"),
        (.pullRequestMerged, "#8957e5", "#8250df"),
        (.pullRequestClosed, "#da3633", "#cf222e"),
        (.pullRequestOpenInk, "#6bc98a", "#1a7f37"),
        (.pullRequestDraftInk, "#a0a8b2", "#59636e"),
        (.pullRequestMergedInk, "#b79cf0", "#7a48c9"),
        (.pullRequestClosedInk, "#f08a84", "#c0262e"),
        // One Dark on a dark theme, One Light on a light one, as Paseo colours code.
        (.syntaxKeyword, "#c678dd", "#a626a4"),
        (.syntaxString, "#98c379", "#50a14f"),
        (.syntaxLiteral, "#d19a66", "#986801"),
        (.syntaxType, "#e5c07b", "#c18401"),
        (.syntaxFunction, "#61afef", "#4078f2"),
        (.syntaxComment, "#5c6370", "#a0a1a7"),
        (.syntaxOperator, "#56b6c2", "#0184bc"),
        (.syntaxTag, "#e06c75", "#e45649"),
        (.syntaxPlain, "#abb2bf", "#383a42"),
        (.added, "#4cc38a", "#1a7f37"),
        (.removed, "#ef6461", "#cf222e"),
        (.addedWash, "#4cc38a1a", "#1a7f3712"),
        (.removedWash, "#ef64611a", "#cf222e0f"),
        // Find's yellow, the one place it's used, because that's how a Mac shows it.
        (.findCurrent, "#e2c0448c", "#f5d547cc"),
        // On a dark theme bright enough to read on dark gray; on a light one
        // deep enough to read on white (so "yellow" is amber, "white" a gray,
        // and bold's bright set deeper, not lighter).
        (.terminalBlack, "#3e3e46", "#1d1d1f"),
        (.terminalRed, "#ef6461", "#cf222e"),
        (.terminalGreen, "#4cc38a", "#1a7f37"),
        (.terminalYellow, "#e5a33a", "#9a6700"),
        (.terminalBlue, "#5b9cf6", "#0969da"),
        (.terminalMagenta, "#c080e8", "#8250df"),
        (.terminalCyan, "#4ebfc7", "#1b7c83"),
        (.terminalWhite, "#c8c8ce", "#6e6e78"),
        (.terminalBrightBlack, "#74747e", "#8e8e98"),
        (.terminalBrightRed, "#ff8a86", "#b31d28"),
        (.terminalBrightGreen, "#72dba6", "#116329"),
        (.terminalBrightYellow, "#f5c26b", "#7d4e00"),
        (.terminalBrightBlue, "#88b9ff", "#0550ae"),
        (.terminalBrightMagenta, "#d8a8f8", "#6e40c9"),
        (.terminalBrightCyan, "#7dd8de", "#136a73"),
        (.terminalBrightWhite, "#f4f4f6", "#7a7a84"),
    ]

    /// The colours a theme starts from when its plugin can't be read:
    /// nothing is drawn unpainted.
    static func fallback(_ appearance: ThemeAppearance) -> ThemeContribution {
        let colors = appearance.isDark
            ? ThemeContribution.Colors(background: "#1e1e21", foreground: "#ececef", raised: "#252529", control: "#303036",
                                       border: "#ffffff13", mutedForeground: "#a4a4ad", ring: "#75757e")
            : ThemeContribution.Colors(background: "#ffffff", foreground: "#1d1d1f", raised: "#f6f6f8", control: "#efeff2",
                                       border: "#00000014", mutedForeground: "#5c5c66", ring: "#8c8c96")
        return ThemeContribution(id: appearance.rawValue, name: appearance.isDark ? "Dark" : "Light",
                                 appearance: appearance, colors: colors)
    }
}
