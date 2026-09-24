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
        }
    }

    var symbol: String {
        switch self {
        case .chat: "text.bubble"
        case .changes: "plusminus"
        case .files: "folder"
        case .terminal: "terminal"
        case .review: PullRequestGlyph.symbol
        }
    }

    var isAvailable: Bool { true }

}

/// The content behind one tab. Register a new pane kind here.
struct PaneContent: View {
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
        }
    }
}
