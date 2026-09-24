import SwiftUI
import AbstractCore

/// Under the last answer: what the chat has changed in its worktree, file by
/// file, each one click from its diff. It reads the worktree itself, so it
/// works the same whether the agent edited with tools (Claude) or through
/// shell commands (Codex).
struct ChatChangesSummary: View {
    @Environment(AppModel.self) private var model
    let session: Session
    /// Changes whenever a turn ends, so the list is re-read then.
    let turnKey: Int
    @State private var files: [FileDiff] = []

    var body: some View {
        // A VStack, not a Group: a Group's modifiers go to its children, and
        // with no files there are none, so the task would never run.
        VStack(alignment: .leading, spacing: 0) {
            // The Changes pane already lists them when it's open.
            if !files.isEmpty, !model.layout(for: session.id).isShowing(.changes) { content }
        }
        .task(id: "\(turnKey)-\(session.status.rawValue)") { await load() }
    }

    private var content: some View {
        let additions = files.reduce(0) { $0 + $1.additions }
        let deletions = files.reduce(0) { $0 + $1.deletions }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("\(files.count) file\(files.count == 1 ? "" : "s") changed")
                    .font(.btChatToolMedium)
                    .foregroundStyle(Color.btTextSecondary)
                DiffCounts(additions: additions, deletions: deletions, hideZeros: true)
                Spacer(minLength: Space.md)
                Button("Review") { model.openDiffTab(in: session.id) }
                    .buttonStyle(.bt(.ghost, size: .small))
                    .help("Open the Changes pane to accept or reject")
            }
            .frame(minHeight: 28)

            ForEach(files.prefix(8)) { file in
                ChangedFileRow(file: file) { model.showChanges(file.path, in: session.id) }
            }
            if files.count > 8 {
                Text("and \(files.count - 8) more")
                    .font(.btChatCaption)
                    .foregroundStyle(Color.btTextTertiary)
                    .padding(.top, 4)
            }
        }
    }

    private func load() async {
        guard !(session.status == .running || session.status == .provisioning),
              case .ready(let context) = model.diffAvailability(session.id) else { return }
        let collected = (try? await Diff.collect(context.executor, worktree: context.worktree, exclude: context.exclude)) ?? []
        withAnimation(.snappy(duration: 0.2)) { files = collected }
    }
}

private struct ChangedFileRow: View {
    let file: FileDiff
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.sm) {
                DiffStatusLetter(status: file.status, size: 10)
                Text((file.path as NSString).lastPathComponent)
                    .font(.btChatTool)
                    .foregroundStyle(hovering ? Color.btText : Color.btText.opacity(0.9))
                    .lineLimit(1)
                let folder = (file.path as NSString).deletingLastPathComponent
                if !folder.isEmpty {
                    Text(folder).font(.btChatCaption).foregroundStyle(Color.btTextTertiary).lineLimit(1).truncationMode(.head)
                }
                if !file.isBinary { DiffCounts(additions: file.additions, deletions: file.deletions, hideZeros: true) }
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.btTextTertiary)
                    .opacity(hovering ? 1 : 0)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Show \(file.path) in Changes")
    }
}
