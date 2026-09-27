import SwiftUI
import AbstractCore

/// The changed files as a tree, after Paseo's (Apache-2.0, Copyright (c)
/// 2025-present Mohamed Boudra): folders first, a folder holding only one
/// folder merged into it (`Sources/App/Chat`), each folder with its files'
/// totals. Choosing a file shows it in the diff. A submodule's folder also
/// holds the commits its parent hasn't recorded; choosing one shows it.
struct ChangesTree: View {
    let review: DiffReview
    let onOpen: (String) -> Void
    let onCommit: (CommitSummary) -> Void
    @State private var collapsed: Set<String> = []

    var body: some View {
        let submodules = Dictionary(uniqueKeysWithValues: review.repos.filter(\.repo.isSubmodule).map { ($0.repo.path, $0) })
        let rows = ChangesTreeRow.flatten(ChangesTreeRow.standalone(review.sections)
                                          + ChangesTreeRow.build(review.files, repos: submodules), collapsed: collapsed)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    TreeRowView(row: row, collapsed: collapsed.contains(row.id), selected: isSelected(row)) {
                        switch row.kind {
                        case .folder where row.foldable:
                            if collapsed.contains(row.id) { collapsed.remove(row.id) } else { collapsed.insert(row.id) }
                        case .folder, .file:
                            onOpen(row.path)
                        case .commit(let commit):
                            onCommit(commit)
                        }
                    }
                }
            }
            .padding(.vertical, Space.xs)
        }
        .background(Color.btCanvas)
    }

    private func isSelected(_ row: ChangesTreeRow) -> Bool {
        if case .commit(let commit) = row.kind {
            if case .commit(let shown) = review.mode { return shown.id == commit.id }
            return false
        }
        return row.path == review.focusPath
    }
}

struct ChangesTreeRow: Identifiable {
    enum Kind { case folder, file(FileDiff.FileStatus), commit(CommitSummary) }
    let kind: Kind
    /// For a file its path; for a folder its path with a trailing slash.
    let id: String
    let path: String
    let name: String
    let depth: Int
    let additions: Int
    let deletions: Int
    var children: [ChangesTreeRow] = []
    /// A submodule's folder.
    var isRepo = false
    /// What a submodule's folder says besides its files ("pointer +2, not committed").
    var note: String?
    /// Has rows under it to show or hide; kept once `flatten` drops `children`.
    var foldable = false

    /// Submodules with no files to list but something to say, first: their
    /// unrecorded commits, or why they couldn't be read.
    static func standalone(_ sections: [DiffReview.RepoSection]) -> [ChangesTreeRow] {
        sections.compactMap { section in
            let diff = section.diff
            guard diff.repo.isSubmodule, section.files.isEmpty,
                  let note = diff.note(committedIn: nil) ?? (diff.error != nil ? "couldn't be read" : nil) else { return nil }
            let commits = commitRows(diff, depth: 1)
            return ChangesTreeRow(kind: .folder, id: diff.repo.path + "/", path: diff.repo.path, name: diff.repo.path,
                                  depth: 0, additions: 0, deletions: 0, children: commits, isRepo: true, note: note,
                                  foldable: !commits.isEmpty)
        }
    }

    /// A submodule's commits its parent hasn't recorded, as rows at `depth`.
    static func commitRows(_ diff: RepoDiff, depth: Int) -> [ChangesTreeRow] {
        diff.unrecorded.map { commit in
            ChangesTreeRow(kind: .commit(commit), id: "commit:" + commit.id, path: diff.repo.path, name: commit.subject,
                           depth: depth, additions: 0, deletions: 0)
        }
    }

    /// Folders before files, each in plain character order; `repos` are the
    /// submodules, by path.
    static func build(_ files: [ReviewFile], repos: [String: RepoDiff] = [:]) -> [ChangesTreeRow] {
        final class Folder {
            var folders: [String: Folder] = [:]
            var files: [ReviewFile] = []
        }
        let root = Folder()
        for file in files {
            var folder = root
            for part in file.directory.split(separator: "/").map(String.init) {
                if folder.folders[part] == nil { folder.folders[part] = Folder() }
                folder = folder.folders[part]!
            }
            folder.files.append(file)
        }
        func rows(_ folder: Folder, prefix: String, depth: Int) -> [ChangesTreeRow] {
            var out: [ChangesTreeRow] = []
            for name in folder.folders.keys.sorted() {
                var child = folder.folders[name]!
                var label = name
                var path = prefix + name
                // A folder whose only content is one folder reads as one row.
                // …but never through a submodule, whose folder is its own row.
                while repos[path] == nil, child.files.isEmpty, child.folders.count == 1, let (next, grandchild) = child.folders.first {
                    label += "/" + next
                    path += "/" + next
                    child = grandchild
                }
                let inner = rows(child, prefix: path + "/", depth: depth + 1)
                let adds = inner.reduce(0) { $0 + $1.additions }
                let dels = inner.reduce(0) { $0 + $1.deletions }
                let repo = repos[path]
                let children = inner + (repo.map { commitRows($0, depth: depth + 1) } ?? [])
                out.append(ChangesTreeRow(kind: .folder, id: path + "/", path: path, name: label, depth: depth,
                                          additions: adds, deletions: dels, children: children, isRepo: repo != nil,
                                          note: repo?.note(committedIn: nil), foldable: !children.isEmpty))
            }
            for file in folder.files.sorted(by: { $0.name < $1.name }) {
                out.append(ChangesTreeRow(kind: .file(file.diff.status), id: file.path, path: file.path, name: file.name, depth: depth,
                                          additions: file.diff.additions, deletions: file.diff.deletions))
            }
            return out
        }
        return rows(root, prefix: "", depth: 0)
    }

    static func flatten(_ rows: [ChangesTreeRow], collapsed: Set<String>) -> [ChangesTreeRow] {
        rows.flatMap { row -> [ChangesTreeRow] in
            var own = row
            own.children = []
            guard row.foldable, !collapsed.contains(row.id) else { return [own] }
            return [own] + flatten(row.children, collapsed: collapsed)
        }
    }
}

private struct TreeRowView: View {
    let row: ChangesTreeRow
    let collapsed: Bool
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                switch row.kind {
                case .folder:
                    if row.foldable {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color.btTextTertiary)
                            .rotationEffect(.degrees(collapsed ? 0 : 90))
                            .frame(width: 10)
                    } else {
                        Color.clear.frame(width: 10)
                    }
                    if row.isRepo {
                        Image(systemName: "shippingbox").font(.system(size: 11)).foregroundStyle(Color.btTextSecondary).frame(width: 16)
                    } else {
                        FileIcon(path: row.path, isDirectory: true, open: !collapsed)
                    }
                    Text(row.name).font(BTFont.ui(12.5)).foregroundStyle(Color.btTextSecondary).lineLimit(1).truncationMode(.middle)
                    if let note = row.note {
                        Text(note).font(.btCaption).foregroundStyle(Color.btTextTertiary).lineLimit(1)
                    }
                case .commit:
                    Color.clear.frame(width: 10)
                    Image(nsImage: Octicon.gitCommit).renderingMode(.template).resizable().frame(width: 12, height: 12)
                        .foregroundStyle(Color.btTextTertiary).frame(width: 16)
                    Text(row.name).font(BTFont.ui(12.5)).foregroundStyle(selected || hovering ? Color.btText : Color.btProse)
                        .lineLimit(1).truncationMode(.tail)
                case .file:
                    Color.clear.frame(width: 10)
                    FileIcon(path: row.path)
                    Text(row.name).font(BTFont.ui(12.5)).foregroundStyle(selected || hovering ? Color.btText : Color.btProse)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 6)
                switch row.kind {
                case .commit(let commit):
                    Text(commit.shortSha).font(.btMonoSmall).foregroundStyle(Color.btTextTertiary).fixedSize()
                case .file(let status):
                    DiffCounts(additions: row.additions, deletions: row.deletions, hideZeros: true, compact: true).fixedSize()
                    DiffStatusIcon(status: status)
                case .folder:
                    DiffCounts(additions: row.additions, deletions: row.deletions, hideZeros: true, compact: true).fixedSize()
                }
            }
            .padding(.leading, 8 + CGFloat(row.depth) * 12)
            .padding(.trailing, Space.sm)
            .frame(height: 26)
            .background(selected ? Color.btSelection : hovering ? Color.btHover : .clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }

    private var help: String {
        if case .commit(let commit) = row.kind { return "\(commit.shortSha) · \(commit.author) · show this commit" }
        return row.isRepo ? "Submodule \(row.path)" : row.path
    }
}
