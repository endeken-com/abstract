import SwiftUI
import AbstractCore

struct ChatView: View {
    @Environment(AppModel.self) private var model
    let sessionId: String

    var body: some View {
        if let session = model.session(sessionId) {
            PanelWorkspace(session: session)
                // Arriving some other way than a tab (a notification, a search):
                // the chat gets one.
                .task(id: sessionId) { if model.activeTab?.kind.sessionId != sessionId { model.open(sessionId) } }
        }
    }

}

/// The chat's buttons in the title band: the side panel's tabs, the panel
/// toggles and More. Part of the window's one toolbar (see `RootView`), so
/// switching screens never rebuilds it.
struct ChatToolbarControls: View {
    @Environment(AppModel.self) private var model
    @AppStorage("chat.transcript") private var transcript: TranscriptMode = .normal
    let session: Session

    var body: some View {
        let layout = model.layout(for: session.id)
        let canRun = Project.nonBlank(model.project(session.projectId)?.runScript) != nil && session.worktreePath != nil
        let reserve = Chrome.sideTabsReserve + (canRun ? Chrome.button + Chrome.gap : 0)
        HStack(spacing: Chrome.gap) {
            // The side panel's tabs, on the buttons' line and starting at its edge.
            if layout.side.isOpen, let width = model.sidePanelWidth[session.id], width > reserve {
                PanelTabBar(slot: .side, session: session, inTitleBand: true)
                    .frame(width: width - reserve, height: Chrome.button, alignment: .leading)
            }
            if canRun {
                Button { model.runProjectScript(in: session.id) } label: { Image(systemName: "play") }
                    .buttonStyle(ChromeIconStyle())
                    .help("Run the project's run script")
            }
            Button { withAnimation(.snappy(duration: 0.2)) { model.togglePanel(.bottom, in: session.id) } } label: {
                RegionGlyph(region: .bottom, open: layout.bottom.isOpen)
            }
            .buttonStyle(ChromeIconStyle())
            .help(layout.bottom.isOpen ? "Hide bottom panel (⌘J)" : "Show bottom panel (⌘J)")
            Button { withAnimation(.snappy(duration: 0.2)) { model.togglePanel(.side, in: session.id) } } label: {
                RegionGlyph(region: .side, open: layout.side.isOpen)
            }
            .buttonStyle(ChromeIconStyle())
            .help(layout.side.isOpen ? "Hide side panel (⌥⌘B)" : "Show side panel (⌥⌘B)")
            ChromeIconMenu(symbol: "ellipsis", help: "More") {
                if model.isAlive(session.id) {
                    Button(model.runningBackgroundTasks(session.id) > 0 ? "Stop Agent and Its Background Tasks" : "Stop Agent") { model.stop(session.id) }
                } else {
                    Button(session.providerSessionId == nil ? "Start Agent Again" : "Resume Agent") { model.resume(session.id) }
                }
                Divider()
                if let path = session.worktreePath, !session.id.hasPrefix(RemoteService.mirrorPrefix) {
                    Button("Reveal Worktree in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                    Button("Copy Worktree Path") { copy(path) }
                }
                if let branch = session.branch { Button("Copy Branch Name (\(branch))") { copy(branch) } }
                Button("Reset Panels") { model.resetLayout(session.id) }
                Divider()
                Picker("Transcript", selection: $transcript) {
                    ForEach(TranscriptMode.allCases) { Text($0.title).tag($0) }
                }
                Picker("Output Style", selection: Binding(get: { model.outputStyle }, set: { model.outputStyle = $0 })) {
                    ForEach(OutputStyle.allCases) { Text($0.title).tag($0) }
                }
                Divider()
                Button(session.archivedAt == nil ? "Archive" : "Unarchive") { model.setArchived(session.id, session.archivedAt == nil) }
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        model.flash("Copied")
    }
}
