import Foundation

/// The themes Abstract can draw in (ABS-185): every theme of every usable
/// plugin, which Settings → Appearance lists, and the bundled ones read
/// straight from the app, so a theme that's missing (its plugin off or
/// removed, or not loaded yet) falls back to Graphite or Paper, never to
/// nothing.
public struct ThemeCatalog: Sendable, Hashable {
    public static let graphiteId = Theme.id(pluginId: "sh.abstract.theme.graphite", themeId: "graphite")
    public static let paperId = Theme.id(pluginId: "sh.abstract.theme.paper", themeId: "paper")
    public static let inkId = Theme.id(pluginId: "sh.abstract.theme.ink", themeId: "ink")
    /// The bundled theme plugins, on by default.
    public static let bundledPluginIds: Set<String> = ["sh.abstract.theme.graphite", "sh.abstract.theme.paper",
                                                        "sh.abstract.theme.ink"]
    static let bundledOrder = [graphiteId, paperId, inkId]

    /// What Settings → Appearance and ⌘K offer: bundled first, then by name.
    public let listed: [Theme]
    /// Looked up when a theme isn't listed.
    public let fallbacks: [Theme]

    public init(listed: [Theme], fallbacks: [Theme] = []) {
        var seen = Set<String>()
        self.listed = listed.filter { seen.insert($0.id).inserted }.sorted(by: Self.order)
        self.fallbacks = fallbacks
    }

    /// The themes of the plugins that can run.
    public static func themes(of plugins: [InstalledPlugin]) -> [Theme] {
        plugins.filter(\.isUsable).flatMap { plugin -> [Theme] in
            guard let manifest = plugin.manifest else { return [] }
            return manifest.contributes.themes.map { Theme(pluginId: manifest.id, contribution: $0) }
        }
    }

    /// The themes in plugin folders, read as data: the app's bundled theme
    /// plugins, before any plugin is installed.
    public static func themes(inFolders folders: [URL]) -> [Theme] {
        folders.flatMap { folder -> [Theme] in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
                  let manifest = try? PluginManifest.decode(data), (try? manifest.validate()) != nil else { return [] }
            return manifest.contributes.themes.map { Theme(pluginId: manifest.id, contribution: $0) }
        }
    }

    /// A theme by id: listed, else bundled, else the standard theme of
    /// `appearance` (or of the id's own side, when it names a bundled one).
    public func theme(_ id: String, appearance: ThemeAppearance? = nil) -> Theme {
        if let theme = listed.first(where: { $0.id == id }) ?? fallbacks.first(where: { $0.id == id }) { return theme }
        let side = appearance ?? (id == Self.paperId ? .light : .dark)
        return standard(side)
    }

    /// Graphite for dark, Paper for light, wherever they can be found.
    public func standard(_ appearance: ThemeAppearance) -> Theme {
        let id = appearance.isDark ? Self.graphiteId : Self.paperId
        let all = listed + fallbacks
        return all.first { $0.id == id } ?? all.first { $0.appearance == appearance }
            ?? Theme(pluginId: "sh.abstract.theme", contribution: ThemeDerivation.fallback(appearance))
    }

    public func listed(_ appearance: ThemeAppearance) -> [Theme] { listed.filter { $0.appearance == appearance } }

    static func order(_ a: Theme, _ b: Theme) -> Bool {
        let ia = bundledOrder.firstIndex(of: a.id) ?? bundledOrder.count
        let ib = bundledOrder.firstIndex(of: b.id) ?? bundledOrder.count
        if ia != ib { return ia < ib }
        let byName = a.name.localizedCaseInsensitiveCompare(b.name)
        return byName == .orderedSame ? a.id < b.id : byName == .orderedAscending
    }
}
