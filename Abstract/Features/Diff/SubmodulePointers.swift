import SwiftUI
import AbstractCore

extension PointerChange {
    /// How the pointer moved, in the parent's terms: "pointer +2, not
    /// committed", "pointer −1", a submodule added or removed.
    var summary: String {
        if from == nil { return "new submodule" }
        if to == nil { return "submodule removed" }
        let moves = [ahead > 0 ? "+\(ahead)" : nil, behind > 0 ? "−\(behind)" : nil].compactMap { $0 }
        let moved = moves.isEmpty ? "pointer moved" : "pointer " + moves.joined(separator: " ")
        return isCommitted ? moved : moved + ", not committed"
    }
}

/// Which repository the review shows: the worktree's own, or one of its
/// submodules, each reviewed on its own, and which ones have uncommitted work.
struct RepoMenu: View {
    @Environment(AppModel.self) private var model
    let review: DiffReview
    let context: DiffContext

    var body: some View {
        Menu {
            ForEach(review.repoList) { repo in
                Button { model.selectRepo(context.sessionId, repo.path) } label: {
                    Image(systemName: repo.isSubmodule ? "shippingbox" : "folder")
                    Text(name(repo))
                    let notes = [repo.path == review.selectedRepo ? "Showing" : nil,
                                 review.changedRepos.contains(repo.path) ? "Uncommitted changes" : nil].compactMap { $0 }
                    if !notes.isEmpty { Text(notes.joined(separator: " · ")) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: review.selected.isSubmodule ? "shippingbox" : "folder")
                    .font(.system(size: 11)).foregroundStyle(Color.btTextSecondary)
                Text(name(review.selected)).font(BTFont.ui(13, .medium)).foregroundStyle(Color.btText)
                    .lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Color.btTextTertiary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .help("Which repository's changes to show")
    }

    private func name(_ repo: ChatRepo) -> String { repo.isSubmodule ? repo.path : context.projectName }
}

/// Under the toolbar while a submodule you can't push to is shown.
struct RepoAccessNotice: View {
    @Environment(AppModel.self) private var model
    let repo: ChatRepo
    @State private var access: RepoAccess = .unknown

    var body: some View {
        Group {
            if access == .readOnly, let slug = repo.github {
                Label { Text("You can't push to \(slug). These changes stay local.") } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .font(.btCaption)
                .foregroundStyle(Color.btTextSecondary)
                .padding(.horizontal, Space.md)
                .padding(.vertical, Space.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: repo.github) {
            access = .unknown
            guard let slug = repo.github else { return }
            access = await model.access(to: slug)
        }
    }
}

/// A submodule whose pointer the shown changes move, before the files: one
/// change of this repository's. Choosing it shows that submodule.
struct PointerRow: View {
    let pointer: PointerChange
    /// Checked out in this worktree, so there's a review of it to switch to.
    let canOpen: Bool
    var depth: CGFloat = 0
    let onOpen: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 6) {
                Color.clear.frame(width: 10)
                Image(systemName: "shippingbox").font(.system(size: 11)).foregroundStyle(Color.btTextSecondary).frame(width: 16)
                Text(pointer.repo.path).font(BTFont.ui(12.5)).foregroundStyle(hovering && canOpen ? Color.btText : Color.btProse)
                    .lineLimit(1).truncationMode(.middle)
                Text(pointer.summary).font(.btCaption).foregroundStyle(Color.btTextTertiary).lineLimit(1)
                Spacer(minLength: 6)
                if canOpen {
                    Image(systemName: "arrow.right").font(.system(size: 9, weight: .medium)).foregroundStyle(Color.btTextTertiary)
                }
            }
            .padding(.leading, 8 + depth * 12)
            .padding(.trailing, Space.sm)
            .frame(height: 26)
            .background(hovering && canOpen ? Color.btHover : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canOpen)
        .onHover { hovering = $0 }
        .help(canOpen ? "Show \(pointer.repo.path)'s changes" : "\(pointer.repo.path) isn't checked out in this worktree")
    }
}
