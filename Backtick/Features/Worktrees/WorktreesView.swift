import SwiftUI
import AppKit
import BacktickCore

/// Every worktree of a project: the main tree where accepted changes land,
/// the ones chats work in, and leftovers nothing uses any more.
struct WorktreesView: View {
    @Environment(AppModel.self) private var model
    @State private var list = WorktreeList()
    @State private var projectId: String?
    @State private var removing: WorktreeEntry?

    private var project: Project? { model.project(projectId) ?? model.projects.first }

    var body: some View {
        Group {
            if let project {
                content(project)
            } else {
                EmptyStateView(symbol: "arrow.triangle.branch", title: "No projects yet",
                               message: "Add a git repository and every chat gets its own worktree, listed here.",
                               action: ("Add a Project", { model.isAddingProject = true }))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.btCanvas)
        .navigationTitle("Worktrees")
        .task(id: project?.id) { await reload() }
        .onChange(of: model.sessions.map(\.id)) { Task { await reload() } }
        .sheet(item: $removing) { entry in
            RemoveWorktreeSheet(entry: entry, isAlive: entry.session.map { model.isAlive($0.id) } ?? false,
                                onCancel: { removing = nil },
                                onRemove: { deleteBranch in
                                    removing = nil
                                    guard let project else { return }
                                    Task { await list.remove(entry, deleteBranch: deleteBranch, project: project, model: model) }
                                })
        }
    }

    private func reload() async {
        guard let project else { return }
        await list.load(project, model: model)
    }

    @ViewBuilder
    private func content(_ project: Project) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                header(project)
                switch list.phase {
                case .idle, .loading:
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(.top, Space.xxl)
                case .failed(let message):
                    EmptyStateView(symbol: "exclamationmark.triangle", title: "Couldn't list worktrees", message: message,
                                   action: ("Try Again", { Task { await reload() } }))
                case .loaded:
                    sections(project)
                }
            }
            .padding(.horizontal, Space.xxl)
            .padding(.vertical, Space.xl)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
        }
    }

    private func header(_ project: Project) -> some View {
        HStack(spacing: Space.md) {
            projectPicker
            Spacer(minLength: Space.md)
            if list.isBusy || (list.phase == .loading && list.loadedProjectId != nil) {
                ProgressView().controlSize(.small).scaleEffect(0.8)
            }
            Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.icon)
                .keyboardShortcut("r", modifiers: .command)
                .help("Refresh (⌘R)")
            Button { Task { await list.prune(project, model: model) } } label: {
                Label("Prune", systemImage: "scissors")
            }
            .buttonStyle(.bt(.secondary, size: .small))
            .disabled(list.isBusy)
            .help("Forget worktrees whose folders were deleted outside git (git worktree prune)")
        }
    }

    @ViewBuilder
    private var projectPicker: some View {
        let selection = Binding<String?>(get: { project?.id }, set: { projectId = $0 })
        if model.projects.count <= 4 {
            Picker("Project", selection: selection) {
                ForEach(model.projects) { p in Text(p.name).tag(Optional(p.id)) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        } else {
            Picker("Project", selection: selection) {
                ForEach(model.projects) { p in Text(p.name).tag(Optional(p.id)) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
    }

    @ViewBuilder
    private func sections(_ project: Project) -> some View {
        if let main = list.main {
            WorktreeSection(title: "Main working tree") {
                WorktreeRow(entry: main, onRemove: nil)
            }
        }

        WorktreeSection(title: "Chat worktrees", count: list.chats.count) {
            if list.chats.isEmpty {
                Text("No chat has a worktree in \(project.name) yet. Start one and it gets its own.")
                    .font(.btCallout)
                    .foregroundStyle(Color.btTextSecondary)
                    .padding(.vertical, Space.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(Array(list.chats.enumerated()), id: \.element.id) { i, entry in
                    if i > 0 { WorktreeDivider() }
                    WorktreeRow(entry: entry, onRemove: { removing = entry })
                }
            }
        }

        if !list.abandoned.isEmpty {
            WorktreeSection(title: "Abandoned", count: list.abandoned.count, warning: true,
                            note: "No chat uses these. They're left over from deleted chats, or ones made outside Backtick; remove them to reclaim the disk space.") {
                ForEach(Array(list.abandoned.enumerated()), id: \.element.id) { i, entry in
                    if i > 0 { WorktreeDivider() }
                    WorktreeRow(entry: entry, onRemove: { removing = entry })
                }
            }
        }
    }
}

// MARK: - Sections and rows

private struct WorktreeSection<Content: View>: View {
    let title: String
    var count: Int? = nil
    var warning = false
    var note: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if warning {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.btWarning)
                }
                Text(title)
                    .font(.btSectionLabel)
                    .foregroundStyle(warning ? Color.btWarning : Color.btTextTertiary)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.btSectionLabel)
                        .foregroundStyle(Color.btTextTertiary)
                        .monospacedDigit()
                }
            }
            .padding(.bottom, note == nil ? Space.sm : Space.xs)
            if let note {
                Text(note)
                    .font(.btCallout)
                    .foregroundStyle(Color.btTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, Space.sm)
            }
            Hairline()
            content()
        }
    }
}

/// Between rows, inset to line up with the row text.
private struct WorktreeDivider: View {
    var body: some View { Hairline().padding(.leading, WorktreeRow.textInset) }
}

private struct WorktreeRow: View {
    /// Icon column plus spacing: where titles start.
    static let textInset: CGFloat = 24 + Space.md
    @Environment(AppModel.self) private var model
    let entry: WorktreeEntry
    let onRemove: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Space.md) {
            icon
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Space.sm) {
                    title
                    tags
                }
                subtitle
            }
            Spacer(minLength: Space.md)
            HStack(spacing: 2) {
                Button(action: reveal) { Image(systemName: "folder") }
                    .buttonStyle(.icon)
                    .disabled(!entry.exists)
                    .help(entry.exists ? "Reveal in Finder" : "The folder no longer exists")
                if let onRemove {
                    Button(action: onRemove) { Image(systemName: "trash") }
                        .buttonStyle(.icon)
                        .help("Remove worktree…")
                }
            }
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
            trailing
        }
        .padding(.vertical, 10)
        .frame(minHeight: 58)
        .background {
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .fill(hovering ? Color.btHover : .clear)
                .padding(.horizontal, -Space.sm)
                .padding(.vertical, 2)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.12), value: hovering)
        .contextMenu {
            Button("Reveal in Finder", action: reveal).disabled(!entry.exists)
            Button("Copy Path") { copy(entry.path) }
            if let branch = entry.info.branch { Button("Copy Branch Name") { copy(branch) } }
            if let s = entry.session {
                Divider()
                Button("Open Chat") { model.open(s.id) }
            }
            if let onRemove {
                Divider()
                Button("Remove Worktree…", action: onRemove)
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        Group {
            switch entry.kind {
            case .main:
                Image(systemName: "house").foregroundStyle(Color.accentColor)
            case .chat(let s):
                ProviderLogo(providerId: s.providerId, size: 17)
            case .abandoned:
                Image(systemName: "arrow.triangle.branch").foregroundStyle(Color.btWarning)
            }
        }
        .font(.system(size: 14, weight: .regular))
        .frame(width: 24)
    }

    @ViewBuilder
    private var title: some View {
        switch entry.kind {
        case .main, .abandoned:
            Text(entry.refLabel)
                .font(.btMono.weight(.medium))
                .foregroundStyle(Color.btText)
                .lineLimit(1)
                .truncationMode(.middle)
        case .chat(let s):
            Text(s.name)
                .font(.btBodyMedium)
                .foregroundStyle(Color.btText)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var tags: some View {
        if case .chat(let s) = entry.kind {
            HStack(spacing: 5) {
                StatusDot(status: s.status, size: 6)
                Text(s.status.label).font(.btCaption).foregroundStyle(Color.btTextSecondary)
            }
            .fixedSize()
            if s.archivedAt != nil { WorktreeNote(text: "Archived", tint: .btTextTertiary) }
        }
        if !entry.exists { WorktreeNote(text: "Folder missing", tint: .btWarning) }
        if entry.info.isLocked {
            Image(systemName: "lock.fill")
                .font(.system(size: 10))
                .foregroundStyle(Color.btTextTertiary)
                .help("Locked — git won't prune or move it")
        }
    }

    @ViewBuilder
    private var subtitle: some View {
        HStack(spacing: 6) {
            if case .chat = entry.kind {
                Text(entry.refLabel)
                    .foregroundStyle(Color.btTextSecondary)
                    .lineLimit(1)
                    .layoutPriority(1)
                Text("·").foregroundStyle(Color.btTextTertiary)
            }
            Text(Self.abbreviate(entry.path))
                .foregroundStyle(Color.btTextTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(entry.path)
        }
        .font(.btMonoSmall)
    }

    @ViewBuilder
    private var trailing: some View {
        switch entry.kind {
        case .main:
            Label("Accepted changes land here", systemImage: "arrow.down.to.line")
                .font(.btCaption)
                .foregroundStyle(Color.btTextSecondary)
                .labelStyle(.titleAndIcon)
                .fixedSize()
        case .chat(let s):
            Button("Open Chat") { model.open(s.id) }
                .buttonStyle(.bt(.secondary, size: .small))
                .fixedSize()
        case .abandoned:
            EmptyView()
        }
    }

    private func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        model.flash("Copied")
    }

    static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

/// A short coloured note beside a title, in place of a pill.
private struct WorktreeNote: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.btCaptionMedium)
            .foregroundStyle(tint)
            .fixedSize()
    }
}

// MARK: - Remove sheet

private struct RemoveWorktreeSheet: View {
    let entry: WorktreeEntry
    let isAlive: Bool
    let onCancel: () -> Void
    let onRemove: (Bool) -> Void
    @State private var deleteBranch = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            HStack(alignment: .top, spacing: Space.md) {
                Image(systemName: "trash")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(Color.btRemoved)
                    .frame(width: 24)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Remove this worktree?").font(.btHeadline).foregroundStyle(Color.btText)
                    Text("Backtick deletes the folder below. Anything uncommitted in it is lost; commits stay on the branch unless you delete it too.")
                        .font(.btCallout)
                        .foregroundStyle(Color.btTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text(entry.path)
                .font(.btMonoSmall)
                .foregroundStyle(Color.btTextSecondary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 24 + Space.md)

            if let s = entry.session {
                Notice(text: isAlive
                       ? "“\(s.name)” is still running here. Its agent is stopped first, and the chat can't run again without a worktree."
                       : "The chat “\(s.name)” stays in the sidebar, but it can't run again without a worktree.")
            }

            if let branch = entry.info.branch {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: $deleteBranch) {
                        HStack(spacing: 4) {
                            Text("Also delete branch")
                            Text(branch).font(.btMono).foregroundStyle(Color.btText)
                        }
                        .font(.btBody)
                    }
                    .toggleStyle(.checkbox)
                    Text("Commits only on that branch are lost with it.")
                        .font(.btCaption)
                        .foregroundStyle(Color.btTextTertiary)
                        .padding(.leading, 20)
                }
            }

            HStack(spacing: Space.sm) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.btSecondary)
                    .keyboardShortcut(.cancelAction)
                Button(deleteBranch ? "Remove Worktree and Branch" : "Remove Worktree") { onRemove(deleteBranch) }
                    .buttonStyle(.btDanger)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.xl)
        .frame(width: 480)
        .background(Color.btCanvas)
    }
}
