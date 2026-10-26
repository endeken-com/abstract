import SwiftUI
import AbstractCore

/// ⇧⌘F in the Files pane: what's inside the worktree's files, found with
/// `git grep` where the chat runs, grouped by file.
@Observable
final class FileContentSearch {
    enum Phase: Equatable { case idle, searching, done, failed(String) }

    /// A file heading or one of its matching lines.
    enum Row: Identifiable {
        case file(path: String, count: Int)
        case match(WorktreeSearch.Match)

        var id: String {
            switch self {
            case .file(let path, _): "file:" + path
            case .match(let match): match.id
            }
        }
    }

    var query = ""
    var options = WorktreeSearch.Options()
    private(set) var phase: Phase = .idle
    private(set) var results = WorktreeSearch.Results()
    private(set) var rows: [Row] = []
    /// The query `results` are for.
    private(set) var searched = ""
    /// The highlighted match.
    var selectedId: String?

    var isEmpty: Bool { query.trimmingCharacters(in: .whitespaces).isEmpty }
    var selected: WorktreeSearch.Match? { results.matches.first { $0.id == selectedId } }

    /// Search after a pause in typing; a newer query cancels this one, and
    /// with it the running `git grep`.
    func run(_ exec: any Executor, root: String, isGit: Bool) async {
        let query = query, options = options
        guard !isEmpty else {
            phase = .idle
            results = WorktreeSearch.Results()
            rows = []
            searched = ""
            return
        }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        phase = .searching
        do {
            let found = try await WorktreeSearch.run(exec, root: root, query: query, options: options, isGit: isGit)
            guard !Task.isCancelled else { return }
            show(found, for: query)
            phase = .done
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            show(WorktreeSearch.Results(), for: query)
            phase = .failed(error.localizedDescription)
        }
    }

    private func show(_ found: WorktreeSearch.Results, for query: String) {
        results = found
        searched = query
        var out: [Row] = []
        var start = 0
        let matches = found.matches
        // git lists a file's lines together.
        while start < matches.count {
            var end = start
            while end < matches.count, matches[end].path == matches[start].path { end += 1 }
            out.append(.file(path: matches[start].path, count: end - start))
            out += matches[start..<end].map { .match($0) }
            start = end
        }
        rows = out
        // Nothing chosen yet, so ⌘G and Return start at the first match.
        if selected == nil { selectedId = nil }
    }

    /// Up/down through the matches.
    func moveSelection(_ delta: Int) {
        let matches = results.matches
        guard !matches.isEmpty else { return }
        let current = matches.firstIndex { $0.id == selectedId }
        let next = current.map { min(max($0 + delta, 0), matches.count - 1) } ?? (delta > 0 ? 0 : matches.count - 1)
        selectedId = matches[next].id
    }

    /// ⌘G and ⇧⌘G: the next or previous match, round to the start.
    func step(_ delta: Int) -> WorktreeSearch.Match? {
        let matches = results.matches
        guard !matches.isEmpty else { return nil }
        let next = matches.firstIndex { $0.id == selectedId }.map { ($0 + delta + matches.count) % matches.count }
            ?? (delta > 0 ? 0 : matches.count - 1)
        selectedId = matches[next].id
        return matches[next]
    }

    /// "128 matches in 17 files".
    var summary: String {
        let count = results.matches.count, files = results.fileCount
        let lines = results.truncated ? "More than \(count.formatted()) matches" : "\(count.formatted()) \(count == 1 ? "match" : "matches")"
        return "\(lines) in \(files.formatted()) \(files == 1 ? "file" : "files")"
    }
}

extension AppModel {
    /// ⇧⌘F: the chat's Files tab, searching inside its files.
    func searchInFiles(_ sessionId: String) {
        showPane(.files, in: sessionId)
        FilesPaneState.shared.session(sessionId).searchContents()
    }

    /// The Files search ⌘G steps through: the chat in front's, while its
    /// Files tab shows matches.
    var fileSearchInFront: String? {
        guard let id = selectedSessionId, let files = FilesPaneState.shared.existing(id), files.mode == .contents,
              !files.contents.results.matches.isEmpty, layout(for: id).isShowing(.files) else { return nil }
        return id
    }

    func stepFileSearch(_ delta: Int) {
        guard let id = fileSearchInFront, let match = FilesPaneState.shared.session(id).contents.step(delta) else { return }
        openSearchMatch(match, in: id)
    }

    /// Open a match's file at its line, with the match selected.
    func openSearchMatch(_ match: WorktreeSearch.Match, in sessionId: String) {
        openFile(match.path, in: sessionId, line: match.line, selecting: match.column..<(match.column + match.length), preview: true)
    }
}

// MARK: - Views

/// The matches, grouped by file, under how many there are.
struct FileSearchResultsView: View {
    let search: FileContentSearch
    let root: String
    let onOpen: (WorktreeSearch.Match) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if search.isEmpty {
                FilesMessage(symbol: "magnifyingglass", title: "Search in files",
                             message: "Finds text inside the worktree's files, new ones included. Ignored files are skipped.")
            } else if case .failed(let message) = search.phase {
                FilesMessage(symbol: "exclamationmark.triangle", title: "Couldn't search", message: message)
            } else if search.searched.isEmpty {
                VStack(spacing: Space.md) {
                    ProgressView().controlSize(.small)
                    Text("Searching…").font(.btCallout).foregroundStyle(Color.btTextSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if search.results.matches.isEmpty {
                FilesMessage(symbol: "magnifyingglass", title: "No matches",
                             message: "Nothing in the worktree's files contains “\(search.searched)”.")
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Text(search.summary)
                        .font(.btCaption)
                        .foregroundStyle(Color.btTextTertiary)
                        .padding(.horizontal, 6)
                        .frame(height: FileTreeMetrics.rowHeight)
                    ForEach(search.rows) { row in
                        switch row {
                        case .file(let path, let count):
                            FileSearchFileRow(path: path, count: count, root: root)
                        case .match(let match):
                            FileSearchMatchRow(match: match, selected: search.selectedId == match.id) {
                                search.selectedId = match.id
                                onOpen(match)
                            }
                            .id(match.id)
                        }
                    }
                }
                .padding(.horizontal, Space.xs + 2)
                .padding(.vertical, Space.xs + 2)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if search.results.timedOut {
                    FilesFootnote(text: "The search stopped after \(Int(WorktreeSearch.timeout.components.seconds)) seconds. These are the matches it found by then.")
                } else if search.results.truncated {
                    FilesFootnote(text: "Showing the first \(WorktreeSearch.limit.formatted()) matches.")
                }
            }
            .onChange(of: search.selectedId) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.upArrow) { search.moveSelection(-1); return .handled }
        .onKeyPress(.downArrow) { search.moveSelection(1); return .handled }
        .onKeyPress(.return) {
            guard let match = search.selected else { return .ignored }
            onOpen(match)
            return .handled
        }
    }
}

/// A file's heading: its name, its folder and how many lines matched.
private struct FileSearchFileRow: View {
    let path: String
    let count: Int
    let root: String

    private var folder: String { FileIndex.parent(of: path) }

    var body: some View {
        HStack(spacing: 0) {
            FileIcon(path: path)
                .frame(width: 18)
                .padding(.trailing, 5)
            Text((path as NSString).lastPathComponent)
                .font(.btBodyMedium)
                .foregroundStyle(Color.btText)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            if !folder.isEmpty {
                Text(folder)
                    .font(.btCaption)
                    .foregroundStyle(Color.btTextTertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .padding(.leading, 6)
            }
            Spacer(minLength: Space.sm)
            Text(count.formatted())
                .font(.btCaption)
                .monospacedDigit()
                .foregroundStyle(Color.btTextTertiary)
        }
        .padding(.leading, 6)
        .padding(.trailing, 6)
        .frame(height: FileTreeMetrics.rowHeight)
        .padding(.top, 4)
        .help(path)
        .contextMenu { FileContextMenu(root: root, path: path, isDirectory: false) }
    }
}

/// A matching line: its number, then the line with the match marked.
private struct FileSearchMatchRow: View {
    let match: WorktreeSearch.Match
    let selected: Bool
    let onActivate: () -> Void

    var body: some View {
        Button(action: onActivate) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(match.line)")
                    .font(.btMonoSmall)
                    .monospacedDigit()
                    .foregroundStyle(Color.btTextTertiary)
                    .frame(minWidth: 28, alignment: .trailing)
                Text(Self.marked(match))
                    .font(.btMonoSmall)
                    .foregroundStyle(Color.btTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.leading, 6)
            .padding(.trailing, 6)
            .frame(height: FileTreeMetrics.rowHeight - 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle(selected: selected, cornerRadius: 6))
        .help("\(match.path), line \(match.line)")
    }

    static func marked(_ match: WorktreeSearch.Match) -> AttributedString {
        var text = AttributedString(match.preview)
        let preview = match.preview
        for range in match.highlights {
            guard let found = Range(NSRange(location: range.lowerBound, length: range.count), in: preview),
                  let marked = Range<AttributedString.Index>(found, in: text) else { continue }
            text[marked].backgroundColor = .btFindCurrent
            text[marked].foregroundColor = .btText
        }
        return text
    }
}
