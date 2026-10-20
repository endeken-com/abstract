import SwiftUI
import AbstractCore

extension PaneKind {
    var title: String {
        switch self {
        case .chat: "Chat"
        case .changes: "Review"
        case .files: "Files"
        case .terminal: "Terminal"
        case .review: "Pull Request"
        case .plugin: "Plugin"
        }
    }

    var symbol: String {
        switch self {
        case .chat: "text.bubble"
        case .changes: "plusminus"
        case .files: "folder"
        case .terminal: "terminal"
        case .review: PullRequestGlyph.symbol
        case .plugin: "puzzlepiece.extension"
        }
    }

    /// Plugin tabs are added by name from the plugins that offer one, not
    /// as a bare kind.
    var isAvailable: Bool { self != .plugin }

}

/// The content behind one tab. Register a new pane kind here.
struct PaneContent: View {
    @Environment(AppModel.self) private var model
    let item: PaneItem
    let session: Session

    var body: some View {
        switch item.kind {
        case .chat:
            // The chat is the window's main area, never a tab.
            EmptyView()
        case .changes:
            DiffView(sessionId: session.id, presentation: .list)
        case .files:
            FilesPaneView(session: session, paneId: item.id)
        case .terminal:
            TerminalPaneView(session: session, paneId: item.id)
        case .review:
            PullRequestPane(session: session)
        case .plugin:
            pluginTab
        }
    }

    /// A plugin's tab beside this chat (ABS-96). Turning the plugin off
    /// removes the tab; one left behind by a removed plugin says so.
    @ViewBuilder
    private var pluginTab: some View {
        if let parsed = PluginContributions.parsePaneItemId(item.id),
           model.plugins.contributions(.chatPanel).contains(where: {
               $0.pluginId == parsed.pluginId && $0.contribution.id == parsed.contributionId
           }) {
            PluginHostView(pluginId: parsed.pluginId, viewId: parsed.contributionId,
                           placement: PluginPlacement(place: .chatPanel,
                                                      contributionId: parsed.contributionId,
                                                      chatId: session.id))
        } else {
            EmptyStateView(symbol: "puzzlepiece.extension", title: "This plugin is off",
                           message: "Turn it on in Settings → Plugins to see its tab.")
        }
    }
}
