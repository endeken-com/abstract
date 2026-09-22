import SwiftUI
import BacktickCore

/// The left rail. Projects are quiet group headers with a + for a new chat;
/// chats sit beneath them as single calm lines. Built by hand rather than
/// with a sidebar `List` so spacing and row height are exact.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 1) {
                    RailNavRow(title: "New", symbol: "plus", destination: .home)
                    RailNavRow(title: "Automations", symbol: "clock", destination: .automations,
                               count: model.automations.filter(\.enabled).count)
                    RailNavRow(title: "Worktrees", symbol: "arrow.triangle.branch", destination: .worktrees)
                }

                if !model.needsYou.isEmpty {
                    RailGroup(title: "Needs you") {
                        ForEach(model.needsYou) { s in RailChatRow(session: s) }
                    }
                }

                ForEach(model.projects) { project in
                    RailProjectGroup(project: project)
                }

                let scratch = model.sessions(in: nil)
                if !scratch.isEmpty {
                    RailGroup(title: "Scratch") {
                        ForEach(scratch) { s in RailChatRow(session: s) }
                    }
                }

                RailFooter()
                    .padding(.top, Rail.groupGap)
            }
            .padding(.horizontal, Rail.inset)
            .padding(.top, 6)
            .padding(.bottom, Space.lg)
        }
        .scrollIndicators(.automatic)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { step(1) }
        .onKeyPress(.upArrow) { step(-1) }
        .toolbar {
            ToolbarItem {
                Button { model.showNewChat(in: model.selectedSession?.projectId ?? model.projects.first?.id) } label: {
                    Image(systemName: "square.and.pencil")
                }
                .help("New chat (⌘N)")
            }
        }
    }

    /// Arrow keys walk the chats in the order the rail shows them.
    private func step(_ delta: Int) -> KeyPress.Result {
        let order = model.needsYou.map(\.id) + model.projects.flatMap { p in
            model.collapsedProjects.contains(p.id) ? [] : model.sessions(in: p.id).map(\.id)
        } + model.sessions(in: nil).map(\.id)
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
    static let groupGap: CGFloat = 16
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
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(selected ? Color.btText : Color.btTextSecondary)
                    .frame(width: Rail.iconColumn)
                Text(title)
                    .font(.system(size: 13))
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

/// A group header plus its rows.
private struct RailGroup<Content: View>: View {
    let title: String
    var trailing: AnyView? = nil
    var onTitleTap: (() -> Void)? = nil
    var collapsed = false
    @ViewBuilder var content: () -> Content
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Button { onTitleTap?() } label: {
                    HStack(spacing: 4) {
                        Text(title)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Color.btTextTertiary)
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
                trailing
            }
            .padding(.leading, Rail.rowPadding)
            .padding(.trailing, 2)
            .frame(height: 26)
            .onHover { hovering = $0 }

            if !collapsed { content() }
        }
        .padding(.top, Rail.groupGap)
        .animation(.snappy(duration: 0.2), value: collapsed)
    }
}

private struct RailProjectGroup: View {
    @Environment(AppModel.self) private var model
    let project: Project

    var body: some View {
        let chats = model.sessions(in: project.id)
        let collapsed = model.collapsedProjects.contains(project.id)
        RailGroup(
            title: project.name,
            trailing: AnyView(
                Button { model.showNewChat(in: project.id) } label: { Image(systemName: "plus") }
                    .buttonStyle(RailIconStyle())
                    .help("New chat in \(project.name)")
            ),
            onTitleTap: {
                if collapsed { model.collapsedProjects.remove(project.id) } else { model.collapsedProjects.insert(project.id) }
            },
            collapsed: collapsed
        ) {
            if chats.isEmpty {
                Button { model.showNewChat(in: project.id) } label: {
                    Text("Start a chat")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.btTextTertiary)
                        .padding(.leading, Rail.rowPadding + Rail.chatIndent + Rail.iconColumn + 8)
                        .frame(maxWidth: .infinity, minHeight: Rail.rowHeight, alignment: .leading)
                }
                .buttonStyle(RailRowStyle(selected: false))
            }
            ForEach(chats) { s in RailChatRow(session: s) }
        }
        .contextMenu {
            Button("New Chat") { model.showNewChat(in: project.id) }
            Button("Show Worktrees") { model.destination = .worktrees }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.rootPath)]) }
            Divider()
            Button("Remove Project…", role: .destructive) { confirmRemove() }
        }
    }

    private func confirmRemove() {
        let alert = NSAlert()
        alert.messageText = "Remove \(project.name) from Backtick?"
        alert.informativeText = "Its chats are removed from Backtick. The repository and any worktrees on disk are left alone."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { model.removeProject(project.id) }
    }
}

struct RailChatRow: View {
    @Environment(AppModel.self) private var model
    let session: Session
    var showProject = false
    @State private var renaming = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let selected = model.selectedSession?.id == session.id
        Button { model.open(session.id) } label: {
            HStack(spacing: 8) {
                RailStatus(status: session.status)
                    .frame(width: Rail.iconColumn)
                if renaming {
                    TextField("Name", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($fieldFocused)
                        .onAppear { fieldFocused = true }
                        .onSubmit(commitRename)
                        .onExitCommand { renaming = false }
                } else {
                    Text(session.name)
                        .font(.system(size: 13))
                        .foregroundStyle(selected ? Color.btText : Color.btText.opacity(0.86))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
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
        .help(tooltip)
        .simultaneousGesture(TapGesture(count: 2).onEnded { draft = session.name; renaming = true })
        .contextMenu {
            Button("Rename") { draft = session.name; renaming = true }
            Button(session.archivedAt == nil ? "Archive" : "Unarchive") { model.setArchived(session.id, session.archivedAt == nil) }
            if let path = session.worktreePath {
                Button("Reveal Worktree in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            }
            Divider()
            Button("Delete Chat and Worktree…", role: .destructive) { confirmDelete() }
        }
    }

    private var tooltip: String {
        [session.status.label, model.project(session.projectId)?.name, ProviderRegistry.name(session.providerId),
         RelativeTime.short(session.lastEventAt ?? session.createdAt)]
            .compactMap { $0 }.joined(separator: " · ")
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
    @State private var spin = false

    var body: some View {
        ZStack {
            switch status {
            case .running, .provisioning:
                Circle().stroke(Color.btTextTertiary.opacity(0.35), lineWidth: 1.5)
                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .onAppear { withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { spin = true } }
            case .waitingInput:
                Circle().fill(Color.btAttention)
            case .errored:
                Circle().fill(Color.btRemoved)
            case .idle:
                Circle().stroke(Color.btAdded, lineWidth: 1.5)
            case .finished, .created:
                Circle().stroke(Color.btTextTertiary, lineWidth: 1.5)
            }
        }
        .frame(width: 9, height: 9)
        .accessibilityLabel(status.label)
    }
}

private struct RailFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Space.md) {
            Button { model.isAddingProject = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus").font(.system(size: 12)).frame(width: Rail.iconColumn)
                    Text("Add project").font(.system(size: 13))
                }
                .foregroundStyle(Color.btTextTertiary)
                .padding(.horizontal, Rail.rowPadding)
                .frame(height: Rail.rowHeight)
            }
            .buttonStyle(RailRowStyle(selected: false))
            Spacer()
            if model.sessions.contains(where: { $0.archivedAt != nil }) {
                Button(model.showArchived ? "Hide archived" : "Show archived") { model.showArchived.toggle() }
                    .buttonStyle(.plain)
                    .font(.btCaption)
                    .foregroundStyle(Color.btTextTertiary)
                    .padding(.trailing, Rail.rowPadding)
            }
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
private struct RailIconStyle: ButtonStyle {
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
