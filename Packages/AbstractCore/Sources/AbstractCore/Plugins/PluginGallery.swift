import Foundation

/// One result in Settings → Plugins. The catalog may be unavailable, so
/// installed and bundled packages are always included independently of it.
public struct PluginGalleryItem: Identifiable, Sendable {
    public enum Category: String, CaseIterable, Sendable {
        case providers = "Providers"
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
    /// Its listing in the reviewed registry (ABS-190).
    public let listing: PluginRegistry.Entry?
    /// For a plugin from a repository: whether a person reviewed exactly
    /// this commit. Nil for the app's own and folder installs.
    public let reviewed: Bool?

    /// "Reviewed" or "Not reviewed", for plugins from a repository.
    public var reviewText: String? {
        reviewed.map { $0 ? "Reviewed" : "Not reviewed" }
    }

    /// The same state wording in gallery cards and plugin details.
    public var statusText: String {
        switch state {
        case .available: "Available"
        case .installed: "On"
        case .disabled: "Off"
        case .updateAvailable: "Update available"
        case .needsReview: "Needs review"
        case .problem: "Needs attention"
        }
    }

    /// `gitUpdates`: plugins installed from a repository whose ref moved
    /// on, found by Check for updates; `registry`: the reviewed listings,
    /// listed beside the catalog (ABS-190).
    public static func items(installed: [InstalledPlugin], bundled: [PluginManifest],
                             catalog: [PluginCatalog.Entry], registry: PluginRegistry? = nil,
                             gitUpdates: Set<String> = []) -> [Self] {
        let installedByID = Dictionary(uniqueKeysWithValues: installed.map { ($0.id, $0) })
        let bundledByID = Dictionary(uniqueKeysWithValues: bundled.map { ($0.id, $0) })
        let catalogByID = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) })
        let listings = Dictionary((registry?.plugins ?? []).map { ($0.pluginId, $0) }, uniquingKeysWith: { first, _ in first })
        let ids = Set(installedByID.keys).union(bundledByID.keys).union(catalogByID.keys).union(listings.keys)
        return ids.map { id in
            let plugin = installedByID[id]
            let manifest = plugin?.manifest ?? bundledByID[id]
            let entry = catalogByID[id]
            let listing = listings[id]
            let source = plugin?.record.source
                ?? (bundledByID[id] != nil ? .bundled : entry != nil ? .catalog : listing.map { .git($0.source) } ?? .catalog)
            let version = plugin?.record.version ?? manifest?.version ?? entry?.version ?? ""
            let state: State
            if let plugin {
                if plugin.problem != nil {
                    state = plugin.manifest != nil && plugin.record.source != .catalog ? .needsReview : .problem
                }
                else if gitUpdates.contains(id) { state = .updateAvailable }
                // A listing's install follows its approved commit.
                else if let installed = plugin.record.source.git, installed.listing != nil, let listing,
                        installed.listing == listing.id, installed.commit != listing.commit {
                    state = .updateAvailable
                }
                else if plugin.record.source.git == nil, let entry,
                        entry.version != plugin.record.version || entry.hash != plugin.record.packageHash {
                    state = .updateAvailable
                } else if !plugin.record.enabled { state = .disabled }
                else { state = .installed }
            } else { state = .available }
            return Self(id: id, name: plugin?.record.name ?? manifest?.name ?? entry?.name ?? listing?.name ?? id,
                        summary: manifest?.description?.trimmingCharacters(in: .whitespacesAndNewlines)
                            .nonEmpty ?? listing?.description.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                            ?? "See what this plugin adds to Abstract.",
                        version: version, source: source,
                        publisher: plugin?.publisher,
                        symbol: manifest?.view?.symbolOrFallback ?? PluginManifest.fallbackSymbol,
                        category: category(for: manifest), state: state, installed: plugin,
                        catalogEntry: entry, listing: listing,
                        reviewed: source.git.map { (registry ?? PluginRegistry(plugins: [])).isReviewed($0) })
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func filter(_ items: [Self], query: String, view: ViewFilter,
                              category: Category?) -> [Self] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter { item in
            (view == .all || (view == .installed && item.installed != nil)
                || (view == .updates && item.state == .updateAvailable || item.state == .needsReview))
                && (category == nil || item.category == category)
                && (query.isEmpty || [item.name, item.summary, item.source.plainWords, item.reviewText ?? "",
                                      item.category.rawValue].contains { $0.localizedCaseInsensitiveContains(query) })
        }
    }

    public enum ViewFilter: String, CaseIterable, Sendable {
        case all = "All", installed = "Installed", updates = "Updates"
    }

    private static func category(for manifest: PluginManifest?) -> Category {
        guard let manifest else { return .other }
        let adds = manifest.contributes
        if !adds.agents.isEmpty { return .providers }
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
