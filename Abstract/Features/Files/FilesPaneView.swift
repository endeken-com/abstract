import SwiftUI
import AbstractCore

/// The chat's worktree as a tree, in the side panel. Choosing a file opens
/// it in the main pane: a single click as a preview the next one replaces,
/// as in Paseo.
struct FilesPaneView: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let paneId: String

    private var state: FilesSession { FilesPaneState.shared.session(session.id) }
    private var root: String? {
        let path = model.session(session.id)?.worktreePath ?? session.worktreePath
        return path?.isEmpty == false ? path : nil
    }

    var body: some View {
        Group {
            if let root {
                VStack(spacing: 0) {
                    FilesFilterBar(state: state, onRefresh: { Task { await refresh() } }, onHide: nil,
                                   onOpenMatch: { model.openSearchMatch($0, in: session.id) })
                    if state.mode == .contents {
                        FileSearchResultsView(search: state.contents, root: root,
                                              onOpen: { model.openSearchMatch($0, in: session.id) })
                    } else {
                        FileTreeView(state: state, root: root, onRetry: { Task { await refresh() } })
                    }
                }
            } else {
                EmptyStateView(symbol: "arrow.triangle.branch", title: "No worktree yet",
                               message: "Files show up here once the chat's worktree is ready.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.btCanvas)
        .environment(\.worktreeIsRemote, model.remoteLink(for: session.id) != nil)
        .task(id: root) { await refresh() }
        // Again when the files change, as the tree is.
        .task(id: SearchKey(mode: state.mode, query: state.contents.query, options: state.contents.options,
                            version: state.indexVersion, root: root)) {
            guard state.mode == .contents, let root else { return }
            await state.contents.run(model.executor(for: session.id), root: root, isGit: state.index?.isGit ?? true)
        }
        .onChange(of: model.session(session.id)?.status) { Task { await refresh() } }
        .onChange(of: state.openPath) { _, path in
            if let path { model.openFileTab(path, in: session.id, preview: true) }
        }
    }

    private struct SearchKey: Equatable {
        let mode: FilesSession.SearchMode
        let query: String
        let options: WorktreeSearch.Options
        let version: Int
        let root: String?
    }

    private func refresh() async {
        guard let root else { return }
        await state.refresh(model.executor(for: session.id), root: root)
    }
}

// MARK: - Filter

/// The search box above the tree: it filters file names, or, after ⇧⌘F,
/// searches inside files. Arrows and return drive the list below while
/// typing; escape clears it, then goes back to filtering names.
struct FilesFilterBar: View {
    @Bindable var state: FilesSession
    let onRefresh: () -> Void
    let onHide: (() -> Void)?
    var onOpenMatch: (WorktreeSearch.Match) -> Void = { _ in }
    @FocusState private var focused: Bool
    @State private var showSpinner = false

    private var searching: Bool { state.mode == .contents }

    var body: some View {
        @Bindable var search = state.contents
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Button { searching ? state.filterNames() : state.searchContents() } label: {
                    Image(systemName: searching ? "magnifyingglass" : "line.3.horizontal.decrease")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(focused || state.isFiltering || searching ? Color.btTextSecondary : Color.btTextTertiary)
                        .frame(width: 14)
                }
                .buttonStyle(.plain)
                .help(searching ? "Filter file names instead" : "Search inside files (⇧⌘F)")
                if searching {
                    TextField("Search in files", text: $search.query)
                        .textFieldStyle(.plain)
                        .font(.btInputCompact)
                        .focused($focused)
                        .onSubmit {
                            if let match = state.contents.selected ?? state.contents.results.matches.first {
                                state.contents.selectedId = match.id
                                onOpenMatch(match)
                            }
                        }
                        .onKeyPress(.downArrow) { state.contents.moveSelection(1); return .handled }
                        .onKeyPress(.upArrow) { state.contents.moveSelection(-1); return .handled }
                        .onKeyPress(.escape) {
                            if state.contents.query.isEmpty { state.filterNames() } else { state.contents.query = "" }
                            return .handled
                        }
                    if !state.contents.query.isEmpty {
                        clearButton(help: "Clear the search") { state.contents.query = "" }
                    }
                    FileSearchOption(label: "Aa", help: "Match Case", isOn: $search.options.matchCase)
                    FileSearchOption(label: "ab", underline: true, help: "Whole Word", isOn: $search.options.wholeWord)
                    FileSearchOption(label: ".*", help: "Regex", isOn: $search.options.regex)
                } else {
                    TextField("Filter files", text: $state.filter)
                        .textFieldStyle(.plain)
                        .font(.btInputCompact)
                        .focused($focused)
                        .onSubmit { state.activateSelection() }
                        .onKeyPress(.downArrow) { state.moveSelection(1); return .handled }
                        .onKeyPress(.upArrow) { state.moveSelection(-1); return .handled }
                        .onKeyPress(.escape) {
                            guard !state.filter.isEmpty else { return .ignored }
                            state.clearFilter()
                            return .handled
                        }
                    if !state.filter.isEmpty {
                        clearButton(help: "Clear the filter") { state.clearFilter() }
                    }
                }
            }
            .padding(.horizontal, 8)
            .frame(height: Field.compactHeight)
            .btFieldChrome(focused: focused)
            Group {
                if showSpinner {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                        .frame(width: 24, height: 24)
                        .help("Refreshing…")
                } else {
                    Button(action: onRefresh) { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.icon(size: 24))
                        .disabled(state.isRefreshing)
                        .help("Refresh the file list")
                }
            }
            if let onHide {
                Button(action: onHide) { Image(systemName: "sidebar.left") }
                    .buttonStyle(.icon(size: 24))
                    .help("Hide the file list")
            }
        }
        // Most refreshes finish in a blink; only a slow one earns a spinner.
        .task(id: state.isRefreshing) {
            guard state.isRefreshing else { showSpinner = false; return }
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled { showSpinner = state.isRefreshing }
        }
        .padding(.leading, Space.md)
        .padding(.trailing, Space.xs)
        .frame(height: 44)
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .onChange(of: state.wantsFocus, initial: true) { _, wants in
            guard wants else { return }
            state.wantsFocus = false
            // Once the field exists, if the pane has just appeared.
            DispatchQueue.main.async { focused = true }
        }
        .overlay(alignment: .bottom) { Hairline() }
    }

    private func clearButton(help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill").font(.system(size: 11, weight: .regular))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.btTextTertiary)
        .help(help)
    }
}

/// Match Case, Whole Word or Regex, inside the search box.
private struct FileSearchOption: View {
    let label: String
    var underline = false
    let help: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            Text(label)
                .font(.system(size: 10.5, weight: .semibold, design: label == ".*" ? .monospaced : .default))
                .underline(underline)
                .foregroundStyle(isOn ? Color.btText : Color.btTextTertiary)
                .frame(width: 20, height: 18)
                .background(isOn ? Color.btSelection : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
