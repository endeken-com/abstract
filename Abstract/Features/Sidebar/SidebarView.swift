import SwiftUI
import AbstractCore

/// The left rail. Projects are quiet group headers with a + for a new chat;
/// chats sit beneath them as single calm lines. Built by hand rather than
/// with a sidebar `List` so spacing and row height are exact.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool
    /// The project being dragged to a new place in the rail.
    @State private var draggingProject: String?
    @AppStorage("sidebar.projectsCollapsed") private var projectsCollapsed = false

    var body: some View {
        VStack(spacing: 0) {
            list
            // Devices stay in reach at the foot, however long the list.
            Hairline()
            RailDevicesBar()
                .padding(.horizontal, Rail.inset)
                .padding(.top, 6)
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")")
                .font(.btCaption)
                .foregroundStyle(Color.btTextTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, Rail.inset + Rail.rowPadding)
                .padding(.top, 2)
                .padding(.bottom, 8)
        }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 1) {
                    RailNavRow(title: "New", symbol: "plus", destination: .home)
                    RailNavRow(title: "Automations", symbol: "clock", destination: .automations)
                    RailNavRow(title: "Worktrees", symbol: "arrow.triangle.branch", destination: .worktrees)
                    RailNavRow(title: "Pull Requests", symbol: PullRequestGlyph.symbol, destination: .pullRequests)
                }

                RailSection(title: model.remote.identity.name, collapsed: $projectsCollapsed) {
                    Button { model.isAddingProject = true } label: { Image(systemName: "plus") }
                        .buttonStyle(RailIconStyle())
                        .help("Add project")
                }
                .contextMenu {
                    if model.sessions.contains(where: { $0.archivedAt != nil }) {
                        Button(model.showArchived ? "Hide Archived Chats" : "Show Archived Chats") {
                            model.showArchived.toggle()
                        }
                    }
                }

                if !projectsCollapsed {
                    ForEach(model.projects) { project in
                        RailProjectGroup(project: project, dragging: $draggingProject)
                    }

                    let scratch = model.sessions(in: nil)
                    if !scratch.isEmpty {
                        RailGroup(title: "Scratch") {
                            ForEach(scratch) { s in
                                RailChatRow(session: s, backgroundTasks: model.runningBackgroundTasks(s.id)).equatable()
                            }
                        }
                    }
                }

                RemoteDevicesSection()
            }
            .padding(.horizontal, Rail.inset)
            .padding(.top, 6)
            .padding(.bottom, Space.lg)
        }
        .scrollIndicators(.automatic)
        // Rows scrolling up under the traffic lights and sidebar toggle blur
        // away instead of colliding with them.
        .overlay(alignment: .top) {
            TitlebarBlur(tint: .btSidebar)
                .ignoresSafeArea(.container, edges: .top)
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { step(1) }
        .onKeyPress(.upArrow) { step(-1) }
    }

    /// Arrow keys walk the chats in the order the rail shows them.
    private func step(_ delta: Int) -> KeyPress.Result {
        let order = (projectsCollapsed ? [] : model.projects).flatMap { p in
            model.collapsedProjects.contains(p.id) ? [] : model.sessions(in: p.id).map(\.id)
        } + (projectsCollapsed ? [] : model.sessions(in: nil).map(\.id))
        var seen = Set<String>()
        let unique = order.filter { seen.insert($0).inserted }
        guard !unique.isEmpty else { return .ignored }
        let current = model.selectedSession.flatMap { s in unique.firstIndex(of: s.id) }
        let next = current.map { min(max($0 + delta, 0), unique.count - 1) } ?? (delta > 0 ? 0 : unique.count - 1)
        model.open(unique[next])
        return .handled
    }
}

/// Rail metrics in one place so every row lines up.
enum Rail {
    static let inset: CGFloat = 10
    static let rowHeight: CGFloat = 28
    static let rowPadding: CGFloat = 8
    /// Chats sit slightly in from their project's name.
    static let chatIndent: CGFloat = 6
    static let iconColumn: CGFloat = 16
    static let groupGap: CGFloat = 4
    static let radius: CGFloat = 7
}

// MARK: - Rows

private struct RailNavRow: View {
    @Environment(AppModel.self) private var model
    let title: String
    let symbol: String
    let destination: Destination
    var count = 0

    var body: some View {
        let selected = model.destination == destination
        Button {
            if destination == .home { model.startNew() } else { model.destination = destination }
        } label: {
            HStack(spacing: 8) {
                Group {
                    if symbol == PullRequestGlyph.symbol {
                        PullRequestGlyph(kind: .open).frame(width: 12, height: 12)
                    } else {
                        Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                    }
                }
                .foregroundStyle(selected ? Color.btText : Color.btTextSecondary)
                .frame(width: Rail.iconColumn)
                Text(title)
                    .font(BTFont.ui(13))
                    .foregroundStyle(selected ? Color.btText : Color.btTextSecondary)
                Spacer(minLength: 4)
                if count > 0 {
                    Text("\(count)").font(.btCaption).foregroundStyle(Color.btTextTertiary).monospacedDigit()
                }
            }
            .padding(.horizontal, Rail.rowPadding)
            .frame(height: Rail.rowHeight)
        }
        .buttonStyle(RailRowStyle(selected: selected))
    }
}

/// A section of the rail ("Projects"): a small label that folds everything
/// under it, with its actions shown on hover.
struct RailSection<Trailing: View>: View {
    let title: String
    @Binding var collapsed: Bool
    @ViewBuilder var trailing: () -> Trailing
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Button { withAnimation(.snappy(duration: 0.2)) { collapsed.toggle() } } label: {
                HStack(spacing: 4) {
                    Text(title)
                        .font(BTFont.ui(13.5))
                        .foregroundStyle(Color.btTextTertiary.opacity(hovering ? 1 : 0.75))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.btTextTertiary)
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                        .opacity(hovering || collapsed ? 1 : 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(collapsed ? "Show \(title)" : "Hide \(title)")
            Spacer(minLength: 4)
            trailing().opacity(hovering ? 1 : 0)
        }
        .padding(.leading, Rail.rowPadding)
        .padding(.trailing, 2)
        .frame(height: Rail.rowHeight)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.12), value: hovering)
        .padding(.top, Space.lg)
    }
}

/// A group header plus its rows.
struct RailGroup<Content: View>: View {
    let title: String
    var trailing: AnyView? = nil
    var onTitleTap: (() -> Void)? = nil
    var collapsed = false
    /// Makes the header a drag handle (projects reorder by their name).
    var dragItem: (() -> NSItemProvider)? = nil
    @ViewBuilder var content: () -> Content
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Button { onTitleTap?() } label: {
                    HStack(spacing: 4) {
                        Text(title)
                            .font(BTFont.ui(12.5))
                            .foregroundStyle(hovering && onTitleTap != nil ? Color.btTextSecondary : Color.btTextTertiary)
                            .lineLimit(1)
                        if onTitleTap != nil {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Color.btTextTertiary)
                                .rotationEffect(.degrees(collapsed ? 0 : 90))
                                .opacity(hovering || collapsed ? 1 : 0)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(onTitleTap == nil)
                Spacer(minLength: 4)
                // Actions appear with the pointer, so the rail at rest is just names.
                trailing.opacity(hovering ? 1 : 0)
            }
            .padding(.leading, Rail.rowPadding)
            .padding(.trailing, 2)
            .frame(height: Rail.rowHeight)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.snappy(duration: 0.12), value: hovering)
            .modifier(HeaderDrag(item: dragItem, title: title))

            if !collapsed { content() }
        }
        .padding(.top, Rail.groupGap)
        .animation(.snappy(duration: 0.2), value: collapsed)
    }
}

private struct RailProjectGroup: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @Binding var dragging: String?
    /// Where a dragged project would land: above this one or below it.
    @State private var dropEdge: VerticalEdge?

    var body: some View {
        let chats = model.sessions(in: project.id)
        let collapsed = model.collapsedProjects.contains(project.id)
        RailGroup(
            title: project.name,
            trailing: AnyView(
                HStack(spacing: 0) {
                    Button { model.destination = .projectSettings(project.id) } label: { Image(systemName: "ellipsis") }
                        .buttonStyle(RailIconStyle())
                        .help("\(project.name) settings")
                    Button { model.showNewChat(in: project.id) } label: { Image(systemName: "plus") }
                        .buttonStyle(RailIconStyle())
                        .help("New chat in \(project.name)")
                }
            ),
            onTitleTap: {
                if collapsed { model.collapsedProjects.remove(project.id) } else { model.collapsedProjects.insert(project.id) }
            },
            collapsed: collapsed,
            dragItem: {
                dragging = project.id
                return NSItemProvider(object: project.id as NSString)
            }
        ) {
            if chats.isEmpty {
                // Aligned with chat titles; not a button, the header's + starts one.
                Text("No chats")
                    .font(BTFont.ui(13))
                    .foregroundStyle(Color.btTextTertiary.opacity(0.7))
                    .padding(.leading, Rail.rowPadding + Rail.chatIndent + Rail.iconColumn + 8)
                    .frame(maxWidth: .infinity, minHeight: Rail.rowHeight, alignment: .leading)
            }
            ForEach(chats) { s in RailChatRow(session: s, backgroundTasks: model.runningBackgroundTasks(s.id)).equatable() }
        }
        .overlay(alignment: dropEdge == .bottom ? .bottom : .top) {
            if let dropEdge {
                Capsule()
                    .fill(Color.btTextSecondary)
                    .frame(height: 2)
                    .padding(.horizontal, Rail.rowPadding)
                    // In the gap between groups, not over a row.
                    .offset(y: dropEdge == .top ? Rail.groupGap / 2 - 1 : Rail.groupGap / 2)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.text], delegate: ProjectDrop(target: project.id, dragging: $dragging, edge: $dropEdge) { id, after in
            withAnimation(.snappy(duration: 0.2)) { model.moveProject(id, relativeTo: project.id, after: after) }
        })
        .contextMenu {
            Button("New Chat") { model.showNewChat(in: project.id) }
            Button("Show Worktrees") { model.destination = .worktrees }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.rootPath)]) }
            Button("Project Settings…") { model.destination = .projectSettings(project.id) }
            Divider()
            Button("Remove Project…", role: .destructive) { confirmRemove() }
        }
    }

    private func confirmRemove() {
        let alert = NSAlert()
        alert.messageText = "Remove \(project.name) from Abstract?"
        alert.informativeText = "Its chats are removed from Abstract. The repository and any worktrees on disk are left alone."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { model.removeProject(project.id) }
    }
}

struct RailChatRow: View {
    @Environment(AppModel.self) private var model
    let session: Session
    /// Still at work in the background, so an idle chat doesn't look done.
    var backgroundTasks = 0
    var showProject = false
    @State private var renaming = false
    @State private var draft = ""
    @State private var hovering = false
    @State private var hoveringDetails = false
    @State private var showingDetails = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let selected = model.selectedSessionId == session.id
        Button { model.open(session.id) } label: {
            HStack(spacing: 8) {
                // At rest, a chat with a pull request shows how that stands;
                // while it works, or needs you, or failed, its own status wins.
                Group {
                    if [.idle, .finished, .created].contains(session.status), let pr = model.pullRequests[session.id] {
                        PullRequestMark(pr: pr)
                    } else {
                        RailStatus(status: session.status)
                    }
                }
                .frame(width: Rail.iconColumn)
                if renaming {
                    TextField("Name", text: $draft)
                        .textFieldStyle(.plain)
                        .font(BTFont.ui(13))
                        .focused($fieldFocused)
                        .onAppear { fieldFocused = true }
                        .onSubmit(commitRename)
                        .onExitCommand { renaming = false }
                        .padding(.horizontal, 6)
                        .frame(height: Field.compactHeight)
                        .btFieldChrome(focused: fieldFocused)
                        .padding(.leading, -6)
                } else {
                    Text(session.name)
                        .font(BTFont.ui(13))
                        .foregroundStyle(selected ? Color.btText : Color.btText.opacity(0.86))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
                if backgroundTasks > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "square.stack.3d.up").font(.system(size: 9))
                        Text("\(backgroundTasks)").monospacedDigit()
                    }
                    .font(.btCaption)
                    .foregroundStyle(Color.btTextTertiary)
                    .help(backgroundTasks == 1 ? "1 task in the background" : "\(backgroundTasks) tasks in the background")
                }
                if showProject, let p = model.project(session.projectId) {
                    Text(p.name).font(.btCaption).foregroundStyle(Color.btTextTertiary).lineLimit(1)
                }
            }
            .padding(.leading, Rail.rowPadding + Rail.chatIndent)
            .padding(.trailing, Rail.rowPadding)
            .frame(height: Rail.rowHeight)
        }
        .buttonStyle(RailRowStyle(selected: selected))
        .opacity(session.archivedAt == nil ? 1 : 0.5)
        .onHover {
            hovering = $0
            if !$0 {
                Task {
                    try? await Task.sleep(for: .milliseconds(250))
                    if !hovering && !hoveringDetails { showingDetails = false }
                }
            }
        }
        .task(id: hovering) {
            guard hovering, !renaming else { return }
            try? await Task.sleep(for: .milliseconds(500))
            if !Task.isCancelled && hovering { showingDetails = true }
        }
        .popover(isPresented: $showingDetails, arrowEdge: .trailing) {
            RailChatDetails(session: session)
                .onHover {
                    hoveringDetails = $0
                    if !$0 && !hovering { showingDetails = false }
                }
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded { if !remote { draft = session.name; renaming = true } })
        .contextMenu {
            if remote {
                Button(session.archivedAt == nil ? "Archive" : "Unarchive") {
                    model.setArchived(session.id, session.archivedAt == nil)
                }
            } else {
                localActions
            }
        }
    }

    private var remote: Bool { session.id.hasPrefix(RemoteService.mirrorPrefix) }

    @ViewBuilder private var localActions: some View {
        Button("Rename") { draft = session.name; renaming = true }
        Button(session.archivedAt == nil ? "Archive" : "Unarchive") { model.setArchived(session.id, session.archivedAt == nil) }
        if let path = session.worktreePath {
            Button("Reveal Worktree in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        }
        Divider()
        Button("Delete Chat and Worktree…", role: .destructive) { confirmDelete() }
    }

    private func commitRename() {
        model.rename(session.id, to: draft)
        renaming = false
    }

    private func confirmDelete() {
        let alert = NSAlert()
        alert.messageText = "Delete “\(session.name)”?"
        alert.informativeText = "The agent is stopped and its worktree is removed. Uncommitted work in the worktree is lost; the branch is kept."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { Task { await model.delete(session.id, removeWorktree: true) } }
    }
}

/// A chat's status as a small ring. At rest it is a quiet hollow circle;
/// working turns it into a slowly turning arc; only "needs you" and errors
/// fill in with colour.
private struct RailStatus: View {
    let status: SessionStatus

    private static let size: CGFloat = 10

    var body: some View {
        ZStack {
            switch status {
            case .running, .provisioning:
                // A short stroke runs round the outline, the way the ring's arc spun.
                AnimatedDiamond(motion: .travel, color: .btAccent, track: Color.btTextTertiary.opacity(0.35))
            case .waitingInput:
                RoundedDiamond().fill(Color.btAttention)
            case .errored:
                RoundedDiamond().fill(Color.btRemoved)
            case .idle:
                RoundedDiamond().stroke(Color.btTextSecondary, lineWidth: 1.2)
            case .finished, .created:
                RoundedDiamond().stroke(Color.btTextTertiary.opacity(0.7), lineWidth: 1.2)
            }
        }
        .frame(width: Self.size, height: Self.size)
        .accessibilityLabel(status.label)
    }
}

private struct RailChatDetails: View {
    @Environment(AppModel.self) private var model
    let session: Session

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text(session.name)
                .font(BTFont.ui(15, .medium))
                .foregroundStyle(Color.btText)
                .fixedSize(horizontal: false, vertical: true)
            Text(session.status.label)
                .font(.btCaption)
                .foregroundStyle(Color.btTextSecondary)
            Hairline()
            detail("Branch", session.branch ?? "No branch", monospaced: true)
            if let pr {
                VStack(alignment: .leading, spacing: 4) {
                    caption("Pull request")
                    HStack(spacing: Space.sm) {
                        Text("#\(pr.number) · \(pr.state)")
                            .font(BTFont.ui(13))
                        Spacer()
                        if let url = pr.url {
                            Button { NSWorkspace.shared.open(url) } label: {
                                Image(systemName: "arrow.up.right.square")
                            }
                            .buttonStyle(.plain)
                            .help("Open pull request")
                        }
                    }
                    Text(pr.title).font(.btCaption).foregroundStyle(Color.btTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                detail("Pull request", remoteDetailsUnavailable ? "Unavailable from this device" : "No PR for this branch")
            }
            Hairline()
            detail("Agent", ProviderRegistry.name(session.providerId))
            detail("Model", modelName)
            detail("Device", deviceName)
            if let project = model.project(session.projectId) { detail("Project", project.name) }
            detail("Updated", "\(RelativeTime.short(session.lastEventAt ?? session.createdAt)) ago")
        }
        .padding(Space.lg)
        .frame(width: 310, alignment: .leading)
    }

    private var deviceName: String {
        guard let (device, _) = RemoteService.split(session.id) else { return model.remote.identity.name }
        return model.remote.paired.first(where: { $0.id == device })?.peer.name ?? "Unknown device"
    }

    private var modelName: String {
        guard let (device, _) = RemoteService.split(session.id) else {
            return model.modelLabel(providerId: session.providerId, model: session.model)
        }
        let catalog = model.models(for: session.providerId, on: device)
        if let selected = session.model { return catalog.option(selected)?.label ?? selected }
        return model.defaultModelName(for: session.providerId, on: device).map { "Default (\($0))" } ?? "Default model"
    }

    private var remoteDetailsUnavailable: Bool {
        guard let (device, _) = RemoteService.split(session.id) else { return false }
        return model.remote.links[device]?.snapshot?.pullRequests == nil
    }

    private var pr: (number: Int, title: String, state: String, url: URL?)? {
        if let local = model.pullRequests[session.id] {
            return (local.number, local.title, local.isDraft ? "Draft" : local.state.rawValue.capitalized, local.url)
        }
        guard let (device, hostId) = RemoteService.split(session.id),
              let remote = model.remote.links[device]?.snapshot?.pullRequests?[hostId] else { return nil }
        return (remote.number, remote.title, remote.isDraft ? "Draft" : remote.state.capitalized, remote.url)
    }

    private func caption(_ title: String) -> some View {
        Text(title.uppercased()).font(.btSectionLabel).foregroundStyle(Color.btTextTertiary)
    }

    private func detail(_ title: String, _ value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            caption(title)
            Text(value)
                .font(monospaced ? .btMono : .btBody)
                .foregroundStyle(Color.btTextSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Styles

/// Rail rows: a faint wash on hover, a slightly stronger one when selected.
struct RailRowStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        RailRowBody(configuration: configuration, selected: selected)
    }

    private struct RailRowBody: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: Rail.radius, style: .continuous)
                        .fill(selected ? Color.btSelection : hovering || configuration.isPressed ? Color.btHover : .clear)
                )
                .onHover { hovering = $0 }
                .animation(.snappy(duration: 0.12), value: hovering)
        }
    }
}

/// The small + on a project header.
struct RailIconStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { IconBody(configuration: configuration) }

    private struct IconBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering ? Color.btText : Color.btTextTertiary)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? Color.btHover : .clear))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }

}

/// Lets a rail group's header be picked up, with its name as the drag image.
private struct HeaderDrag: ViewModifier {
    let item: (() -> NSItemProvider)?
    let title: String

    func body(content: Content) -> some View {
        if let item {
            content.onDrag(item) {
                Text(title)
                    .font(BTFont.ui(12.5, .medium))
                    .foregroundStyle(Color.btText)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(Color.btSurfaceRaised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        } else {
            content
        }
    }
}

/// Drops a dragged project above or below this one: the upper part of the
/// header means above, anywhere lower means below.
private struct ProjectDrop: DropDelegate {
    let target: String
    @Binding var dragging: String?
    @Binding var edge: VerticalEdge?
    let move: (String, Bool) -> Void

    func validateDrop(info: DropInfo) -> Bool { dragging != nil && dragging != target }
    func dropEntered(info: DropInfo) { update(info) }
    func dropExited(info: DropInfo) { edge = nil }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { edge = nil; dragging = nil }
        guard let id = dragging, id != target else { return false }
        move(id, edge == .bottom)
        return true
    }

    private func update(_ info: DropInfo) {
        guard let dragging, dragging != target else { edge = nil; return }
        edge = info.location.y < Rail.groupGap + Rail.rowHeight / 2 ? .top : .bottom
    }
}

/// A row redraws when its chat changes, not whenever any chat does.
extension RailChatRow: Equatable {
    nonisolated static func == (a: RailChatRow, b: RailChatRow) -> Bool {
        a.session == b.session && a.backgroundTasks == b.backgroundTasks && a.showProject == b.showProject
    }
}
