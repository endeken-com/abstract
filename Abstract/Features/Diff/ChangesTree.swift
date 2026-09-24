import SwiftUI
import AbstractCore

/// The changed files as a tree, after Paseo's (Apache-2.0, Copyright (c)
/// 2025-present Mohamed Boudra): folders first, a folder holding only one
/// folder merged into it (`Sources/App/Chat`), each folder with its files'
/// totals. Choosing a file shows it in the diff.
struct ChangesTree: View {
    let review: DiffReview
    let onOpen: (String) -> Void
    @State private var collapsed: Set<String> = []

    var body: some View {
        let rows = ChangesTreeRow.flatten(ChangesTreeRow.build(review.files), collapsed: collapsed)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    TreeRowView(row: row, collapsed: collapsed.contains(row.id), selected: row.path == review.focusPath) {
                        switch row.kind {
                        case .folder:
                            if collapsed.contains(row.id) { collapsed.remove(row.id) } else { collapsed.insert(row.id) }
                        case .file:
                            onOpen(row.path)
                        }
                    }
                }
            }
            .padding(.vertical, Space.xs)
        }
        .background(Color.btCanvas)
    }
}

struct ChangesTreeRow: Identifiable {
    enum Kind { case folder, file(FileDiff.FileStatus) }
    let kind: Kind
    /// For a file its path; for a folder its path with a trailing slash.
    let id: String
    let path: String
    let name: String
    let depth: Int
    let additions: Int
    let deletions: Int
    var children: [ChangesTreeRow] = []

    /// Folders before files, each in plain character order.
    static func build(_ files: [ReviewFile]) -> [ChangesTreeRow] {
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
                while child.files.isEmpty, child.folders.count == 1, let (next, grandchild) = child.folders.first {
                    label += "/" + next
                    path += "/" + next
                    child = grandchild
                }
                let inner = rows(child, prefix: path + "/", depth: depth + 1)
                let adds = inner.reduce(0) { $0 + $1.additions }
                let dels = inner.reduce(0) { $0 + $1.deletions }
                out.append(ChangesTreeRow(kind: .folder, id: path + "/", path: path, name: label, depth: depth,
                                          additions: adds, deletions: dels, children: inner))
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
            guard case .folder = row.kind, !collapsed.contains(row.id) else { return [own] }
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
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.btTextTertiary)
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                        .frame(width: 10)
                    FileIcon(path: row.path, isDirectory: true, open: !collapsed)
                    Text(row.name).font(BTFont.ui(12.5)).foregroundStyle(Color.btTextSecondary).lineLimit(1).truncationMode(.middle)
                case .file:
                    Color.clear.frame(width: 10)
                    FileIcon(path: row.path)
                    Text(row.name).font(BTFont.ui(12.5)).foregroundStyle(selected || hovering ? Color.btText : Color.btProse)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 6)
                DiffCounts(additions: row.additions, deletions: row.deletions, hideZeros: true, compact: true).fixedSize()
                if case .file(let status) = row.kind { DiffStatusIcon(status: status) }
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
        .help(row.path)
    }
}
