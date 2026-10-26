import Foundation

/// One result in Settings → Plugins. The catalog may be unavailable, so
/// installed and bundled packages are always included independently of it.
public struct PluginGalleryItem: Identifiable, Sendable {
    public enum Category: String, CaseIterable, Sendable {
        case chats = "Chats"
        case projects = "Projects"
        case reviews = "Reviews"
        case connections = "Connections"
        case other = "Other"
    }

    public enum State: Equatable, Sendable {
        case available, installed, disabled, updateAvailable, needsReview, problem
    }

    public let id: String
    public let name: String
    public let summary: String
    public let version: String
    public let source: PluginSource
    public let publisher: String?
    public let symbol: String
    public let category: Category
    public let state: State
    public let installed: InstalledPlugin?
    public let catalogEntry: PluginCatalog.Entry?

    public static func items(installed: [InstalledPlugin], bundled: [PluginManifest],
                             catalog: [PluginCatalog.Entry]) -> [Self] {
        let installedByID = Dictionary(uniqueKeysWithValues: installed.map { ($0.id, $0) })
        let bundledByID = Dictionary(uniqueKeysWithValues: bundled.map { ($0.id, $0) })
        let catalogByID = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) })
        let ids = Set(installedByID.keys).union(bundledByID.keys).union(catalogByID.keys)
        return ids.map { id in
            let plugin = installedByID[id]
            let manifest = plugin?.manifest ?? bundledByID[id]
            let entry = catalogByID[id]
            let source = plugin?.record.source ?? (bundledByID[id] == nil ? .catalog : .bundled)
            let version = plugin?.record.version ?? manifest?.version ?? entry?.version ?? ""
            let state: State
            if let plugin {
                if plugin.problem != nil {
                    state = plugin.manifest != nil && plugin.record.source != .catalog ? .needsReview : .problem
                }
                else if let entry, entry.version != plugin.record.version || entry.hash != plugin.record.packageHash {
                    state = .updateAvailable
                } else if !plugin.record.enabled { state = .disabled }
                else { state = .installed }
            } else { state = .available }
            return Self(id: id, name: plugin?.record.name ?? manifest?.name ?? entry?.name ?? id,
                        summary: manifest?.description?.trimmingCharacters(in: .whitespacesAndNewlines)
                            .nonEmpty ?? "See what this plugin adds to Abstract.",
                        version: version, source: source,
                        publisher: plugin?.publisher,
                        symbol: manifest?.view?.symbolOrFallback ?? PluginManifest.fallbackSymbol,
                        category: category(for: manifest), state: state, installed: plugin,
                        catalogEntry: entry)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func filter(_ items: [Self], query: String, view: ViewFilter,
                              category: Category?) -> [Self] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter { item in
            (view == .all || (view == .installed && item.installed != nil)
                || (view == .updates && item.state == .updateAvailable || item.state == .needsReview))
                && (category == nil || item.category == category)
                && (query.isEmpty || [item.name, item.summary, item.source.plainWords,
                                      item.category.rawValue].contains { $0.localizedCaseInsensitiveContains(query) })
        }
    }

    public enum ViewFilter: String, CaseIterable, Sendable {
        case all = "All", installed = "Installed", updates = "Updates"
    }

    private static func category(for manifest: PluginManifest?) -> Category {
        guard let manifest else { return .other }
        let adds = manifest.contributes
        if adds.issueTracker != nil || adds.codeHost != nil { return .connections }
        if !adds.reviewActions.isEmpty || !adds.pullRequestSwitches.isEmpty { return .reviews }
        if !adds.homeWidgets.isEmpty { return .projects }
        if !adds.chatPanelTabs.isEmpty || !adds.chatMenuItems.isEmpty || !adds.paletteCommands.isEmpty
            || !manifest.agentTools.isEmpty { return .chats }
        return .other
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
