import SwiftUI
import AppKit
import AbstractCore

/// The worktree as a tree, or, while filtering, a flat list of matches.
/// Up/down move, left/right close and open folders, return opens.
struct FileTreeView: View {
    let state: FilesSession
    let root: String
    let onRetry: () -> Void
    @FocusState private var focused: Bool

    private struct MatchKey: Equatable { let query: String; let version: Int }
    private struct RevealKey: Equatable { let path: String?; let rows: Int }

    var body: some View {
        Group {
            switch state.phase {
            case .idle, .loading:
                VStack(spacing: Space.md) {
                    ProgressView().controlSize(.small)
                    Text("Reading files…").font(.btCallout).foregroundStyle(Color.btTextSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                FilesMessage(symbol: "exclamationmark.triangle", title: "Couldn't list the files", message: message,
                             action: ("Try Again", onRetry))
            case .loaded:
                if state.isFiltering {
                    matchList
                } else if state.rows.isEmpty {
                    FilesMessage(symbol: "folder", title: "No files", message: "The worktree is empty.")
                } else {
                    tree
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: MatchKey(query: state.filter, version: state.indexVersion)) {
            // Big repositories get a beat to finish the word before searching.
            if (state.index?.files.count ?? 0) > 20_000 { try? await Task.sleep(for: .milliseconds(90)) }
            guard !Task.isCancelled else { return }
            await state.updateMatches()
        }
    }

    // MARK: Tree

    private var tree: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let index = state.index
                    ForEach(state.rows) { row in
                        let path = row.entry.path
                        FileTreeRowView(
                            entry: row.entry, depth: row.depth, root: root,
                            expanded: row.entry.isDirectory && state.isExpanded(path),
                            selected: state.selectedPath == path,
                            opened: state.openPath == path,
                            change: index?.changes[path],
                            containsChanges: row.entry.isDirectory && index?.changedDirectories.contains(path) == true,
                            onActivate: { state.activate(row.entry); focused = true }
                        )
                        .id(path)
                    }
                }
                .padding(.horizontal, Space.xs + 2)
                .padding(.vertical, Space.xs + 2)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if state.index?.truncated == true {
                    FilesFootnote(text: "Showing the first \(FileIndex.walkLimit.formatted()) files.")
                }
            }
            .onChange(of: state.selectedPath) { _, path in
                guard let path, state.pendingReveal == nil else { return }
                proxy.scrollTo(path)
            }
            .onChange(of: RevealKey(path: state.pendingReveal, rows: state.rows.count), initial: true) { _, key in
                guard let path = key.path, state.rows.contains(where: { $0.id == path }) else { return }
                state.pendingReveal = nil
                Task { @MainActor in
                    await Task.yield()
                    proxy.scrollTo(path, anchor: .center)
                }
            }
        }
        .keyboardNavigation(state: state, focused: $focused)
    }

    // MARK: Matches

    private var matchList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let index = state.index
                    ForEach(state.matches) { entry in
                        FileMatchRowView(entry: entry, root: root,
                                         selected: state.selectedPath == entry.path,
                                         change: index?.changes[entry.path],
                                         onActivate: { state.activate(entry); focused = true })
                            .id(entry.path)
                    }
                }
                .padding(.horizontal, Space.xs + 2)
                .padding(.vertical, Space.xs + 2)
            }
            .overlay {
                if state.matches.isEmpty {
                    Text("No files match “\(state.filter.trimmingCharacters(in: .whitespaces))”")
                        .font(.btCallout)
                        .foregroundStyle(Color.btTextTertiary)
                        .multilineTextAlignment(.center)
                        .padding(Space.lg)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if state.matchTotal > state.matches.count {
                    FilesFootnote(text: "Showing \(state.matches.count.formatted()) of \(state.matchTotal.formatted()) matches.")
                }
            }
            .onChange(of: state.selectedPath) { _, path in
                if let path { proxy.scrollTo(path) }
            }
        }
        .keyboardNavigation(state: state, focused: $focused)
    }
}

private extension View {
    func keyboardNavigation(state: FilesSession, focused: FocusState<Bool>.Binding) -> some View {
        focusable()
            .focusEffectDisabled()
            .focused(focused)
            .onKeyPress(.upArrow) { state.moveSelection(-1); return .handled }
            .onKeyPress(.downArrow) { state.moveSelection(1); return .handled }
            .onKeyPress(.leftArrow) { state.collapseSelection(); return .handled }
            .onKeyPress(.rightArrow) { state.expandSelection(); return .handled }
            .onKeyPress(.return) { state.activateSelection(); return .handled }
            .onKeyPress(.escape) {
                guard !state.filter.isEmpty else { return .ignored }
                state.clearFilter()
                return .handled
            }
    }
}

// MARK: - Rows

enum FileTreeMetrics {
    static let rowHeight: CGFloat = 24
    static let indent: CGFloat = 14
}

private struct FileTreeRowView: View {
    let entry: FileEntry
    let depth: Int
    let root: String
    let expanded: Bool
    let selected: Bool
    let opened: Bool
    let change: FileDiff.FileStatus?
    let containsChanges: Bool
    let onActivate: () -> Void

    var body: some View {
        Button(action: onActivate) {
            HStack(spacing: 0) {
                Spacer().frame(width: CGFloat(depth) * FileTreeMetrics.indent)
                Group {
                    if entry.isDirectory {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.btTextTertiary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                }
                .frame(width: 16)
                FileIcon(path: entry.path, isDirectory: entry.isDirectory, open: expanded)
                    .frame(width: 18)
                    .padding(.trailing, 5)
                FileName(entry: entry, change: change, emphasized: opened)
                    .layoutPriority(1)
                Spacer(minLength: Space.sm)
                FileChangeMark(change: change, containsChanges: containsChanges)
            }
            .padding(.leading, 2)
            .padding(.trailing, 6)
            .frame(height: FileTreeMetrics.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle(selected: selected, cornerRadius: 6))
        .animation(.snappy(duration: 0.14), value: expanded)
        .help(entry.path)
        .contextMenu { FileContextMenu(root: root, path: entry.path, isDirectory: entry.isDirectory) }
    }
}

/// A filter match: the name, then its folder.
private struct FileMatchRowView: View {
    let entry: FileEntry
    let root: String
    let selected: Bool
    let change: FileDiff.FileStatus?
    let onActivate: () -> Void

    var body: some View {
        Button(action: onActivate) {
            HStack(spacing: 0) {
                FileIcon(path: entry.path)
                    .frame(width: 18)
                    .padding(.trailing, 5)
                FileName(entry: entry, change: change, emphasized: false)
                    .layoutPriority(1)
                if !entry.directory.isEmpty {
                    // The whole folder, its last part, or nothing: never a sliver.
                    ViewThatFits(in: .horizontal) {
                        folder(entry.directory)
                        if entry.directory.contains("/") {
                            folder("…/" + (entry.directory as NSString).lastPathComponent)
                        }
                        Color.clear.frame(width: 0, height: 0)
                    }
                }
                Spacer(minLength: Space.sm)
                FileChangeMark(change: change, containsChanges: false)
            }
            .padding(.leading, 6)
            .padding(.trailing, 6)
            .frame(height: FileTreeMetrics.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle(selected: selected, cornerRadius: 6))
        .help(entry.path)
        .contextMenu { FileContextMenu(root: root, path: entry.path, isDirectory: false) }
    }

    private func folder(_ text: String) -> some View {
        Text(text)
            .font(.btCaption)
            .foregroundStyle(Color.btTextTertiary)
            .lineLimit(1)
            .fixedSize()
            .padding(.leading, 6)
    }
}

private struct FileName: View {
    let entry: FileEntry
    let change: FileDiff.FileStatus?
    let emphasized: Bool

    var body: some View {
        Text(entry.name)
            .font(emphasized ? .btBodyMedium : .btBody)
            .foregroundStyle(change == .deleted ? Color.btTextSecondary : Color.btText)
            .strikethrough(change == .deleted, color: Color.btTextTertiary)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

/// M/A/D/R for a changed file, a dot for a folder holding changes.
private struct FileChangeMark: View {
    let change: FileDiff.FileStatus?
    let containsChanges: Bool

    var body: some View {
        if let change {
            DiffStatusLetter(status: change, size: 10.5)
        } else if containsChanges {
            Circle()
                .fill(Color.btWarning)
                .frame(width: 5, height: 5)
                .frame(width: 13.5)
                .help("Contains changes")
        }
    }
}

struct FileContextMenu: View {
    @Environment(\.worktreeIsRemote) private var remote
    let root: String
    let path: String
    let isDirectory: Bool

    var body: some View {
        let absolute = FileIndex.join(root, path)
        if !remote {
            if !isDirectory {
                Button("Open With Default App") { FileActions.open(absolute) }
            }
            Button("Reveal in Finder") { FileActions.reveal(absolute) }
            Divider()
        }
        Button("Copy Relative Path") { FileActions.copy(path) }
        Button("Copy Full Path") { FileActions.copy(absolute) }
    }
}

// MARK: - Shared bits

enum FileActions {
    static func open(_ absolute: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: absolute))
    }

    static func reveal(_ absolute: String) {
        let url = URL(fileURLWithPath: absolute)
        if FileManager.default.fileExists(atPath: absolute) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
        }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// A quiet line of context under a list.
struct FilesFootnote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.btCaption)
            .foregroundStyle(Color.btTextTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.sm)
            .background(Color.btCanvas)
            .overlay(alignment: .top) { Hairline() }
    }
}

/// An empty state sized for a narrow column.
struct FilesMessage: View {
    let symbol: String
    let title: String
    var message: String? = nil
    var action: (label: String, run: () -> Void)? = nil

    var body: some View {
        VStack(spacing: Space.sm) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(Color.btTextTertiary)
                .padding(.bottom, Space.xxs)
            Text(title).font(.btBodyMedium).foregroundStyle(Color.btText)
            if let message {
                Text(message)
                    .font(.btCallout)
                    .foregroundStyle(Color.btTextSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            if let action {
                Button(action.label, action: action.run)
                    .buttonStyle(.bt(.secondary, size: .small))
                    .padding(.top, Space.xs)
            }
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
