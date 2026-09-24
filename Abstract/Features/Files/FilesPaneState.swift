import Foundation
import Observation
import AbstractCore

/// A row of the tree: an entry and how deep it sits.
nonisolated struct FileTreeRow: Sendable, Hashable, Identifiable {
    let entry: FileEntry
    let depth: Int
    var id: String { entry.path }
}

/// The Files pane's state, one per chat, kept for the app's lifetime so it
/// survives the pane being rebuilt (tab switches, re-layout) and so
/// `openFile` can set a selection before the pane first appears.
@Observable
final class FilesPaneState {
    static let shared = FilesPaneState()

    @ObservationIgnored private var bySession: [String: FilesSession] = [:]

    func session(_ sessionId: String) -> FilesSession {
        if let existing = bySession[sessionId] { return existing }
        let created = FilesSession()
        bySession[sessionId] = created
        return created
    }

    /// Forget a deleted chat.
    func discard(_ sessionId: String) {
        bySession[sessionId] = nil
    }
}

extension AppModel {
    /// Open `relativePath` in a tab of the main pane, and select it in the chat's file tree.
    /// Absolute paths inside the chat's worktree are accepted too.
    func openFile(_ relativePath: String, in sessionId: String) {
        var path = relativePath
        if let root = session(sessionId)?.worktreePath, !root.isEmpty {
            let base = FileIndex.join(root, "") + "/"
            if path.hasPrefix(base) { path.removeFirst(base.count) }
        }
        while path.hasPrefix("./") { path.removeFirst(2) }
        while path.hasSuffix("/") { path.removeLast() }
        FilesPaneState.shared.session(sessionId).reveal(path)
        openFileTab(path, in: sessionId)
    }

    /// The same, with the caret on `line`.
    func openFile(_ relativePath: String, in sessionId: String, line: Int?) {
        openFile(relativePath, in: sessionId)
        guard let line, let root = session(sessionId)?.worktreePath else { return }
        EditorStore.shared.document(root: root, path: relativePath, in: sessionId, model: self).goToLine = line
    }
}

/// One chat's tree, selection and open file.
@Observable
final class FilesSession {
    enum Phase: Equatable { case idle, loading, loaded, failed(String) }

    private(set) var phase: Phase = .idle
    private(set) var index: FileIndex?
    /// Bumped whenever `index` is replaced, to re-run the filter.
    private(set) var indexVersion = 0
    private(set) var isRefreshing = false

    /// Visible rows of the tree, rebuilt when folders open or close.
    private(set) var rows: [FileTreeRow] = []
    private(set) var expanded: Set<String> = []

    var filter = ""
    private(set) var matches: [FileEntry] = []
    private(set) var matchTotal = 0

    /// The highlighted row, file or folder.
    var selectedPath: String?
    /// The file last opened from the tree; the pane opens it in a tab.
    private(set) var openPath: String?

    /// A path `openFile` asked the tree to scroll to.
    var pendingReveal: String?

    @ObservationIgnored private var seeded = false
    @ObservationIgnored private var generation = 0

    var isFiltering: Bool { !filter.trimmingCharacters(in: .whitespaces).isEmpty }

    func change(_ path: String) -> FileDiff.FileStatus? { index?.changes[path] }

    // MARK: Loading

    func refresh(_ exec: any Executor, root: String) async {
        generation += 1
        let current = generation
        if index == nil { phase = .loading } else { isRefreshing = true }
        defer { if current == generation { isRefreshing = false } }
        do {
            let loaded = try await FileIndex.load(exec, root: root)
            guard current == generation else { return }
            apply(loaded)
            phase = .loaded
        } catch {
            guard current == generation else { return }
            index = nil
            rows = []
            matches = []
            phase = .failed(error.localizedDescription)
        }
    }

    private func apply(_ loaded: FileIndex) {
        index = loaded
        indexVersion += 1
        if !seeded {
            seeded = true
            expanded.formUnion(Self.initialExpansion(loaded))
        }
        if let pendingReveal { expanded.formUnion(FileIndex.ancestors(of: pendingReveal)) }
        rebuildRows()
    }

    /// The top level, any lone folder chain under it (src/ alone), and the
    /// way down to what the agent changed.
    private static func initialExpansion(_ index: FileIndex) -> Set<String> {
        var result: Set<String> = []
        var dir = ""
        while true {
            let entries = index.entries(in: dir)
            guard entries.count == 1, entries[0].isDirectory else { break }
            result.insert(entries[0].path)
            dir = entries[0].path
        }
        for path in index.changes.keys.sorted().prefix(60) {
            result.formUnion(FileIndex.ancestors(of: path))
        }
        return result
    }

    private func rebuildRows() {
        guard let index else { rows = []; return }
        var out: [FileTreeRow] = []
        func walk(_ dir: String, _ depth: Int) {
            for entry in index.entries(in: dir) {
                out.append(FileTreeRow(entry: entry, depth: depth))
                if entry.isDirectory, expanded.contains(entry.path) { walk(entry.path, depth + 1) }
            }
        }
        walk("", 0)
        rows = out
    }

    func updateMatches() async {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard let index, !query.isEmpty else {
            if !matches.isEmpty { matches = [] }
            if matchTotal != 0 { matchTotal = 0 }
            return
        }
        let found = await FileIndex.match(query, in: index)
        guard !Task.isCancelled, query == filter.trimmingCharacters(in: .whitespaces) else { return }
        matches = found.paths.map { FileEntry(path: $0, name: ($0 as NSString).lastPathComponent, isDirectory: false) }
        matchTotal = found.total
        if !matches.contains(where: { $0.path == selectedPath }) { selectedPath = matches.first?.path }
    }

    // MARK: Actions

    func isExpanded(_ path: String) -> Bool { expanded.contains(path) }

    func toggle(_ path: String) {
        if expanded.contains(path) { expanded.remove(path) } else { expanded.insert(path) }
        rebuildRows()
    }

    /// A click: folders open or close, files open on the right.
    func activate(_ entry: FileEntry) {
        selectedPath = entry.path
        if entry.isDirectory { toggle(entry.path) } else { openPath = entry.path }
    }

    func open(_ path: String) {
        selectedPath = path
        openPath = path
    }

    /// Select, open and scroll to a file, opening the folders above it.
    func reveal(_ path: String) {
        filter = ""
        matches = []
        open(path)
        expanded.formUnion(FileIndex.ancestors(of: path))
        pendingReveal = path
        rebuildRows()
    }

    /// Leave the filter, keeping the selected match in view in the tree.
    func clearFilter() {
        guard isFiltering || !filter.isEmpty else { return }
        filter = ""
        matches = []
        if let keep = selectedPath, index?.contains(keep) == true {
            expanded.formUnion(FileIndex.ancestors(of: keep))
            pendingReveal = keep
        }
        rebuildRows()
    }

    // MARK: Keyboard

    private var navigable: [FileEntry] { isFiltering ? matches : rows.map(\.entry) }

    /// Up/down. Moving onto a file shows it, like a preview.
    func moveSelection(_ delta: Int) {
        let entries = navigable
        guard !entries.isEmpty else { return }
        let current = selectedPath.flatMap { path in entries.firstIndex { $0.path == path } }
        let next = current.map { min(max($0 + delta, 0), entries.count - 1) } ?? (delta > 0 ? 0 : entries.count - 1)
        let entry = entries[next]
        selectedPath = entry.path
        if !entry.isDirectory { openPath = entry.path }
    }

    /// Left: close the folder, or step out to its parent.
    func collapseSelection() {
        guard !isFiltering, let path = selectedPath, let index else { return }
        if index.isDirectory(path), expanded.contains(path) {
            toggle(path)
        } else {
            let parent = FileIndex.parent(of: path)
            if !parent.isEmpty { selectedPath = parent }
        }
    }

    /// Right: open the folder, or step into its first entry.
    func expandSelection() {
        guard !isFiltering, let path = selectedPath, let index, index.isDirectory(path) else { return }
        if !expanded.contains(path) {
            toggle(path)
        } else if let first = index.entries(in: path).first {
            selectedPath = first.path
        }
    }

    /// Return: open the file, or open/close the folder.
    func activateSelection() {
        guard let path = selectedPath else {
            if let first = navigable.first { activate(first) }
            return
        }
        if let entry = navigable.first(where: { $0.path == path }) { activate(entry) }
    }
}
