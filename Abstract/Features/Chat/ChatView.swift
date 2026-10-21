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
    @State private var showingLaunch = false
    let session: Session
    var showsTabs = true

    var body: some View {
        let layout = model.layout(for: session.id)
        let canRun = Project.nonBlank(model.project(session.projectId)?.runScript) != nil && session.worktreePath != nil
        let reserve = Chrome.sideTabsReserve + (canRun ? Chrome.button + Chrome.gap : 0)
        HStack(spacing: Chrome.gap) {
            // The side panel's tabs, on the buttons' line and starting at its edge.
            if showsTabs, layout.side.isOpen, let width = model.sidePanelWidth[session.id], width > reserve {
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
                if let setup = model.setups[session.id] {
                    if setup.failure == nil { Button("Stop Setup") { model.stop(session.id) } } else { Button("Set Up Again") { model.resume(session.id) } }
                } else if model.isAlive(session.id) {
                    Button(model.runningBackgroundTasks(session.id) > 0 ? "Stop Agent and Its Background Tasks" : "Stop Agent") { model.stopAgent(session.id) }
                } else {
                    Button(session.providerSessionId == nil ? "Start Agent Again" : "Resume Agent") { model.resume(session.id) }
                }
                Divider()
                if let path = session.worktreePath, !session.id.hasPrefix(RemoteService.mirrorPrefix) {
                    let kind = session.projectId == nil ? "Folder" : "Worktree"
                    Button("Reveal \(kind) in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                    Button("Copy \(kind) Path") { copy(path) }
                }
                if let branch = session.branch { Button("Copy Branch Name (\(branch))") { copy(branch) } }
                if latestLaunch != nil { Button("How this turn started") { showingLaunch = true } }
                Button("Reset Panels") { model.resetLayout(session.id) }
                Divider()
                Picker("Transcript", selection: $transcript) {
                    ForEach(TranscriptMode.allCases) { Text($0.title).tag($0) }
                }
                Picker("Output Style", selection: Binding(get: { model.outputStyle }, set: { model.outputStyle = $0 })) {
                    ForEach(OutputStyle.allCases) { Text($0.title).tag($0) }
                }
                if !session.id.hasPrefix(RemoteService.mirrorPrefix), !model.workflows.isEmpty || session.workflow?.isActive == true {
                    Divider()
                    if session.workflow?.isActive == true {
                        Button("Stop Workflow") { model.stopWorkflow(session.id) }
                    } else {
                        Menu("Run Workflow") {
                            ForEach(model.workflows) { workflow in
                                Button(workflow.name) { runWorkflow(workflow) }
                            }
                        }
                    }
                }
                Divider()
                Button(session.archivedAt == nil ? "Archive" : "Unarchive") { model.setArchived(session.id, session.archivedAt == nil) }
                // Items plugins add to a chat's menu (ABS-96).
                let pluginItems = model.plugins.contributions(.chatMenu)
                if !pluginItems.isEmpty {
                    Divider()
                    ForEach(pluginItems) { contribution in
                        Button(contribution.contribution.title) {
                            model.invokePlugin(contribution, chatId: session.id)
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showingLaunch) {
            if let latestLaunch { LaunchDetailsView(record: latestLaunch) }
        }
    }

    private var latestLaunch: LaunchRecord? {
        for case let .turn(_, info) in model.feed(session.id).timeline.blocks.reversed() {
            if let launch = info.launch { return launch }
        }
        return nil
    }

    /// Hand this chat to the workflow's first step, to carry on the work in it.
    private func runWorkflow(_ workflow: Workflow) {
        guard !model.turnInProgress(session.id) else {
            model.flash("Wait for this turn to end, or stop it, before starting a workflow.", isError: true)
            return
        }
        do {
            try model.startWorkflow(workflow, in: session.id, task: "Pick up the work in this chat from where it stands.")
        } catch { model.flash(error.localizedDescription, isError: true) }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        model.flash("Copied")
    }
}
