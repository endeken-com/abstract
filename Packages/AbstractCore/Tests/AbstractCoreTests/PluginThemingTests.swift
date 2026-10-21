import Foundation
import JavaScriptCore
import Testing
@testable import AbstractCore

/// Plugins follow Abstract's theme from the first frame (ABS-134), and every
/// bundled plugin is drawn with the shared kit.
@Suite struct PluginThemingTests {
    var repo: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    var pluginsFolder: URL { repo.appendingPathComponent("Abstract/Resources/Plugins") }
    var kitFolder: URL { repo.appendingPathComponent("Abstract/Resources/PluginKit") }

    // MARK: The theme comes from Abstract, not the Mac

    @Test(arguments: [
        // Picked theme, Mac in Dark, Increase contrast, what a plugin gets.
        (ThemeChoice.graphite, false, false, Theme.graphite),
        (.graphite, true, false, .graphite),
        (.graphite, false, true, .graphite),
        (.ink, false, false, .ink),
        (.ink, true, true, .ink),
        (.paper, true, false, .paper),
        (.paper, true, true, .paper),
        (.system, false, false, .paper),
        (.system, true, false, .graphite),
        (.system, true, true, .ink),
    ])
    func colourVariablesFollowTheChosenTheme(choice: ThemeChoice, macDark: Bool, contrast: Bool, expected: Theme) throws {
        let appearance = PluginAppearance.resolve(choice: choice, systemDark: macDark, increasedContrast: contrast)
        #expect(appearance.theme == expected)
        #expect(appearance.colorScheme == (expected == .paper ? "light" : "dark"))
        let context = PluginContext.jsonValue(appearance: appearance, locale: "en_US", pluginId: "sh.example.p",
                                              pluginVersion: "1.0.0", capabilities: [])
        #expect(context["theme"] == .string(expected.rawValue))
        #expect(context["colorScheme"] == .string(appearance.colorScheme))
        for role in PaletteRole.allCases {
            let value = PluginContext.css(role.swatch(in: expected, strongerBorders: appearance.strongerBorders))
            #expect(context["tokens"]?[role.rawValue] == .string(value), "\(role) in \(choice)")
        }
    }

    @Test func graphiteOnALightMacIsNeverPaperWhite() {
        let appearance = PluginAppearance.resolve(choice: .graphite, systemDark: false, increasedContrast: false)
        #expect(appearance.tokens["canvas"] == "#1e1e21")
        #expect(appearance.tokens["canvas"] != PluginAppearance(theme: .paper).tokens["canvas"])
        let ink = PluginAppearance.resolve(choice: .ink, systemDark: false, increasedContrast: false)
        #expect(ink.tokens["canvas"] == "#000000")
    }

    @Test func matchSystemStrengthensPaperBordersWithIncreasedContrast() {
        let strong = PluginAppearance.resolve(choice: .system, systemDark: false, increasedContrast: true)
        #expect(strong.theme == .paper && strong.strongerBorders)
        #expect(strong.tokens["border"] == PluginContext.css(PaletteRole.border.swatch(in: .paper, strongerBorders: true)))
        #expect(!PluginAppearance.resolve(choice: .paper, systemDark: false, increasedContrast: true).strongerBorders)
    }

    // MARK: The colours are in the page before its CSS

    /// Runs the document-start script against a stand-in document and
    /// returns what it set on the root element.
    func runDocumentStart(_ appearance: PluginAppearance) throws -> (properties: [String: String], attributes: [String: String]) {
        let context = try #require(JSContext())
        context.evaluateScript("""
        var __set = {}; var __attrs = {};
        var document = { documentElement: {
          style: { setProperty: function (name, value) { __set[name] = value; } },
          setAttribute: function (name, value) { __attrs[name] = value; }
        } };
        """)
        context.evaluateScript(PluginTheming.documentStartScript(appearance))
        if let exception = context.exception { Issue.record("threw: \(exception)") }
        let properties = context.objectForKeyedSubscript("__set").toDictionary() as? [String: String] ?? [:]
        let attributes = context.objectForKeyedSubscript("__attrs").toDictionary() as? [String: String] ?? [:]
        return (properties, attributes)
    }

    @Test(arguments: Theme.allCases)
    func colourVariablesAreSetAtDocumentStart(theme: Theme) throws {
        let appearance = PluginAppearance(theme: theme)
        let (properties, attributes) = try runDocumentStart(appearance)
        for (name, value) in appearance.tokens {
            #expect(properties["--abstract-\(name)"] == value, "--abstract-\(name)")
        }
        #expect(properties["color-scheme"] == appearance.colorScheme)
        #expect(properties["background-color"] == appearance.tokens["canvas"])
        #expect(properties["--abstract-font"] == PluginTheming.fontFamily)
        #expect(attributes["data-abstract-theme"] == theme.rawValue)
    }

    @Test func theDocumentStartScriptIsTheSameCodeTheContextMessageUses() throws {
        // A theme change arrives as a `context` message; it must set the
        // same variables the first frame had.
        let source = try String(contentsOf: repo.appendingPathComponent("Abstract/Features/Plugins/PluginHostView.swift"),
                                encoding: .utf8)
        #expect(source.contains("PluginTheming.documentStartScript(appearance)"))
        #expect(source.contains("injectionTime: .atDocumentStart"))
        let shim = try String(contentsOf: repo.appendingPathComponent("Abstract/Features/Plugins/PluginConnection.swift"),
                              encoding: .utf8)
        #expect(shim.contains("const applyTheme = \\(PluginTheming.applySource);"))
        // The Mac's appearance alone no longer picks a plugin's palette.
        let model = try String(contentsOf: repo.appendingPathComponent("Abstract/App/AppModel+Plugins.swift"), encoding: .utf8)
        #expect(!model.contains("ThemeState.shared.theme(for: NSApp.effectiveAppearance)"))
        #expect(model.contains("PluginAppearance"))
    }

    // MARK: The kit

    @Test func theKitIsServedFromAReservedPath() {
        #expect(PluginKit.file(forRequestPath: "_abstract/abstract-ui.css") == "abstract-ui.css")
        #expect(PluginKit.file(forRequestPath: "_abstract/abstract-ui.js") == "abstract-ui.js")
        // Anything else under the prefix is refused, never read from the package.
        #expect(PluginKit.isKitPath("_abstract/other.css"))
        #expect(PluginKit.file(forRequestPath: "_abstract/other.css") == nil)
        #expect(PluginKit.file(forRequestPath: "_abstract/../manifest.json") == nil)
        #expect(!PluginKit.isKitPath("style.css"))
        #expect(PluginKit.file(forRequestPath: "abstract-ui.css") == nil)
        for name in PluginKit.files {
            #expect(FileManager.default.fileExists(atPath: kitFolder.appendingPathComponent(name).path), "\(name)")
        }
    }

    @Test func theKitHasEveryComponentItDocuments() throws {
        let css = try String(contentsOf: kitFolder.appendingPathComponent("abstract-ui.css"), encoding: .utf8)
        for selector in [".ab-button", ".ab-input", ".ab-search", ".ab-tabs", ".ab-tab[aria-selected=\"true\"]",
                         ".ab-segmented", ".ab-row", ".ab-row.ab-interactive:hover", ".ab-row.ab-selected",
                         ".ab-chip", ".ab-badge", ".ab-status", ".ab-card", ".ab-empty", ".ab-skeleton",
                         ".ab-notice", ".ab-popover", ":focus-visible", "prefers-reduced-motion"] {
            #expect(css.contains(selector), "abstract-ui.css lacks \(selector)")
        }
        // Colours only from the host's tokens: no theme of its own.
        for token in ["--abstract-canvas", "--abstract-text", "--abstract-surface", "--abstract-hover", "--abstract-selection"] {
            #expect(css.contains(token), "abstract-ui.css never uses \(token)")
        }
        let docs = try String(contentsOf: repo.appendingPathComponent("docs/plugins.md"), encoding: .utf8)
        #expect(docs.contains("/_abstract/abstract-ui.css"))
    }

    @Test func everyBundledPluginWithAScreenUsesTheKit() throws {
        let folders = try FileManager.default.contentsOfDirectory(at: pluginsFolder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "abstractplugin" }
        #expect(folders.count >= 7)
        for folder in folders {
            let manifest = try PluginPackage.inspect(folder: folder).manifest
            let html = try String(contentsOf: folder.appendingPathComponent(manifest.entry), encoding: .utf8)
            #expect(html.contains("href=\"/_abstract/abstract-ui.css\""), "\(manifest.id) doesn't link the kit")
            // Its own CSS uses no colour of its own: the kit's names, or the host's tokens.
            let css = (try? String(contentsOf: folder.appendingPathComponent("style.css"), encoding: .utf8)) ?? ""
            #expect(css.range(of: #"#[0-9a-fA-F]{3,8}\b"#, options: .regularExpression) == nil, "\(manifest.id) style.css has a raw colour")
        }
    }

    @Test func followPullRequestSecondOpinionAndLessonsAreChatPanelTabs() throws {
        for name in ["follow-pr", "second-opinion", "lessons"] {
            let manifest = try PluginPackage.inspect(folder: pluginsFolder.appendingPathComponent("\(name).abstractplugin")).manifest
            #expect(manifest.contributes.chatPanelTabs.count == 1, "\(name)")
            try manifest.validate()
        }
    }

    @Test func pluginsWithSeveralViewsUseTabs() throws {
        for name in ["kanban", "approvals", "follow-pr"] {
            let app = try String(contentsOf: pluginsFolder.appendingPathComponent("\(name).abstractplugin/app.js"), encoding: .utf8)
            #expect(app.contains("ui.tabs(") || app.contains("AbstractUI.tabs("), "\(name) has no tabs")
        }
    }

    /// The kit's preview (docs/plugin-kit) draws with the host's own colours.
    @Test func theKitPreviewUsesTheHostsColours() throws {
        let url = repo.appendingPathComponent("docs/plugin-kit/tokens.js")
        let themes = Dictionary(uniqueKeysWithValues: Theme.allCases.map {
            ($0.rawValue, JSONValue.object(PluginAppearance(theme: $0).jsonValue()))
        })
        let expected = "// The host's colours for each theme, from PaletteRole. PluginThemingTests checks it.\n"
            + "window.ABSTRACT_THEMES = \(JSONValue.object(themes).pretty());\n"
        let actual = try? String(contentsOf: url, encoding: .utf8)
        if actual != expected {
            let fresh = FileManager.default.temporaryDirectory.appendingPathComponent("abstract-plugin-kit-tokens.js")
            try expected.write(to: fresh, atomically: true, encoding: .utf8)
            Issue.record("docs/plugin-kit/tokens.js is out of date; the current one is at \(fresh.path)")
        }
    }
}
