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
                    FilesFilterBar(state: state, onRefresh: { Task { await refresh() } }, onHide: nil)
                    FileTreeView(state: state, root: root, onRetry: { Task { await refresh() } })
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
        .onChange(of: model.session(session.id)?.status) { Task { await refresh() } }
        .onChange(of: state.openPath) { _, path in
            if let path { model.openFileTab(path, in: session.id, preview: true) }
        }
    }

    private func refresh() async {
        guard let root else { return }
        await state.refresh(model.executor(for: session.id), root: root)
    }
}

// MARK: - Filter

/// The filter field above the tree. Arrows and return drive the list below
/// while typing; escape clears it.
struct FilesFilterBar: View {
    @Bindable var state: FilesSession
    let onRefresh: () -> Void
    let onHide: (() -> Void)?
    @FocusState private var focused: Bool
    @State private var showSpinner = false

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(focused || state.isFiltering ? Color.btTextSecondary : Color.btTextTertiary)
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
                    Button { state.clearFilter() } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 11, weight: .regular))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.btTextTertiary)
                    .help("Clear the filter")
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
        .overlay(alignment: .bottom) { Hairline() }
    }
}
