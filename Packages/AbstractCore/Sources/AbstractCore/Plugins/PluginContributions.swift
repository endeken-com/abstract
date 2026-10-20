import Foundation

/// One place a usable plugin currently appears, resolved for the host's
/// menus, palette, panels, Home and Settings (ABS-96). Only plugins that
/// can run resolve, so turning one off removes it from every place at once.
public struct ResolvedPluginContribution: Sendable, Hashable, Identifiable {
    public var pluginId: String
    public var pluginName: String
    public var place: PluginPlace
    public var contribution: PluginManifest.Contribution

    public var id: String { "\(pluginId):\(place.rawValue):\(contribution.id)" }

    public init(pluginId: String, pluginName: String, place: PluginPlace,
                contribution: PluginManifest.Contribution) {
        self.pluginId = pluginId; self.pluginName = pluginName
        self.place = place; self.contribution = contribution
    }
}

public enum PluginContributions {
    /// Every contribution of every usable plugin, in manifest order.
    public static func resolve(_ plugins: [InstalledPlugin]) -> [ResolvedPluginContribution] {
        plugins.filter(\.isUsable).flatMap { plugin -> [ResolvedPluginContribution] in
            guard let manifest = plugin.manifest else { return [] }
            let contributes = manifest.contributes
            var out = contributes.views.map {
                ResolvedPluginContribution(pluginId: manifest.id, pluginName: manifest.name, place: .main,
                                           contribution: .init(id: $0.id, title: $0.title, symbol: $0.symbol))
            }
            let places: [(PluginPlace, [PluginManifest.Contribution])] = [
                (.chatPanel, contributes.chatPanelTabs), (.chatMenu, contributes.chatMenuItems),
                (.palette, contributes.paletteCommands),
                (.settings, contributes.settingsPage.map { [$0] } ?? []), (.home, contributes.homeWidgets),
                (.review, contributes.reviewActions),
            ]
            for (place, items) in places {
                out += items.map {
                    ResolvedPluginContribution(pluginId: manifest.id, pluginName: manifest.name,
                                               place: place, contribution: $0)
                }
            }
            return out
        }
    }

    public static func resolve(_ plugins: [InstalledPlugin], place: PluginPlace) -> [ResolvedPluginContribution] {
        resolve(plugins).filter { $0.place == place }
    }

    // MARK: The chat side-panel tab

    /// A plugin tab's steady pane id, so a chat keeps one tab per plugin
    /// contribution and disabling the plugin can find them all.
    public static func paneItemId(pluginId: String, contributionId: String) -> String {
        "plugin-tab:\(pluginId):\(contributionId)"
    }

    public static func paneItemId(for resolved: ResolvedPluginContribution) -> String {
        paneItemId(pluginId: resolved.pluginId, contributionId: resolved.contribution.id)
    }

    public static func parsePaneItemId(_ id: String) -> (pluginId: String, contributionId: String)? {
        let parts = id.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0] == "plugin-tab", !parts[1].isEmpty, !parts[2].isEmpty else { return nil }
        return (parts[1], parts[2])
    }
}
