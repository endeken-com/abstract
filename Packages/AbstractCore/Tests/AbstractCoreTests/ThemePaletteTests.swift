import Foundation
import Testing
@testable import AbstractCore

@Suite struct ThemePaletteTests {
    /// The background a foreground sits on, made opaque.
    private func surfaces(in theme: Theme) -> [(PaletteRole, Swatch)] {
        let canvas = PaletteRole.canvas.swatch(in: theme)
        return PaletteRole.backgrounds.map { ($0, $0.swatch(in: theme).over(canvas)) }
    }

    @Test func contrastMatchesWCAG() {
        #expect(abs(Swatch(0x000000).contrast(on: Swatch(0xFFFFFF)) - 21) < 0.01)
        #expect(abs(Swatch(0x777777).contrast(on: Swatch(0xFFFFFF)) - 4.48) < 0.01)
        #expect(Swatch(0xFFFFFF).contrast(on: Swatch(0xFFFFFF)) == 1)
        #expect(Swatch(0xFFFFFF, alpha: 0).contrast(on: Swatch(0x000000)) == 1, "a clear colour is the background")
    }

    @Test func hexColoursReadAsPaseoWritesThem() {
        #expect(Swatch(css: "#1e1e21") == Swatch(0x1E1E21))
        #expect(Swatch(css: "#FFF") == Swatch(0xFFFFFF))
        #expect(Swatch(css: "#ffffff13") == Swatch(0xFFFFFF, alpha: 19.0 / 255))
        #expect(Swatch(css: "#ffffff13")?.css == "#ffffff13")
        for bad in ["1e1e21", "#12345", "#gggggg", "red", "#1234", ""] {
            #expect(Swatch(css: bad) == nil, "\(bad)")
        }
    }

    // MARK: The bundled themes are today's colours

    /// Every role of Graphite, Paper and Ink, as the Swift table held them
    /// before they became theme plugins (and the terminal's own table).
    @Test func bundledThemesKeepEveryColourTheyHad() throws {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/theme-palettes-before-plugins", withExtension: "json"))
        let before = try JSONDecoder().decode([String: [String: String]].self, from: Data(contentsOf: url))
        let cases: [(String, Theme, Bool)] = [("graphite", .graphite, false), ("paper", .paper, false),
                                              ("ink", .ink, false), ("paperStrong", .paper, true)]
        for (name, theme, strong) in cases {
            let expected = try #require(before[name])
            #expect(expected.count == PaletteRole.allCases.count, "\(name)")
            for role in PaletteRole.allCases {
                #expect(role.swatch(in: theme, strongerBorders: strong).css == expected[role.rawValue], "\(name) \(role)")
            }
        }
    }

    @Test func bundledThemesAreNamedAndSided() {
        #expect(BundledThemes.all.map(\.name) == ["Graphite", "Paper", "Ink"])
        #expect(BundledThemes.all.map(\.appearance) == [.dark, .light, .dark])
        #expect(BundledThemes.all.map(\.id) == [ThemeCatalog.graphiteId, ThemeCatalog.paperId, ThemeCatalog.inkId])
        #expect(Theme.graphite.shortId == "graphite")
    }

    // MARK: Ink (ABS-68)

    /// Ink's reading test: text and prose at 7:1, every other foreground at
    /// 4.5:1, on every surface; text on every wash; text on the accent.
    private func passesInksReadingTest(_ theme: Theme, onAccent floor: Double = 7) {
        for (background, surface) in surfaces(in: theme) {
            for role in PaletteRole.foregrounds {
                let ratio = role.swatch(in: theme).contrast(on: surface)
                let floor = role == .text || role == .prose ? 7.0 : 4.5
                #expect(ratio >= floor, "\(theme.name) \(role) on \(background): \(String(format: "%.2f", ratio)):1")
            }
        }
        let canvas = PaletteRole.canvas.swatch(in: theme)
        for wash in [PaletteRole.selection, .hover, .addedWash, .removedWash, .findMatch, .findCurrent] {
            let under = wash.swatch(in: theme).over(canvas)
            #expect(PaletteRole.text.swatch(in: theme).contrast(on: under) >= 4.5, "\(theme.name) text on \(wash)")
        }
        let accent = PaletteRole.accent.swatch(in: theme)
        #expect(PaletteRole.onAccent.swatch(in: theme).contrast(on: accent) >= floor, "\(theme.name) on its accent")
    }

    @Test func inkTextReadsOnEverySurfaceAndWash() { passesInksReadingTest(.ink) }

    @Test func inkSyntaxReadsAtSevenToOneOnBlack() {
        let black = PaletteRole.code.swatch(in: .ink)
        #expect(black == Swatch(0x000000))
        for role in PaletteRole.allCases where role.rawValue.hasPrefix("syntax") {
            #expect(role.swatch(in: .ink).contrast(on: black) >= 7, "\(role)")
        }
    }

    @Test func inkIsTrueBlackWithVisibleBorders() {
        for role in [PaletteRole.canvas, .sidebar, .code] {
            #expect(role.swatch(in: .ink) == Swatch(0x000000), "\(role)")
        }
        let black = Swatch(0x000000)
        let surfaces = [PaletteRole.surface, .surfaceRaised, .inset].map { $0.swatch(in: .ink).luminance }
        #expect(surfaces == surfaces.sorted(), "surfaces step up, back to front")
        // Borders are what separates Ink's surfaces, so they must show.
        #expect(PaletteRole.border.swatch(in: .ink).contrast(on: black) >= 2)
        #expect(PaletteRole.borderStrong.swatch(in: .ink).contrast(on: black) >= 3)
        #expect(PaletteRole.fieldBorderFocused.swatch(in: .ink).contrast(on: black)
                > PaletteRole.fieldBorder.swatch(in: .ink).contrast(on: black))
    }

    @Test func findMatchesAreToldApart() {
        let canvas = PaletteRole.canvas.swatch(in: .ink)
        let match = PaletteRole.findMatch.swatch(in: .ink).over(canvas)
        let current = PaletteRole.findCurrent.swatch(in: .ink).over(canvas)
        #expect(match != current)
        #expect(current.contrast(on: match) >= 1.3)
        #expect(PaletteRole.added.swatch(in: .ink) != PaletteRole.removed.swatch(in: .ink))
    }

    @Test func sidebarCheckResultsReadInLightAndDarkThemes() {
        for theme in BundledThemes.all {
            let sidebar = PaletteRole.sidebar.swatch(in: theme)
            for role in [PaletteRole.added, .removed, .textSecondary] {
                #expect(role.swatch(in: theme).contrast(on: sidebar) >= 4.5, "\(role) on \(theme.name) sidebar")
            }
        }
    }

    /// Graphite and Paper aren't held to Ink's bar; their ratios are reported.
    @Test func reportsGraphiteAndPaperContrast() {
        for theme in [Theme.graphite, .paper] {
            let canvas = PaletteRole.canvas.swatch(in: theme)
            let lowest = PaletteRole.foregrounds
                .map { ($0, $0.swatch(in: theme).contrast(on: canvas)) }
                .min { $0.1 < $1.1 }
            if let (role, ratio) = lowest {
                print("\(theme.name): lowest is \(role) at \(String(format: "%.2f", ratio)):1 on the canvas")
                #expect(ratio > 1)
            }
        }
    }

    // MARK: A theme with only Paseo's eight colours

    /// Paseo's own example (public-docs/plugins/reference.md) and a light one.
    static let mocha = ThemeContribution(
        id: "mocha", name: "Catppuccin Mocha", appearance: .dark,
        colors: .init(background: "#1e1e2e", foreground: "#cdd6f4", raised: "#313244", control: "#45475a",
                      border: "#45475a", accent: "#cba6f7", mutedForeground: "#a6adc8", ring: "#6c7086"))
    static let latte = ThemeContribution(
        id: "latte", name: "Catppuccin Latte", appearance: .light,
        colors: .init(background: "#eff1f5", foreground: "#4c4f69", raised: "#e6e9ef", control: "#ccd0da",
                      border: "#bcc0cc", mutedForeground: "#6c6f85", ring: "#9ca0b0"))

    @Test(arguments: [mocha, latte])
    func anEightColourThemePassesInksReadingTest(_ contribution: ThemeContribution) {
        let theme = Theme(pluginId: "sh.example.catppuccin", contribution: contribution)
        passesInksReadingTest(theme, onAccent: 4.5)
    }

    @Test(arguments: [mocha, latte])
    func everyRoleIsDerivedFromTheEightColours(_ contribution: ThemeContribution) {
        let theme = Theme(pluginId: "sh.example.catppuccin", contribution: contribution)
        let colors = contribution.colors
        for role in PaletteRole.allCases {
            let swatch = role.swatch(in: theme)
            #expect((0...1).contains(swatch.alpha) && swatch.hex <= 0xFFFFFF, "\(role)")
        }
        #expect(theme.swatch(.canvas).css == colors.background)
        #expect(theme.swatch(.surface).css == colors.raised)
        #expect(theme.swatch(.inset).css == colors.control)
        #expect(theme.swatch(.border).css == colors.border)
        #expect(theme.swatch(.fieldBorderFocused).css == colors.ring)
        #expect(theme.swatch(.onAccent).css == colors.background)
        #expect(theme.swatch(.accent).css == (colors.accent ?? colors.foreground))
        // Surfaces step the way the theme's do: the sidebar and code sit
        // behind the canvas on a dark theme.
        if contribution.appearance == .dark {
            #expect(theme.swatch(.sidebar).luminance < theme.swatch(.canvas).luminance)
            #expect(theme.swatch(.code).luminance < theme.swatch(.canvas).luminance)
        }
        // Constants are the bundled theme's of that side, unless lifted.
        let side: Theme = contribution.appearance == .dark ? .graphite : .paper
        #expect(theme.swatch(.terminalRed) == side.swatch(.terminalRed))
        #expect(theme.swatch(.pullRequestMerged) == side.swatch(.pullRequestMerged))
    }

    @Test func accentFallsBackToTheForeground() {
        var plain = Self.mocha
        plain.colors.accent = nil
        let theme = Theme(pluginId: "sh.example.p", contribution: plain)
        #expect(theme.swatch(.accent).css == plain.colors.foreground)
    }

    @Test func tokensAreTakenAsWrittenEvenWhenTheyDontRead() {
        var custom = Self.mocha
        custom.tokens = ["syntaxComment": "#313244", "canvas": "#101010"]
        let theme = Theme(pluginId: "sh.example.p", contribution: custom)
        #expect(theme.swatch(.syntaxComment).css == "#313244")
        #expect(theme.swatch(.canvas).css == "#101010")
        // Without the token, the same comment colour would have been lifted.
        let derived = Theme(pluginId: "sh.example.p", contribution: Self.mocha)
        #expect(derived.swatch(.syntaxComment).contrast(on: derived.swatch(.surface)) >= 4.5)
    }

    @Test func strongerBordersAreForLightThemesOnly() {
        let latte = Theme(pluginId: "sh.example.p", contribution: Self.latte)
        #expect(latte.swatch(.border, strongerBorders: true).alpha > 0.15)
        let mocha = Theme(pluginId: "sh.example.p", contribution: Self.mocha)
        #expect(mocha.swatch(.border, strongerBorders: true) == mocha.swatch(.border))
    }

    // MARK: Choosing a theme

    private let catalog = BundledThemes.catalog

    @Test func choiceResolvesToAThemePerAppearance() {
        let ink = ThemeChoice(.ink), graphite = ThemeChoice(.graphite), system = ThemeChoice.system
        #expect(ink.isDark(in: catalog) == true)
        #expect(system.isDark(in: catalog) == nil)
        #expect(ink.theme(dark: true, increasedContrast: false, catalog: catalog) == .ink)
        #expect(graphite.theme(dark: true, increasedContrast: true, catalog: catalog) == .graphite,
                "a theme picked by name stays put when Increase contrast is on")
        #expect(system.theme(dark: true, increasedContrast: false, catalog: catalog) == .graphite)
        #expect(system.theme(dark: true, increasedContrast: true, catalog: catalog) == .ink)
        #expect(system.theme(dark: false, increasedContrast: true, catalog: catalog) == .paper)
        // A view forced light (the settings previews) draws in the light pick whatever is picked.
        #expect(ink.theme(dark: false, increasedContrast: false, catalog: catalog) == .paper)
        #expect(ThemeChoice(.paper).resolved(systemDark: true, increasedContrast: false, catalog: catalog) == .paper)
    }

    @Test func matchSystemFollowsItsPicks() {
        let picks = ThemePicks(light: ThemeCatalog.paperId, dark: ThemeCatalog.inkId)
        #expect(ThemeChoice.system.theme(dark: true, increasedContrast: false, catalog: catalog, picks: picks) == .ink)
        let mocha = Theme(pluginId: "sh.example.catppuccin", contribution: Self.mocha)
        let more = ThemeCatalog(listed: BundledThemes.all + [mocha])
        let mine = ThemePicks(dark: mocha.id)
        #expect(ThemeChoice.system.theme(dark: true, increasedContrast: false, catalog: more, picks: mine) == mocha)
        #expect(ThemeChoice.system.theme(dark: true, increasedContrast: true, catalog: more, picks: mine) == mocha,
                "Increase contrast swaps in Ink only for the standard dark pick")
    }

    @Test func namesSavedBeforeThemePluginsStillChooseTheSameTheme() {
        #expect(ThemeChoice(rawValue: "graphite").rawValue == ThemeCatalog.graphiteId)
        #expect(ThemeChoice(rawValue: "paper").rawValue == ThemeCatalog.paperId)
        #expect(ThemeChoice(rawValue: "ink").rawValue == ThemeCatalog.inkId)
        #expect(ThemeChoice(rawValue: "system") == .system)
        #expect(ThemeChoice.default.rawValue == ThemeCatalog.graphiteId)
        #expect(ThemePicks(light: "paper", dark: "ink").dark == ThemeCatalog.inkId)
    }

    @Test func aMissingThemeFallsBackToTheStandardOneOfItsSide() {
        let empty = ThemeCatalog(listed: [], fallbacks: BundledThemes.all)
        #expect(empty.theme("sh.example.gone/theme/x") == .graphite)
        #expect(empty.theme("sh.example.gone/theme/x", appearance: .light) == .paper)
        #expect(empty.theme(ThemeCatalog.inkId) == .ink, "a bundled theme turned off is still found")
        // Nothing at all to read: a theme is still drawn.
        let nothing = ThemeCatalog(listed: [])
        #expect(nothing.theme(ThemeCatalog.paperId).appearance == .light)
        #expect(nothing.theme(ThemeCatalog.graphiteId).swatch(.canvas).css == "#1e1e21")
        let lone = ThemeCatalog(listed: [], fallbacks: [.paper])
        #expect(lone.standard(.light) == .paper)
    }

    @Test func listedThemesAreBundledFirstThenByName() {
        let mocha = Theme(pluginId: "sh.example.catppuccin", contribution: Self.mocha)
        let latte = Theme(pluginId: "sh.example.catppuccin", contribution: Self.latte)
        let catalog = ThemeCatalog(listed: [mocha, .ink, latte, .graphite, .paper, .ink])
        #expect(catalog.listed.map(\.name) == ["Graphite", "Paper", "Ink", "Catppuccin Latte", "Catppuccin Mocha"])
        #expect(catalog.listed(.light).map(\.name) == ["Paper", "Catppuccin Latte"])
    }

    @Test func lightThemesStrengthenTheirBordersOnlyUnderMatchSystem() {
        #expect(ThemeChoice.system.strongerBorders(dark: false, increasedContrast: true))
        #expect(!ThemeChoice(.paper).strongerBorders(dark: false, increasedContrast: true))
        #expect(!ThemeChoice.system.strongerBorders(dark: true, increasedContrast: true))
        let plain = PaletteRole.border.swatch(in: .paper)
        let strong = PaletteRole.border.swatch(in: .paper, strongerBorders: true)
        #expect(strong.alpha > plain.alpha)
        #expect(PaletteRole.text.swatch(in: .paper, strongerBorders: true) == PaletteRole.text.swatch(in: .paper))
    }

    // MARK: The phone

    @Test func thePhoneGetsTheThemeAsColours() throws {
        let named = RemoteTheming(choice: ThemeChoice(.ink), catalog: catalog)
        #expect(!named.followsSystem && named.light == named.dark)
        #expect(named.dark.tokens["canvas"] == "#000000")
        #expect(named.dark.tokens.count == PaletteRole.allCases.count)
        #expect(named.dark.appearance == .dark && named.dark.name == "Ink")

        let system = RemoteTheming(choice: .system, catalog: catalog, picks: .standard, increasedContrast: false)
        #expect(system.followsSystem)
        #expect(system.light.id == ThemeCatalog.paperId && system.dark.id == ThemeCatalog.graphiteId)

        let snapshot = RemoteSnapshot(projects: [], sessions: [], providers: [], alive: [], theme: system)
        let data = try JSONEncoder().encode(snapshot)
        let back = try JSONDecoder().decode(RemoteSnapshot.self, from: data)
        #expect(back.theme == system)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let theme = try #require(json["theme"] as? [String: Any])
        #expect((theme["dark"] as? [String: Any])?["appearance"] as? String == "dark")
        // An older Mac's snapshot has none.
        let old = try JSONDecoder().decode(RemoteSnapshot.self, from: Data(#"{"projects":[],"sessions":[],"providers":[],"alive":[]}"#.utf8))
        #expect(old.theme == nil)
    }
}
