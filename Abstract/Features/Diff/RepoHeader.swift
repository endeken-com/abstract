import SwiftUI
import AbstractCore

/// A repository's heading in the review, once the changes reach into a
/// submodule: where it is, its branch, how far the chat moved it, its totals,
/// and whether you can push to it. Clicking folds its files away.
struct RepoHeader: View {
    @Environment(AppModel.self) private var model
    let section: DiffReview.RepoSection
    /// The project's name for the worktree's own repository, else the submodule's path.
    let title: String
    /// Where its pointer is committed: the project's name for a top-level
    /// submodule, else its parent's path.
    let parent: String
    let collapsed: Bool
    let onToggle: () -> Void
    @State private var access: RepoAccess = .unknown

    private var repo: ChatRepo { section.diff.repo }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: Space.sm) {
                    // Nothing under it to fold, so no arrow.
                    if section.files.isEmpty {
                        Color.clear.frame(width: 10)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color.btTextTertiary)
                            .rotationEffect(.degrees(collapsed ? 0 : 90))
                            .frame(width: 10)
                    }
                    Text(title).font(BTFont.ui(13, .medium)).foregroundStyle(Color.btText).lineLimit(1).truncationMode(.middle)
                    if access == .readOnly {
                        Text("read-only").font(.btCaption).foregroundStyle(Color.btTextSecondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.btHover, in: Capsule())
                    }
                    Text(repo.branch ?? "detached").font(.btMonoSmall).foregroundStyle(Color.btTextTertiary).lineLimit(1)
                    if let note = section.diff.note(committedIn: parent) {
                        Text(note).font(.btCaption).foregroundStyle(Color.btTextTertiary).lineLimit(1)
                    }
                    Spacer(minLength: Space.sm)
                    DiffCounts(additions: section.files.reduce(0) { $0 + $1.diff.additions },
                               deletions: section.files.reduce(0) { $0 + $1.diff.deletions }, hideZeros: true, compact: true)
                        .fixedSize()
                }
                .padding(.horizontal, Space.md)
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if access == .readOnly, let slug = repo.github {
                warning("You can't push to \(slug). These changes stay local.")
            }
            if let error = section.diff.error {
                warning("Couldn't read \(repo.path): \(error)")
            }
        }
        .background(Color.btCanvas)
        .overlay(alignment: .top) { Hairline() }
        .task(id: repo.github) {
            guard let slug = repo.github else { return }
            access = await model.access(to: slug)
        }
    }

    private func warning(_ text: String) -> some View {
        Label { Text(text) } icon: { Image(systemName: "exclamationmark.triangle") }
            .font(.btCaption)
            .foregroundStyle(Color.btTextSecondary)
            .padding(.horizontal, Space.md)
            .padding(.bottom, Space.sm)
    }
}

extension RepoDiff {
    /// What a submodule's heading says besides its files: new, or how far
    /// its pointer moved and whether `parent` has committed that yet.
    func note(committedIn parent: String?) -> String? {
        if isNew { return "new submodule" }
        if pointerUncommitted {
            return (ahead > 0 ? "pointer +\(ahead)" : "pointer moved") + ", not committed" + (parent.map { " in \($0)" } ?? "")
        }
        return ahead > 0 ? "pointer +\(ahead) commit\(ahead == 1 ? "" : "s")" : nil
    }
}
