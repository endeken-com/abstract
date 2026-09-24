import SwiftUI
import AbstractCore

/// A file tab: Paseo's editor bar (size and line count, then the caret), a
/// warning when the file changed on disk under your edits, and the text.
struct CodeEditorView: View {
    @Environment(AppModel.self) private var model
    let sessionId: String
    let path: String
    /// The tab, kept once you edit it.
    let tabId: String

    var body: some View {
        if let root = model.session(sessionId)?.worktreePath, !root.isEmpty {
            let document = EditorStore.shared.document(root: root, path: path, in: sessionId, model: model)
            VStack(spacing: 0) {
                EditorBar(document: document)
                if document.status == .conflict || document.status == .deleted {
                    EditorConflictBar(document: document)
                }
                content(document)
            }
            .background(Color.btCanvas)
            .task(id: path) {
                document.onFirstEdit = { [weak model] in model?.keepTab(tabId) }
                await document.load()
            }
        } else {
            EmptyStateView(symbol: "doc.questionmark", title: "No worktree", message: "This chat has no worktree to open files from.")
        }
    }

    @ViewBuilder
    private func content(_ document: EditorDocument) -> some View {
        switch document.content {
        case .loading:
            Color.clear
        case .text:
            let commented = Set(model.comments(sessionId).filter { $0.ref.path == path }.map(\.ref.line))
            CodeTextView(document: document, sessionId: sessionId, commented: commented)
        case .image(let image):
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: min(image.size.width, 1600), maxHeight: min(image.size.height, 1600))
                    .padding(Space.xl)
            }
        case .binary:
            EmptyStateView(symbol: "doc", title: "Binary preview unavailable", message: EditorDocument.format(document.size))
        case .tooLarge:
            EmptyStateView(symbol: "doc", title: "This file is too large to display", message: EditorDocument.format(document.size))
        case .missing:
            EmptyStateView(symbol: "doc.questionmark", title: "This file no longer exists", message: path)
        case .unreadable(let reason):
            EmptyStateView(symbol: "exclamationmark.triangle", title: "Couldn't read this file", message: reason)
        }
    }
}

/// Size and lines on the left, how saving is going, the caret on the right.
private struct EditorBar: View {
    let document: EditorDocument

    var body: some View {
        HStack(spacing: Space.md) {
            HStack(spacing: Space.sm) {
                Text(EditorDocument.format(document.size))
                if case .text = document.content {
                    Text("\(document.lineCount.formatted()) lines")
                }
                switch document.status {
                case .dirty:
                    Circle().fill(Color.btTextTertiary).frame(width: 6, height: 6).help("Unsaved changes")
                case .saving:
                    Text("Saving…").foregroundStyle(Color.btTextSecondary)
                case .failed(let reason):
                    Text("Save failed").foregroundStyle(Color.btRemoved).help(reason)
                default:
                    EmptyView()
                }
                if case .text(false) = document.content {
                    Text("Read only").help("Files over \(EditorDocument.format(EditorDocument.editableLimit)) open read-only.")
                }
            }
            Spacer(minLength: Space.sm)
            if case .text = document.content {
                Text("Ln \(document.line), Col \(document.column)").monospacedDigit()
            }
        }
        .font(BTFont.ui(12))
        .foregroundStyle(Color.btTextTertiary)
        .lineLimit(1)
        .padding(.horizontal, Space.md)
        .frame(height: 36)
        .overlay(alignment: .bottom) { Hairline() }
    }
}

/// Paseo's "Changed on disk": keep yours, or take the file as it is now.
private struct EditorConflictBar: View {
    let document: EditorDocument
    @State private var confirmingReload = false

    var body: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.btTextSecondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(document.status == .deleted ? "File deleted on disk" : "Changed on disk").font(BTFont.ui(12.5, .medium))
                Text(document.status == .deleted ? "The open copy is preserved." : "It changed while you were editing it here.")
                    .font(.btCaption).foregroundStyle(Color.btTextSecondary)
            }
            Spacer(minLength: Space.sm)
            if document.status == .conflict {
                Button("Overwrite") { Task { await document.overwrite() } }
                    .buttonStyle(.bt(.ghost, size: .small))
                    .help("Save your version over the one on disk")
                Button("Reload") { confirmingReload = true }
                    .buttonStyle(.bt(.secondary, size: .small))
            } else {
                Button("Save Here") { Task { await document.overwrite() } }
                    .buttonStyle(.bt(.secondary, size: .small))
                    .help("Write the open copy back to disk")
            }
        }
        .foregroundStyle(Color.btText)
        .padding(.horizontal, Space.md)
        .frame(minHeight: 48)
        .background(Color.btSurface)
        .overlay(alignment: .bottom) { Hairline() }
        .confirmationDialog("Reload from disk?", isPresented: $confirmingReload, titleVisibility: .visible) {
            Button("Reload", role: .destructive) { Task { await document.reload() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your local changes will be lost.")
        }
    }
}
