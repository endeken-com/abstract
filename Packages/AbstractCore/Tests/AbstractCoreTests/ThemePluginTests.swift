import Foundation
import Testing
@testable import AbstractCore

/// The theme contribution (ABS-185): Paseo's schema in a plugin manifest,
/// validated like the rest of the manifest, installed like any plugin.
@Suite struct ThemePluginTests {
    let fm = FileManager.default

    static var mocha: [String: Any] {
        ["id": "mocha", "name": "Catppuccin Mocha", "appearance": "dark",
         "colors": ["background": "#1e1e2e", "foreground": "#cdd6f4", "raised": "#313244", "control": "#45475a",
                    "border": "#45475a", "accent": "#cba6f7", "mutedForeground": "#a6adc8", "ring": "#6c7086"]]
    }

    func manifest(themes: [[String: Any]], extra: [String: Any] = [:]) -> [String: Any] {
        ["api": 2, "id": "sh.example.catppuccin", "name": "Catppuccin", "version": "1.0.0",
         "capabilities": [String](), "contributes": ["themes": themes]].merging(extra) { _, new in new }
    }

    func decode(_ object: [String: Any]) throws -> PluginManifest {
        try PluginManifest.decode(JSONSerialization.data(withJSONObject: object))
    }

    func refuses(_ object: [String: Any], _ why: String, sourceLocation: SourceLocation = #_sourceLocation) {
        do {
            let manifest = try decode(object)
            try manifest.validate()
            Issue.record("expected a refusal: \(why)", sourceLocation: sourceLocation)
        } catch let error as PluginValidationError {
            #expect(error.detail.contains(why), "\(error.detail)", sourceLocation: sourceLocation)
        } catch {
            Issue.record("unexpected error: \(error)", sourceLocation: sourceLocation)
        }
    }

    func folder(_ object: [String: Any]) throws -> URL {
        let url = fm.temporaryDirectory.appendingPathComponent("abstract-theme-plugin-\(UUID().uuidString)")
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: url.appendingPathComponent("manifest.json"))
        return url
    }

    // MARK: Manifest

    @Test func aThemeOnlyPluginNeedsNoPageScriptOrGrant() throws {
        let decoded = try decode(manifest(themes: [Self.mocha]))
        try decoded.validate()
        #expect(decoded.isThemesOnly)
        #expect(decoded.entry.isEmpty)
        #expect(decoded.grantedCapabilities.isEmpty)
        let theme = try #require(decoded.contributes.themes.first)
        #expect(theme.appearance == .dark && theme.colors.accent == "#cba6f7")
        #expect(decoded.appearanceSentences == ["Themes — Catppuccin Mocha, in Settings → Appearance."])
        // It installs: the package check doesn't look for a page.
        let inspection = try PluginPackage.inspect(folder: folder(manifest(themes: [Self.mocha])))
        #expect(inspection.manifest.contributes.themes.count == 1)
    }

    @Test func aPluginWithAScreenStillNeedsItsEntry() throws {
        var object = manifest(themes: [Self.mocha])
        object["contributes"] = ["themes": [Self.mocha], "views": [["id": "main", "title": "Main", "location": "main"]]]
        refuses(object, "missing entry")
    }

    @Test func everyColourMustBeHex() {
        for bad in ["red", "#12345", "1e1e2e", "rgb(0,0,0)", "#gggggg"] {
            var theme = Self.mocha
            var colors = theme["colors"] as! [String: Any]
            colors["background"] = bad
            theme["colors"] = colors
            refuses(manifest(themes: [theme]), "background must be a hex colour")
        }
        var short = Self.mocha
        var colors = short["colors"] as! [String: Any]
        colors["ring"] = "#abc"
        colors["border"] = "#45475a80"
        short["colors"] = colors
        #expect((try? decode(manifest(themes: [short])).validate()) != nil, "#rgb and #rrggbbaa are hex too")
    }

    @Test func unknownKeysFailTheInstall() {
        var theme = Self.mocha
        var colors = theme["colors"] as! [String: Any]
        colors["sparkle"] = "#ffffff"
        theme["colors"] = colors
        #expect(throws: PluginValidationError.self) { try decode(manifest(themes: [theme])) }
        var extraKey = Self.mocha
        extraKey["font"] = "Comic Sans"
        #expect(throws: PluginValidationError.self) { try decode(manifest(themes: [extraKey])) }
        var missing = Self.mocha
        var some = missing["colors"] as! [String: Any]
        some["ring"] = nil
        missing["colors"] = some
        #expect(throws: PluginValidationError.self) { try decode(manifest(themes: [missing])) }
        var appearance = Self.mocha
        appearance["appearance"] = "sepia"
        #expect(throws: PluginValidationError.self) { try decode(manifest(themes: [appearance])) }
    }

    @Test func tokensNameAbstractsRolesAsHex() {
        var theme = Self.mocha
        theme["tokens"] = ["syntaxKeyword": "#cba6f7", "terminalRed": "#f38ba8"]
        #expect((try? decode(manifest(themes: [theme])).validate()) != nil)
        theme["tokens"] = ["notARole": "#ffffff"]
        refuses(manifest(themes: [theme]), "unknown token notARole")
        theme["tokens"] = ["canvas": "black"]
        refuses(manifest(themes: [theme]), "canvas must be a hex colour")
    }

    @Test func namesIdsAndCountsAreChecked() {
        var long = Self.mocha
        long["name"] = String(repeating: "a", count: 61)
        refuses(manifest(themes: [long]), "at most 60 characters")
        var blank = Self.mocha
        blank["name"] = "  "
        refuses(manifest(themes: [blank]), "at most 60 characters")
        var slash = Self.mocha
        slash["id"] = "a/b"
        refuses(manifest(themes: [slash]), "needs an id")
        refuses(manifest(themes: [Self.mocha, Self.mocha]), "duplicate id in themes")
        let many = (0..<9).map { i -> [String: Any] in
            var theme = Self.mocha
            theme["id"] = "t\(i)"
            return theme
        }
        refuses(manifest(themes: many), "at most 8 themes")
    }

    @Test func aManifestWithoutThemesReadsAsBefore() throws {
        let object: [String: Any] = ["api": 1, "id": "sh.example.p", "name": "P", "version": "1.0.0", "entry": "index.html",
                                     "capabilities": [String](), "contributes": ["views": [["id": "m", "title": "M", "location": "main"]]]]
        let manifest = try decode(object)
        try manifest.validate()
        #expect(manifest.contributes.themes.isEmpty && !manifest.isThemesOnly)
        #expect(manifest.entry == "index.html")
    }

    // MARK: Installed, on and off

    @Test func anInstalledThemeIsListedOnlyWhileItsPluginIsOn() throws {
        let root = fm.temporaryDirectory.appendingPathComponent("abstract-theme-plugins-\(UUID().uuidString)")
        let manager = PluginManager(store: try Store.inMemory(), pluginsRoot: root.appendingPathComponent("Plugins"),
                                    dataRoot: root.appendingPathComponent("PluginData"))
        try manager.install(from: folder(manifest(themes: [Self.mocha])), sourceKind: .user)
        #expect(ThemeCatalog.themes(of: manager.installed()).isEmpty, "installed but not on yet")
        manager.setEnabled("sh.example.catppuccin", true)
        let themes = ThemeCatalog.themes(of: manager.installed())
        #expect(themes.map(\.id) == ["sh.example.catppuccin/theme/mocha"])
        #expect(themes.first?.name == "Catppuccin Mocha")
        let catalog = ThemeCatalog(listed: BundledThemes.all + themes)
        let mocha = catalog.theme("sh.example.catppuccin/theme/mocha")
        #expect(mocha.swatch(.canvas).css == "#1e1e2e")
        // Picked, then turned off: the window falls back to Graphite.
        manager.setEnabled("sh.example.catppuccin", false)
        let off = ThemeCatalog(listed: ThemeCatalog.themes(of: manager.installed()), fallbacks: BundledThemes.all)
        #expect(ThemeChoice(rawValue: mocha.id).resolved(systemDark: false, increasedContrast: false, catalog: off) == .graphite)
    }

    /// The sample package (Fixtures/sample-theme.abstractplugin), as a
    /// person would install it: on the Mac, and as colours for the phone.
    @Test func theSampleThemePluginInstallsAndApplies() throws {
        let sample = try #require(Bundle.module.url(forResource: "Fixtures/sample-theme.abstractplugin", withExtension: nil))
        let root = fm.temporaryDirectory.appendingPathComponent("abstract-theme-sample-\(UUID().uuidString)")
        let manager = PluginManager(store: try Store.inMemory(), pluginsRoot: root.appendingPathComponent("Plugins"),
                                    dataRoot: root.appendingPathComponent("PluginData"))
        let record = try manager.install(from: sample, sourceKind: .user)
        #expect(record.grantedCapabilities.isEmpty)
        manager.setEnabled(record.id, true)
        let catalog = ThemeCatalog(listed: BundledThemes.all + ThemeCatalog.themes(of: manager.installed()),
                                   fallbacks: BundledThemes.all)
        let choice = ThemeChoice(rawValue: "sh.example.catppuccin-mocha/theme/mocha")
        let mac = choice.resolved(systemDark: false, increasedContrast: false, catalog: catalog)
        #expect(mac.name == "Catppuccin Mocha" && mac.isDark)
        #expect(PluginAppearance.resolve(choice: choice, systemDark: false, increasedContrast: false, catalog: catalog)
            .tokens["canvas"] == "#1e1e2e")
        let phone = RemoteTheming(choice: choice, catalog: catalog)
        #expect(phone.dark.tokens["canvas"] == "#1e1e2e" && phone.dark.tokens["text"] == mac.swatch(.text).css)
        #expect(phone.dark.tokens.count == PaletteRole.allCases.count)
    }

    @Test func theBundledThemesInstallAndTurnOnByDefault() throws {
        let root = fm.temporaryDirectory.appendingPathComponent("abstract-theme-defaults-\(UUID().uuidString)")
        let manager = PluginManager(store: try Store.inMemory(), pluginsRoot: root.appendingPathComponent("Plugins"),
                                    dataRoot: root.appendingPathComponent("PluginData"))
        let bundled = PluginManager.bundledFolders(in: BundledThemes.pluginsFolder.deletingLastPathComponent())
        #expect(bundled.count >= 3)
        manager.installDefaults(from: bundled)
        let installed = manager.installed()
        for id in ThemeCatalog.bundledPluginIds {
            let plugin = try #require(installed.first { $0.id == id })
            #expect(plugin.isUsable && plugin.record.source == .bundled, "\(id)")
        }
        #expect(ThemeCatalog(listed: ThemeCatalog.themes(of: installed)).listed.map(\.name) == ["Graphite", "Paper", "Ink"])
    }

    @Test func anUpdateAddingAThemeIsReviewedAgain() throws {
        let old = try decode(manifest(themes: [Self.mocha]))
        var latte = Self.mocha
        latte["id"] = "latte"
        latte["name"] = "Catppuccin Latte"
        latte["appearance"] = "light"
        let new = try decode(manifest(themes: [Self.mocha, latte]))
        let record = PluginRecord(id: old.id, name: old.name, version: old.version, source: .user, packageHash: "x")
        #expect(PluginGrantChanges(new: new, old: record, previous: old).asksForMore)
        #expect(!PluginGrantChanges(new: old, old: record, previous: old).asksForMore)
    }
}
