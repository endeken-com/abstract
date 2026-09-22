import SwiftUI
import AppKit
import BacktickCore

enum DiffLayout: String { case unified, split }

/// The chat's "Changes" tab: everything the agent changed in its worktree,
/// file by file, with accept (into the main working tree) and reject (in the
/// worktree) at file and hunk level.
struct DiffView: View {
    @Environment(AppModel.self) private var model
    let sessionId: String

    @State private var review = DiffReview()
    @AppStorage("diff.layout") private var layout: DiffLayout = .unified
    @AppStorage("diff.fileListWidth") private var listWidth: Double = 260
    @State private var confirmingAcceptAll = false

    var body: some View {
        Group {
            switch model.diffAvailability(sessionId) {
            case .noProject:
                EmptyStateView(symbol: "folder.badge.questionmark", title: "Nothing to compare against",
                               message: "This chat runs without a project, so there is no worktree to review.")
            case .noWorktree:
                EmptyStateView(symbol: "arrow.triangle.branch", title: "No worktree yet",
                               message: "Changes show up here once the chat's worktree is ready.")
            case .ready(let context):
                content(context)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.btCanvas)
        .task(id: sessionId) { await reload() }
        .onChange(of: model.session(sessionId)?.status) { Task { await reload() } }
    }

    private func reload() async {
        guard case .ready(let context) = model.diffAvailability(sessionId) else { return }
        await review.load(context)
    }

    @ViewBuilder
    private func content(_ context: DiffContext) -> some View {
        switch review.phase {
        case .loading:
            VStack(spacing: Space.md) {
                ProgressView().controlSize(.small)
                Text("Reading changes…").font(.btCallout).foregroundStyle(Color.btTextSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            EmptyStateView(symbol: "exclamationmark.triangle", title: "Couldn't read the changes", message: message,
                           action: ("Try Again", { Task { await review.load(context) } }))
        case .loaded:
            VStack(spacing: 0) {
                DiffSummaryBar(review: review, layout: $layout, onRefresh: { Task { await review.load(context) } },
                               onAcceptAll: { confirmingAcceptAll = true })
                if let error = review.actionError {
                    DiffErrorBanner(message: error) { review.actionError = nil }
                }
                if review.files.isEmpty {
                    EmptyStateView(symbol: "checkmark.circle", title: "No changes yet",
                                   message: "The agent hasn't modified anything in its worktree.")
                } else {
                    HStack(spacing: 0) {
                        DiffFileList(review: review, projectName: context.projectName, nestedRepos: context.exclude)
                            .frame(width: listWidth)
                        DiffPaneDivider(width: $listWidth)
                        if let file = review.selectedFile {
                            DiffFilePane(review: review, file: file, layout: layout, context: context)
                        } else {
                            EmptyStateView(symbol: "doc.text.magnifyingglass", title: "Select a file")
                        }
                    }
                }
            }
            .confirmationDialog("Accept all changes into \(context.projectName)?", isPresented: $confirmingAcceptAll,
                                titleVisibility: .visible) {
                Button("Accept All") { Task { await review.acceptAll(context, model: model) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                let count = review.files.filter { !review.isAccepted($0) }.count
                Text("This writes the agent's changes to \(count) file\(count == 1 ? "" : "s") in your main working tree at \(context.root). Nothing is committed, so you can still review them there.")
            }
        }
    }
}

// MARK: - Summary bar

private struct DiffSummaryBar: View {
    let review: DiffReview
    @Binding var layout: DiffLayout
    let onRefresh: () -> Void
    let onAcceptAll: () -> Void

    var body: some View {
        let count = review.files.count
        let pending = review.files.contains { !review.isAccepted($0) }
        HStack(spacing: Space.md) {
            HStack(spacing: Space.sm) {
                Text(count == 0 ? "No changes" : "\(count) file\(count == 1 ? "" : "s") changed")
                    .font(.btBodyMedium)
                    .foregroundStyle(Color.btText)
                if count > 0 {
                    DiffCounts(additions: review.totalAdditions, deletions: review.totalDeletions)
                }
                if review.isRefreshing || review.isWorking {
                    ProgressView().controlSize(.small).scaleEffect(0.8)
                        .help(review.isWorking ? "Applying…" : "Refreshing…")
                }
            }
            Spacer(minLength: Space.md)
            Picker("Layout", selection: $layout) {
                Text("Unified").tag(DiffLayout.unified)
                Text("Split").tag(DiffLayout.split)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Show changes in one column or side by side")
            Button(action: onRefresh) { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.icon)
                .keyboardShortcut("r", modifiers: .command)
                .disabled(review.isRefreshing || review.isWorking)
                .help("Refresh (⌘R)")
            Button(action: onAcceptAll) {
                Label(pending || count == 0 ? "Accept All" : "All Accepted", systemImage: "checkmark")
            }
            .buttonStyle(.bt(.primary, size: .small))
            .disabled(count == 0 || !pending || review.isWorking)
            .help("Apply every change to the project's main working tree")
        }
        .padding(.horizontal, Space.lg)
        .frame(height: 44)
        .background(Color.btCanvas)
        .overlay(alignment: .bottom) { Hairline() }
    }
}

private struct DiffErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Space.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.btRemoved)
                .padding(.top, 1)
            Text(message)
                .font(.btCallout)
                .foregroundStyle(Color.btText)
                .textSelection(.enabled)
                .lineLimit(6)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) { Image(systemName: "xmark") }
                .buttonStyle(.icon(size: 20))
                .help("Dismiss")
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Hairline() }
    }
}

/// Drag handle between the file list and the diff.
private struct DiffPaneDivider: View {
    @Binding var width: Double
    @State private var dragStart: Double?

    var body: some View {
        Rectangle()
            .fill(Color.btBorder)
            .frame(width: 0.5)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .pointerStyle(.columnResize)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = dragStart ?? width
                                dragStart = start
                                width = min(max(start + value.translation.width, 190), 460)
                            }
                            .onEnded { _ in dragStart = nil }
                    )
            }
    }
}

// MARK: - Shared bits

/// `+12 −4` in the diff colours.
struct DiffCounts: View {
    let additions: Int
    let deletions: Int
    var hideZeros = false

    var body: some View {
        HStack(spacing: 5) {
            if !(hideZeros && additions == 0) {
                Text("+\(additions)").foregroundStyle(Color.btAdded)
            }
            if !(hideZeros && deletions == 0) {
                Text("−\(deletions)").foregroundStyle(Color.btRemoved)
            }
        }
        .font(.btMonoSmall)
        .monospacedDigit()
    }
}

/// A/M/D/R as a coloured letter.
struct DiffStatusLetter: View {
    let status: FileDiff.FileStatus
    var size: CGFloat = 11

    var body: some View {
        Text(letter)
            .font(.system(size: size, weight: .bold, design: .monospaced))
            .foregroundStyle(tint)
            .frame(width: size + 3)
            .help(status.word)
            .accessibilityLabel(status.word)
    }

    private var letter: String {
        switch status {
        case .added: "A"
        case .modified: "M"
        case .deleted: "D"
        case .renamed: "R"
        }
    }

    private var tint: Color {
        switch status {
        case .added: .btAdded
        case .modified: .btWarning
        case .deleted: .btRemoved
        case .renamed: .btTextSecondary
        }
    }
}

extension FileDiff.FileStatus {
    var word: String {
        switch self {
        case .added: "Added"
        case .modified: "Modified"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        }
    }
}

/// "Accepted" with a check, for files and hunks already in the main tree.
struct DiffAcceptedLabel: View {
    var partly = false
    var body: some View {
        Label(partly ? "Partly accepted" : "Accepted", systemImage: partly ? "circle.lefthalf.filled" : "checkmark.circle.fill")
            .font(.btCaptionMedium)
            .foregroundStyle(Color.btAdded)
            .labelStyle(.titleAndIcon)
    }
}
