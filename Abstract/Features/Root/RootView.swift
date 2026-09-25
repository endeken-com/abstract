import SwiftUI
import AbstractCore

/// The window: a flush sidebar, a hairline, and the detail. No floating
/// sidebar panel. The sidebar's colour runs up under the traffic lights; the
/// native title is pushed to the detail column's edge, so titles, the
/// sidebar toggle and the lights share one line.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("sidebar.width") private var sidebarWidth: Double = 256
    @AppStorage("sidebar.hidden") private var sidebarHidden = false
    // Settings › Appearance › Fonts: the window redraws when one changes.
    @AppStorage(UIFontChoice.familyKey) private var uiFamily = UIFontChoice.defaults.family
    @AppStorage(UIFontChoice.sizeKey) private var uiSize = UIFontChoice.defaults.size
    @AppStorage(UIFontChoice.weightKey) private var uiWeight = UIFontChoice.defaults.weight
    @AppStorage(EditorFontChoice.familyKey) private var editorFamily = EditorFontChoice.defaults.family
    @AppStorage(EditorFontChoice.sizeKey) private var editorSize = EditorFontChoice.defaults.size
    @AppStorage(EditorFontChoice.weightKey) private var editorWeight = EditorFontChoice.defaults.weight
    @AppStorage(EditorFontChoice.ligaturesKey) private var ligatures = EditorFontChoice.defaults.ligatures
    @AppStorage(EditorFontChoice.lineHeightKey) private var lineHeight = EditorFontChoice.defaults.lineHeight

    /// Fonts are read where text is drawn, not observed, so a new choice
    /// rebuilds the window's views; Settings stays as it is over them.
    private var fonts: String {
        BTFont.uiChoice = UIFontChoice.stored
        return "\(uiFamily)|\(uiSize)|\(uiWeight.rawValue)|\(editorFamily)|\(editorSize)|\(editorWeight.rawValue)|\(ligatures)|\(lineHeight)"
    }

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            if !sidebarHidden {
                SidebarView()
                    .frame(width: sidebarWidth)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(Color.btSidebar.ignoresSafeArea())
                    .transition(.move(edge: .leading).combined(with: .opacity))
                SidebarEdge(width: $sidebarWidth)
            }
            DetailView()
                .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.btCanvas)
        }
        .frame(minHeight: 480)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbar(removing: .title)
        // The window's one toolbar. Every screen shares it, so its items never
        // change set and the sidebar toggle never moves when you switch.
        .toolbar {
            PlainToolbarItem(placement: .navigation) {
                TitlebarLeading(sidebarHidden: $sidebarHidden, sidebarWidth: sidebarWidth)
            }
            if #available(macOS 26, *) { ToolbarSpacer(.flexible) }
            PlainToolbarItem(placement: .automatic) { DetailToolbarControls() }
        }
        .id(fonts)
        .overlay {
            if model.isPaletteOpen {
                CommandPalette()
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .overlay {
            if model.isSettingsOpen {
                SettingsView()
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .overlay(alignment: .bottom) { ToastView() }
        .animation(.snappy(duration: 0.18), value: model.isPaletteOpen)
        .animation(.snappy(duration: 0.18), value: model.isSettingsOpen)
        .sheet(isPresented: Binding(get: { model.newChatProjectId != nil }, set: { if !$0 { model.newChatProjectId = nil } })) {
            NewChatSheet(initialProjectId: model.newChatProjectId ?? nil, standalone: model.newChatStandalone)
        }
        .sheet(isPresented: $model.isAddingProject) { AddProjectSheet() }
        .confirmationDialog("Archive “\(model.requestArchive.flatMap(model.chatName) ?? "")”?",
                            isPresented: Binding(get: { model.requestArchive != nil }, set: { if !$0 { model.requestArchive = nil } }),
                            titleVisibility: .visible) {
            Button("Archive", role: .destructive) {
                if let id = model.requestArchive {
                    if model.isAlive(id) { model.stop(id) }
                    model.setArchived(id, true)
                }
                model.requestArchive = nil
            }
            Button("Cancel", role: .cancel) { model.requestArchive = nil }
        } message: {
            Text("Its agent stops and it moves to Archived. The worktree and branch stay, so you can bring it back.")
        }
        .sheet(item: Binding(get: { model.remote.prompt }, set: { if $0 == nil { model.remote.dismissPrompt() } })) {
            PairingSheet(prompt: $0)
        }
        // Whether the Revund CLI is here, for the Review pane's button.
        .task { await RevundService.shared.refreshStatus(model.executor) }
    }
}

struct DetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        content
            .navigationTitle(title)
    }

    private var title: String {
        switch model.destination {
        case .home: ""
        case .session(let id): model.chatName(id) ?? ""
        case .automations: "Automations"
        case .worktrees: "Worktrees"
        case .pullRequests: "Pull Requests"
        case .projectSettings(let id): model.project(id)?.name ?? ""
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.destination {
        case .home:
            HomeView()
        case .session(let id):
            // A chat on another Mac is the same chat here: its work happens there.
            if id.hasPrefix(RemoteService.mirrorPrefix), model.chatName(id) == nil {
                RemoteChatView(sessionId: id).id(id)
            } else if model.chatName(id) != nil {
                ChatView(sessionId: id).id(id)
            } else {
                EmptyStateView(symbol: "bubble.left.and.exclamationmark.bubble.right", title: "This chat no longer exists")
            }
        case .automations:
            AutomationsView()
        case .worktrees:
            WorktreesView()
        case .pullRequests:
            PullRequestsView()
        case .projectSettings(let id):
            ProjectSettingsView(projectId: id).id(id)
        }
    }
}

struct ToastView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            if let toast = model.toast {
                HStack(spacing: Space.sm) {
                    Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(toast.isError ? Color.btRemoved : Color.btAdded)
                    Text(toast.message).font(.btBody).foregroundStyle(Color.btText).lineLimit(2)
                }
                .padding(.horizontal, Space.lg)
                .padding(.vertical, 10)
                .btRaised(radius: 12)
                .padding(.bottom, Space.xl)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(toast.id)
            }
        }
        .animation(.spring(duration: 0.35, bounce: 0.2), value: model.toast)
    }
}

/// The sidebar toggle beside the traffic lights, then the title, which
/// starts where the detail column does. Abstract draws the title itself so
/// it can stay small and carry where the chat runs. The room before it is
/// computed, never measured: measuring the item and resizing it from that
/// made AppKit loop on layout and crash.
private struct TitlebarLeading: View {
    @Environment(AppModel.self) private var model
    @Binding var sidebarHidden: Bool
    let sidebarWidth: Double

    var body: some View {
        HStack(spacing: 0) {
            Button { withAnimation(.snappy(duration: 0.22)) { sidebarHidden.toggle() } } label: {
                RegionGlyph(region: .sidebar, open: !sidebarHidden)
            }
            .buttonStyle(ChromeIconStyle())
            .help(sidebarHidden ? "Show sidebar (⌃⌘S)" : "Hide sidebar (⌃⌘S)")
            .keyboardShortcut("s", modifiers: [.control, .command])
            if case .session(let id) = model.destination, let session = model.session(id) {
                // A chat's title band holds the main pane's tabs, starting at its edge.
                Color.clear.frame(width: tabsRoom, height: 1)
                MainTabBar(session: session, inTitleBand: true)
                    .frame(width: tabsWidth(session), height: Chrome.button + 4)
            } else {
                Color.clear.frame(width: room, height: 1)
                WindowTitle()
            }
        }
    }

    /// Where the main pane starts, less the toolbar item's own offset.
    private var tabsRoom: CGFloat {
        let detail = sidebarHidden ? 0 : sidebarWidth + 1
        return max(Space.xs, (detail + Space.sm - Chrome.leadingItemOrigin - Chrome.button).rounded())
    }

    /// From there to the side panel's edge, or to the chat buttons when it's closed.
    private func tabsWidth(_ session: Session) -> CGFloat {
        let detail = sidebarHidden ? 0 : sidebarWidth + 1
        let start = Chrome.leadingItemOrigin + Chrome.button + tabsRoom
        let sideOpen = model.layout(for: session.id).side.isOpen
        let canRun = Project.nonBlank(model.project(session.projectId)?.runScript) != nil && session.worktreePath != nil
        let buttons = CGFloat(canRun ? 4 : 3) * (Chrome.button + Chrome.gap) + 26
        let end = detail + model.mainColumnWidth - (sideOpen ? Space.sm : buttons)
        return max(160, (end - start).rounded(.down))
    }

    private var room: CGFloat {
        guard !sidebarHidden else { return Space.md }
        return max(Space.md, (sidebarWidth + Space.lg - Chrome.leadingItemOrigin - Chrome.button).rounded())
    }
}

/// The detail's title, small; a chat's title band holds its tabs instead.
private struct WindowTitle: View {
    @Environment(AppModel.self) private var model
    /// An open automation page shows its own breadcrumb; the band then stays quiet.
    @AppStorage("automations.open") private var openAutomation = ""

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
        }
        .font(BTFont.ui(12.5, .medium))
        .foregroundStyle(Color.btText)
        .lineLimit(1)
        .frame(maxWidth: 520, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var title: String {
        switch model.destination {
        case .automations: openAutomation.isEmpty ? "Automations" : ""
        case .worktrees: "Worktrees"
        case .pullRequests: "Pull Requests"
        case .projectSettings(let id): model.project(id)?.name ?? ""
        default: ""
        }
    }
}

/// The sidebar's right edge: a hairline you can drag.
private struct SidebarEdge: View {
    @Binding var width: Double
    @State private var start: Double?
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(hovering || start != nil ? Color.btBorderStrong : Color.btBorder)
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .pointerStyle(.columnResize)
                    .onHover { hovering = $0 }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let base = start ?? width
                                start = base
                                width = min(max(base + value.translation.width, 200), 380)
                            }
                            .onEnded { _ in start = nil }
                    )
            }
            .ignoresSafeArea()
    }
}


/// The trailing buttons for whatever the detail shows.
private struct DetailToolbarControls: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.destination {
        case .session(let id):
            if let session = model.session(id) {
                ChatToolbarControls(session: session)
            } else {
                Color.clear.frame(width: 1, height: Chrome.button)
            }
        case .automations:
            Button { model.newAutomationRequest += 1 } label: { Image(systemName: "plus") }
                .buttonStyle(ChromeIconStyle())
                .help("New automation")
        default:
            // Holds the item's place so the toolbar keeps the same shape.
            Color.clear.frame(width: 1, height: Chrome.button)
        }
    }
}
