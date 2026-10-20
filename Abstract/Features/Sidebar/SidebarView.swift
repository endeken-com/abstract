import AppKit
import SwiftUI
import AbstractCore

/// The left rail. Chats are grouped by what they need from you (or, by
/// choice, under their projects), each as a calm two-line row. Built by hand
/// rather than with a sidebar `List` so spacing and row height are exact.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool
    /// The project being dragged to a new place in the rail.
    @State private var draggingProject: String?
    @AppStorage("sidebar.projectsCollapsed") private var projectsCollapsed = false
    @AppStorage("sidebar.arrangement") private var arrangement: SidebarChats.Arrangement = .status
    @AppStorage("sidebar.filter") private var filterJSON = ""
    @State private var searching = false
    @State private var query = ""
    @State private var showOlderDone = false

    var body: some View {
        VStack(spacing: 0) {
            list
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")")
                .font(.btCaption)
                .foregroundStyle(Color.btTextTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, Rail.inset + Rail.rowPadding)
                .padding(.vertical, 6)
            // Devices stay in reach at the foot, however long the list.
            Hairline()
            RailDevicesBar()
                .padding(.horizontal, Rail.inset)
                .padding(.vertical, 6)
        }
    }

    private var filter: SidebarChats.Filter {
        (try? JSONDecoder().decode(SidebarChats.Filter.self, from: Data(filterJSON.utf8))) ?? SidebarChats.Filter()
    }

    private var narrowing: Bool { !filter.isEmpty || !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// The chats the search and filters let through, archived ones only when asked for.
    private func visibleChats(_ all: [SidebarChats.Chat]) -> [SidebarChats.Chat] {
        let filter = filter
        return all.filter {
            (model.showArchived || $0.session.archivedAt == nil) && filter.matches($0) && SidebarChats.matches($0, query: query)
        }
    }

    private var list: some View {
        let allChats = model.sidebarChats()
        let chats = visibleChats(allChats)
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 1) {
                    RailNavRow(title: "New", symbol: "plus", destination: .home)
                    RailNavRow(title: "Automations", symbol: "clock", destination: .automations)
                    RailNavRow(title: "Worktrees", symbol: "arrow.triangle.branch", destination: .worktrees)
                    RailNavRow(title: "Pull Requests", symbol: PullRequestGlyph.symbol, destination: .pullRequests)
                    ForEach(model.plugins.usable) { plugin in
                        if let view = plugin.view {
                            RailNavRow(title: view.title,
                                       symbol: NSImage(systemSymbolName: view.symbolOrFallback, accessibilityDescription: nil) != nil
                                           ? view.symbolOrFallback : PluginManifest.fallbackSymbol,
                                       destination: .plugin(plugin.id, view.id))
                        }
                    }
                }

                RailSection(title: arrangement == .status ? "Chats" : model.remote.identity.name, collapsed: $projectsCollapsed,
                            showsTrailing: searching || !filter.isEmpty) {
                    HStack(spacing: 0) {
                        Button {
                            searching.toggle()
                            if !searching { query = "" }
                        } label: { Image(systemName: "magnifyingglass") }
                            .buttonStyle(RailIconStyle())
                            .help("Search chats")
                        SidebarFilterMenu(arrangement: $arrangement, filterJSON: $filterJSON, filter: filter, chats: allChats)
                        Button { model.isAddingProject = true } label: { Image(systemName: "plus") }
                            .buttonStyle(RailIconStyle())
                            .help("Add project")
                    }
                }

                if searching {
                    SidebarSearchField(query: $query) { searching = false; query = "" }
                        .padding(.vertical, 4)
                }

                if !projectsCollapsed {
                    switch arrangement {
                    case .status: statusGroups(chats)
                    case .project: projectGroups(chats)
                    }
                    if narrowing && chats.isEmpty {
                        Text("No chats match")
                            .font(BTFont.ui(13))
                            .foregroundStyle(Color.btTextTertiary.opacity(0.7))
                            .padding(.leading, Rail.rowPadding)
                            .frame(maxWidth: .infinity, minHeight: Rail.rowHeight, alignment: .leading)
                    }
                }
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
        .onKeyPress(.downArrow) { step(1, in: chats) }
        .onKeyPress(.upArrow) { step(-1, in: chats) }
    }

    /// Pinned, Needs you, Working, Ready to review, Done: across projects and Macs.
    @ViewBuilder private func statusGroups(_ chats: [SidebarChats.Chat]) -> some View {
        ForEach(SidebarChats.sections(chats)) { section in
            RailGroup(title: section.group.title) {
                ForEach(section.chats) { chat in RailChatRow(chat: chat, showProject: true).equatable() }
                if !section.older.isEmpty {
                    if showOlderDone {
                        ForEach(section.older) { chat in RailChatRow(chat: chat, showProject: true).equatable() }
                    }
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { showOlderDone.toggle() }
                    } label: {
                        Text(showOlderDone ? "Hide older" : "Show \(section.older.count) older")
                            .font(BTFont.ui(12.5))
                            .foregroundStyle(Color.btTextTertiary)
                            .padding(.leading, Rail.rowPadding + Rail.chatIndent + Rail.iconColumn + 8)
                            .frame(maxWidth: .infinity, minHeight: Rail.rowHeight - 4, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Today's layout: each project's chats under it, then Standalone, then each paired Mac's.
    @ViewBuilder private func projectGroups(_ chats: [SidebarChats.Chat]) -> some View {
        let byId = Dictionary(chats.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        ForEach(model.projects) { project in
            let rows = model.sessions(in: project.id).compactMap { byId[$0.id] }
            if !narrowing || !rows.isEmpty {
                RailProjectGroup(project: project, chats: rows, dragging: $draggingProject)
            }
        }

        let standalone = model.sessions(in: nil).compactMap { byId[$0.id] }
        if !standalone.isEmpty {
            RailGroup(title: SidebarChats.standalone, trailing: AnyView(
                Button { model.showNewChat(in: nil, standalone: true) } label: { Image(systemName: "plus") }
                    .buttonStyle(RailIconStyle())
                    .help("New standalone chat")
            )) {
                ForEach(standalone) { chat in RailChatRow(chat: chat, showPin: true).equatable() }
            }
        }

        RemoteDevicesSection(chats: byId, narrowing: narrowing)
    }

    /// Arrow keys walk the chats in the order the rail shows them.
    private func step(_ delta: Int, in chats: [SidebarChats.Chat]) -> KeyPress.Result {
        let order: [String]
        if projectsCollapsed {
            order = []
        } else if arrangement == .status {
            order = SidebarChats.sections(chats).flatMap { $0.chats + (showOlderDone ? $0.older : []) }.map(\.id)
        } else {
            let shown = Set(chats.map(\.id))
            order = (model.projects.flatMap { p in
                model.collapsedProjects.contains(p.id) ? [] : model.sessions(in: p.id).map(\.id)
            } + model.sessions(in: nil).map(\.id)).filter(shown.contains)
        }
        var seen = Set<String>()
        let unique = order.filter { seen.insert($0).inserted }
        guard !unique.isEmpty else { return .ignored }
        let current = model.selectedSessionId.flatMap { unique.firstIndex(of: $0) }
        let next = current.map { min(max($0 + delta, 0), unique.count - 1) } ?? (delta > 0 ? 0 : unique.count - 1)
        model.open(unique[next])
        return .handled
    }
}

/// The search field under the chats header: title, branch or pull request number.
private struct SidebarSearchField: View {
    @Binding var query: String
    let close: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Color.btTextTertiary)
            TextField("Title, branch or PR number", text: $query)
                .textFieldStyle(.plain)
                .font(BTFont.ui(13))
                .focused($focused)
                .onExitCommand(perform: close)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.btTextTertiary)
                    .help("Clear")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Field.compactHeight)
        .btFieldChrome(focused: focused)
        .onAppear { focused = true }
    }
}

/// The chats header's filter menu: how to group, which chats, and archived ones.
private struct SidebarFilterMenu: View {
    @Environment(AppModel.self) private var model
    @Binding var arrangement: SidebarChats.Arrangement
    @Binding var filterJSON: String
    let filter: SidebarChats.Filter
    /// Every chat, filtered or not: the choices come from them.
    let chats: [SidebarChats.Chat]
    @State private var hovering = false

    var body: some View {
        @Bindable var model = model
        let projects = Set(model.projects.map(\.name) + chats.map { $0.projectName ?? SidebarChats.standalone }).sorted()
        let macs = Set(chats.map(\.mac) + [model.remote.identity.name]).sorted()
        Menu {
            Picker("Group By", selection: $arrangement) {
                Text("Status").tag(SidebarChats.Arrangement.status)
                Text("Project").tag(SidebarChats.Arrangement.project)
            }
            .pickerStyle(.inline)
            Divider()
            Menu("Project") {
                ForEach(projects, id: \.self) { name in Toggle(name, isOn: choice(\.projects, name)) }
            }
            Menu("Agent") {
                ForEach(ProviderRegistry.all.map(\.id), id: \.self) { id in
                    Toggle(ProviderRegistry.name(id), isOn: choice(\.agents, id))
                }
            }
            if macs.count > 1 {
                Menu("Mac") {
                    ForEach(macs, id: \.self) { name in Toggle(name, isOn: choice(\.macs, name)) }
                }
            }
            if !filter.isEmpty {
                Button("Show All Chats") { save(SidebarChats.Filter()) }
            }
            Divider()
            Toggle("Show Archived Chats", isOn: $model.showArchived)
        } label: {
            Image(systemName: filter.isEmpty ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering || !filter.isEmpty ? Color.btText : Color.btTextTertiary)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? Color.btHover : .clear))
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help(filter.isEmpty ? "Group and filter chats" : "Some chats are filtered out")
    }

    private func choice(_ key: WritableKeyPath<SidebarChats.Filter, Set<String>>, _ value: String) -> Binding<Bool> {
        Binding {
            filter[keyPath: key].contains(value)
        } set: { on in
            var next = filter
            if on { next[keyPath: key].insert(value) } else { next[keyPath: key].remove(value) }
            save(next)
        }
    }

    private func save(_ next: SidebarChats.Filter) {
        filterJSON = next.isEmpty ? "" : (try? JSONEncoder().encode(next)).map { String(decoding: $0, as: UTF8.self) } ?? ""
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
    /// Keeps its actions showing at rest: a search open or a filter on.
    var showsTrailing = false
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
            trailing().opacity(hovering || showsTrailing ? 1 : 0)
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
    /// Its chats the search and filters let through, in the rail's order.
    let chats: [SidebarChats.Chat]
    @Binding var dragging: String?
    /// Where a dragged project would land: above this one or below it.
    @State private var dropEdge: VerticalEdge?

    var body: some View {
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
            ForEach(chats) { chat in RailChatRow(chat: chat, showPin: true).equatable() }
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
            if model.projectIsPaused(project.id) && !model.everythingPaused {
                Button("Resume Project") { model.resumeProject(project.id) }
            } else if !model.everythingPaused {
                Button("Pause Project") { model.pauseProject(project.id) }
            }
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

/// A chat in the rail: its project and state, title and age on the first
/// line; where it lives and how its pull request stands on a quiet second.
struct RailChatRow: View {
    @Environment(AppModel.self) private var model
    let chat: SidebarChats.Chat
    /// Its project on the second line, where the rail doesn't group by project.
    var showProject = false
    /// A pin by the title, where pinned chats aren't a group of their own.
    var showPin = false
    @State private var renaming = false
    @State private var draft = ""
    @State private var hovering = false
    @State private var restingPoint: CGPoint?
    @State private var hoveringDetails = false
    @State private var showingDetails = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let selected = model.selectedSessionId == session.id
        let unreachable = model.remote.unreachableMessage(session.id)
        let stalled = unreachable == nil && (model.stallState(session.id)?.isStalled ?? false)
        let line = SidebarChats.line(for: chat, showProject: showProject)
        Button { model.open(session.id) } label: {
            HStack(alignment: line.isEmpty && unreachable == nil && !stalled ? .center : .top, spacing: 8) {
                RailChatMark(chat: chat, status: unreachable == nil ? session.status : .idle,
                             working: unreachable == nil && backgroundTasks > 0, stalled: stalled)
                    .opacity(unreachable == nil ? 1 : 0.5)
                    .frame(width: Rail.iconColumn, height: 17)
                VStack(alignment: .leading, spacing: 1) {
                    firstLine(selected: selected)
                    if let unreachable {
                        Text(unreachable)
                            .font(.btCaption)
                            .foregroundStyle(Color.btTextTertiary)
                            .lineLimit(1)
                    } else if stalled {
                        Text("Stalled")
                            .font(.btCaption)
                            .foregroundStyle(Color.btWarning)
                            .lineLimit(1)
                    } else if !line.isEmpty { RailChatLine(line: line) }
                }
            }
            .padding(.leading, Rail.rowPadding + Rail.chatIndent)
            .padding(.trailing, Rail.rowPadding)
            .padding(.vertical, line.isEmpty && unreachable == nil && !stalled ? 0 : 5)
            .frame(minHeight: Rail.rowHeight)
        }
        .buttonStyle(RailRowStyle(selected: selected))
        .opacity(session.archivedAt == nil ? 1 : 0.5)
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                hovering = true
                restingPoint = point
            case .ended:
                hovering = false
                restingPoint = nil
                Task {
                    try? await Task.sleep(for: .milliseconds(250))
                    if !hovering && !hoveringDetails { showingDetails = false }
                }
            }
        }
        // Every pointer move restarts the wait, so the card only opens once the pointer rests.
        .task(id: restingPoint) {
            guard restingPoint != nil, !renaming, !showingDetails else { return }
            try? await Task.sleep(for: .milliseconds(600))
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
        // `/rename` in the composer: the row that shows the chat takes it.
        .onChange(of: model.renamingSessionId, initial: true) { _, id in
            guard id == session.id, !remote else { return }
            model.renamingSessionId = nil
            draft = session.name
            renaming = true
        }
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

    private var session: Session { chat.session }
    /// Still at work in the background, so an idle chat doesn't look done.
    private var backgroundTasks: Int { chat.backgroundTasks }

    /// The title (or its rename field), then a pin, background tasks and the age.
    @ViewBuilder private func firstLine(selected: Bool) -> some View {
        HStack(spacing: 6) {
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
            if showPin, session.pinnedAt != nil {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.btTextTertiary)
                    .help("Pinned")
            }
            if backgroundTasks > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "square.stack.3d.up").font(.system(size: 9))
                    Text("\(backgroundTasks)").monospacedDigit()
                }
                .font(.btCaption)
                .foregroundStyle(Color.btTextTertiary)
                .help(backgroundTasks == 1 ? "1 task in the background" : "\(backgroundTasks) tasks in the background")
            }
            if !renaming {
                // Ticks over on its own, so "now" becomes "1m" without anything else changing.
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(RelativeAge.short(chat.activeAt, now: context.date))
                        .font(.btCaption)
                        .foregroundStyle(Color.btTextTertiary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                }
                .help("Last active \(chat.activeAt.formatted(date: .abbreviated, time: .shortened))")
            }
        }
        .frame(minHeight: 17)
    }

    private var remote: Bool { session.id.hasPrefix(RemoteService.mirrorPrefix) }
    /// No project: it works in a folder of its own, not a worktree.
    private var standalone: Bool { session.projectId == nil }

    @ViewBuilder private var localActions: some View {
        Button("Rename") { draft = session.name; renaming = true }
        Button(session.pinnedAt == nil ? "Pin" : "Unpin") { model.setPinned(session.id, session.pinnedAt == nil) }
        Button(session.archivedAt == nil ? "Archive" : "Unarchive") { model.setArchived(session.id, session.archivedAt == nil) }
        if let path = session.worktreePath {
            Button(standalone ? "Reveal Folder in Finder" : "Reveal Worktree in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
        Divider()
        Button(standalone ? "Delete Chat and Folder…" : "Delete Chat and Worktree…", role: .destructive) { confirmDelete() }
    }

    private func commitRename() {
        model.rename(session.id, to: draft)
        renaming = false
    }

    private func confirmDelete() {
        Task {
            // Commits in its submodules that no remote has go with the worktree.
            var lost: String?
            if !standalone, let path = session.worktreePath {
                lost = await model.unpushedSubmoduleWarning(model.executor(for: session.id), worktree: path)
            }
            let alert = NSAlert()
            alert.messageText = "Delete “\(session.name)”?"
            alert.informativeText = (standalone
                ? "The agent is stopped and the chat's folder is removed with everything in it."
                : "The agent is stopped and its worktree is removed. Uncommitted work in the worktree is lost; the branch is kept.")
                + (lost.map { "\n\n" + $0 } ?? "")
            alert.addButton(withTitle: lost == nil ? "Delete" : "Delete Anyway")
            alert.addButton(withTitle: "Cancel")
            alert.buttons.first?.hasDestructiveAction = true
            if alert.runModal() == .alertFirstButtonReturn { await model.delete(session.id, removeWorktree: true) }
        }
    }
}

/// A chat's status as a small ring. At rest it is a quiet hollow circle;
/// working turns it into a slowly turning arc; only "needs you" and errors
/// fill in with colour.
private struct RailStatus: View {
    let status: SessionStatus
    /// Working, but no output for so long the chat is marked Stalled.
    var stalled = false
    var size: CGFloat = 10

    var body: some View {
        ZStack {
            if stalled {
                RoundedDiamond().fill(Color.btWarning)
            } else { statusMark }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(stalled ? "Stalled" : status.label)
    }

    @ViewBuilder private var statusMark: some View {
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
}

/// What leads a chat's row: its project's icon (its agent's logo when it
/// has no project), with a small badge for its state: turning while it
/// works, filled when it needs you, red when it failed. At rest, just the icon.
private struct RailChatMark: View {
    let chat: SidebarChats.Chat
    let status: SessionStatus
    /// Still at work in the background, though its turn is over.
    var working = false
    /// No output for so long the chat is marked Stalled.
    var stalled = false

    var body: some View {
        content
            .overlay(alignment: .bottomTrailing) {
                if let badge {
                    RailStatus(status: badge, stalled: stalled, size: 7)
                        .padding(1.5)
                        .background(RoundedDiamond().fill(Color.btSidebar))
                        .offset(x: 3.5, y: 3.5)
                }
            }
            .accessibilityLabel("\(chat.projectName ?? SidebarChats.standalone), \(ProviderRegistry.name(chat.session.providerId)), \(stalled ? "Stalled" : status.label)")
    }

    @ViewBuilder private var content: some View {
        switch chat.icon {
        case .agentLogo:
            ProviderLogo(providerId: chat.session.providerId, size: 14)
        case .project(let mark):
            RailProjectMark(mark: mark)
        }
    }

    private var badge: SessionStatus? {
        switch status {
        case .running, .provisioning, .waitingInput, .errored: status
        case .idle, .finished, .created: working ? .running : nil
        }
    }
}

/// A project's icon at rail size, as Project Settings shows it: its uploaded
/// image (from its file here, or from the bytes its Mac sent), else its
/// symbol or initial on its colour.
private struct RailProjectMark: View {
    let mark: SidebarChats.ProjectMark

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .frame(width: Rail.iconColumn, height: Rail.iconColumn)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            ProjectIconView(project: Project(name: mark.name, rootPath: "", iconSymbol: mark.symbol, iconColor: mark.color),
                            size: Rail.iconColumn)
        }
    }

    private var image: NSImage? {
        if let data = mark.imageData { return NSImage(data: data) }
        if let file = mark.imageFile { return ProjectIconStore.image(file) }
        return nil
    }
}

/// A chat row's quiet second line: project, pull request, checks, a review
/// asking for changes, and the Mac it runs on, as far as each applies.
private struct RailChatLine: View {
    let line: SidebarChats.Line

    var body: some View {
        HStack(spacing: 4) {
            if let project = line.project { part(project) }
            if let pr = line.pullRequest {
                dot(after: line.project != nil)
                HStack(spacing: 3) {
                    PullRequestGlyph(kind: .init(state: pr.state, isDraft: pr.isDraft))
                        .foregroundStyle(Color.pullRequestInk(state: pr.state, isDraft: pr.isDraft))
                        .frame(width: 10, height: 10)
                    part("#\(pr.number)").monospacedDigit()
                    if let checks = line.checks {
                        HStack(spacing: 2) {
                            Image(systemName: checks.symbol)
                                .font(.system(size: 9, weight: .semibold))
                            Text(checks.rawValue)
                        }
                        .foregroundStyle(checks.color)
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
            }
            if line.changesRequested {
                dot(after: true)
                part("changes requested", color: .btText.opacity(0.75))
            }
            if let mac = line.mac {
                dot(after: line.project != nil || line.pullRequest != nil)
                HStack(spacing: 2) {
                    Image(systemName: "laptopcomputer").font(.system(size: 8.5))
                    part(mac)
                }
            }
        }
        .font(.btCaption)
        .foregroundStyle(Color.btTextTertiary)
        .lineLimit(1)
        .frame(height: 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.accessibilityText)
    }

    private func part(_ text: String, color: Color = .btTextTertiary) -> some View {
        Text(text).foregroundStyle(color).lineLimit(1).truncationMode(.tail)
    }

    @ViewBuilder private func dot(after previous: Bool) -> some View {
        if previous { Text("·").foregroundStyle(Color.btTextTertiary.opacity(0.7)) }
    }
}

private extension SidebarChats.PullRequestFacts.Checks {
    var symbol: String {
        switch self {
        case .passed: "checkmark"
        case .failing: "xmark"
        case .running: "clock"
        }
    }

    var color: Color {
        switch self {
        case .passed: .btAdded
        case .failing: .btRemoved
        case .running: .btTextSecondary
        }
    }
}

extension PullRequestGlyph.Kind {
    init(state: PullRequest.State, isDraft: Bool) {
        switch state {
        case .merged: self = .merged
        case .closed: self = .closed
        case .open: self = isDraft ? .draft : .open
        }
    }
}

extension Color {
    static func pullRequestInk(state: PullRequest.State, isDraft: Bool) -> Color {
        switch state {
        case .open: isDraft ? .btPullRequestDraftInk : .btPullRequestOpenInk
        case .merged: .btPullRequestMergedInk
        case .closed: .btPullRequestClosedInk
        }
    }
}

private struct RailChatDetails: View {
    @Environment(AppModel.self) private var model
    let session: Session

    /// A local or remote pull request, whichever the chat has.
    private struct PR {
        let number: Int
        let title: String
        let state: PullRequest.State
        let isDraft: Bool
        let url: URL?

        var label: String {
            switch state {
            case .merged: "Merged"
            case .closed: "Closed"
            case .open: isDraft ? "Draft" : "Open"
            }
        }

        var glyph: PullRequestGlyph.Kind { .init(state: state, isDraft: isDraft) }
        var ink: Color { .pullRequestInk(state: state, isDraft: isDraft) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(alignment: .top, spacing: Space.sm) {
                RailStatus(status: session.status).frame(width: 16, height: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.name)
                        .font(BTFont.ui(14, .medium))
                        .foregroundStyle(Color.btText)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(session.status.label) · updated \(RelativeTime.short(session.lastEventAt ?? session.createdAt)) ago")
                        .font(.btCaption)
                        .foregroundStyle(Color.btTextTertiary)
                }
            }
            Hairline()
            VStack(alignment: .leading, spacing: Space.sm) {
                row("Branch") {
                    Image(nsImage: Octicon.gitBranch).renderingMode(.template).resizable().frame(width: 12, height: 12)
                } content: {
                    value(session.branch ?? "No branch", monospaced: true)
                }
                prRow
            }
            Hairline()
            VStack(alignment: .leading, spacing: Space.sm) {
                row("Agent") { ProviderLogo(providerId: session.providerId, size: 12) } content: {
                    value(ProviderRegistry.name(session.providerId))
                }
                row("Model") { Image(systemName: "cpu") } content: { value(modelName) }
                row("Time") { Image(systemName: "clock") } content: { value(timeSummary) }
                row("Device") { Image(systemName: "laptopcomputer") } content: { value(deviceName) }
                row("Project") { Image(systemName: "folder") } content: {
                    value(model.project(session.projectId)?.name ?? "Standalone")
                }
            }
        }
        .padding(Space.md)
        .frame(width: 360, alignment: .leading)
        // The working time is read from the chat's log.
        .onAppear { if RemoteService.split(session.id) == nil { model.loadTimelineIfNeeded(session.id) } }
    }

    /// "47m working over 12 turns · started Oct 11, 14:02": the turns added
    /// up, not the time spent waiting for you between them.
    private var timeSummary: String {
        let time = model.feed(session.id).time
        let started = "started \(session.createdAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))"
        guard time.turns > 0 else { return "No turns yet · \(started)" }
        return "\(RelativeTime.duration(time.workingMs)) working over \(time.turns) turn\(time.turns == 1 ? "" : "s") · \(started)"
    }

    @ViewBuilder private var prRow: some View {
        if let pr {
            row("PR") {
                PullRequestGlyph(kind: pr.glyph).foregroundStyle(pr.ink).frame(width: 12, height: 12)
            } content: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("#\(pr.number)").font(BTFont.ui(12, .medium)).foregroundStyle(Color.btText)
                        Text(pr.label)
                            .font(BTFont.ui(10.5, .medium))
                            .foregroundStyle(pr.ink)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(pr.ink.opacity(0.15)))
                        Spacer(minLength: 0)
                        if let url = pr.url {
                            Button { NSWorkspace.shared.open(url) } label: {
                                Image(systemName: "arrow.up.right.square")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.btTextSecondary)
                            .help("Open pull request")
                        }
                    }
                    value(pr.title)
                }
            }
        } else {
            row("PR") {
                PullRequestGlyph(kind: .open).frame(width: 12, height: 12)
            } content: {
                value(remoteDetailsUnavailable ? "Unavailable from this device" : "None for this branch")
            }
        }
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

    private var pr: PR? {
        if let local = model.pullRequests[session.id] {
            return PR(number: local.number, title: local.title, state: local.state, isDraft: local.isDraft, url: local.url)
        }
        guard let (device, hostId) = RemoteService.split(session.id),
              let remote = model.remote.links[device]?.snapshot?.pullRequests?[hostId] else { return nil }
        return PR(number: remote.number, title: remote.title, state: PullRequest.State(rawValue: remote.state) ?? .open,
                  isDraft: remote.isDraft, url: remote.url)
    }

    /// Icon, name, then the value, which wraps rather than truncates.
    private func row<Icon: View, Content: View>(_ label: String, @ViewBuilder icon: () -> Icon,
                                                @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: Space.sm) {
            icon()
                .font(.system(size: 11))
                .foregroundStyle(Color.btTextTertiary)
                .frame(width: 16, height: 16)
            Text(label)
                .font(.btCaption)
                .foregroundStyle(Color.btTextTertiary)
                .frame(width: 48, height: 16, alignment: .leading)
            content()
        }
    }

    private func value(_ text: String, monospaced: Bool = false) -> some View {
        Text(text)
            .font(monospaced ? .btMono : BTFont.ui(12))
            .foregroundStyle(Color.btTextSecondary)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, minHeight: 16, alignment: .leading)
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
        a.chat == b.chat && a.showProject == b.showProject && a.showPin == b.showPin
    }
}
