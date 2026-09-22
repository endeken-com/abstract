import SwiftUI
import BacktickCore

struct ChatView: View {
    @Environment(AppModel.self) private var model
    let sessionId: String

    var body: some View {
        @Bindable var model = model
        if let session = model.session(sessionId) {
            VStack(spacing: 0) {
                if model.chatTab == .chat {
                    ConversationView(session: session)
                    ComposerView(session: session)
                } else {
                    DiffView(sessionId: session.id)
                }
            }
            .navigationTitle(session.name)
            .navigationSubtitle(subtitle(session))
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("View", selection: $model.chatTab) {
                        Label("Chat", systemImage: "text.bubble").tag(ChatTab.chat)
                        Label("Changes", systemImage: "plusminus").tag(ChatTab.changes)
                    }
                    .pickerStyle(.segmented)
                    .labelStyle(.titleAndIcon)
                    .frame(width: 200)
                    .help("Switch between the conversation and the diff (⌘D)")
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if model.isAlive(session.id) {
                        Button { model.stop(session.id) } label: { Label("Stop", systemImage: "stop.fill") }
                            .help("Stop the agent (⌘.)")
                    } else {
                        Button { model.resume(session.id) } label: {
                            Label(session.providerSessionId == nil ? "Restart" : "Resume", systemImage: "arrow.clockwise")
                        }
                        .help(session.providerSessionId == nil ? "Start the agent again" : "Resume the agent's session")
                    }
                    Menu {
                        if let path = session.worktreePath {
                            Button("Reveal Worktree in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                            Button("Copy Worktree Path") { copy(path) }
                            Button("Open in Terminal") { openTerminal(path) }
                        }
                        if let branch = session.branch { Button("Copy Branch Name") { copy(branch) } }
                        Divider()
                        Button(session.archivedAt == nil ? "Archive" : "Unarchive") { model.setArchived(session.id, session.archivedAt == nil) }
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                    .help("More actions")
                }
            }
        }
    }

    /// Status lives in the native subtitle as plain words. A custom pill in
    /// the toolbar would sit inside the system's own glass pill.
    private func subtitle(_ s: Session) -> String {
        [s.status.label, model.project(s.projectId)?.name, s.branch].compactMap { $0 }.joined(separator: "  ·  ")
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        model.flash("Copied")
    }

    private func openTerminal(_ path: String) {
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }
}
