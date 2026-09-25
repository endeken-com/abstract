import SwiftUI
import AppKit
import AbstractCore

enum DiffLayout: String { case unified, split }

/// The chat's review: what the agent changed, file by file, after Paseo's
/// Changes panel (Apache-2.0, Copyright (c) 2025-present Mohamed Boudra).
/// It compares the uncommitted work, or the branch's commits, or one of
/// them; refreshes as files change; takes comments on any line; and can
/// discard changes, or apply them to the project's main checkout.
struct DiffView: View {
    /// The whole diff (a main-pane tab), or the side panel's list of files, which opens it.
    enum Presentation { case document, list }

    @Environment(AppModel.self) private var model
    let sessionId: String
    var presentation: Presentation = .document

    /// Shared by the chat's list and its diff tab, so both show the same review.
    private var review: DiffReview { ReviewStore.shared.review(sessionId) }
    @AppStorage("diff.layout") private var layout: DiffLayout = .unified
    @AppStorage("diff.ignoreWhitespace") private var ignoreWhitespace = false
    @AppStorage("diff.tree") private var showTree = false
    @State private var confirmingApplyAll = false
    @State private var discarding: [ReviewFile] = []
    @State private var watcher: AnyObject?

    var body: some View {
        Group {
            switch model.diffAvailability(sessionId) {
            case .noProject:
                EmptyStateView(symbol: "folder.badge.questionmark", title: "Nothing to compare against",
                               message: "This chat runs without a project, so there is no worktree to review.")
            case .noWorktree:
                EmptyStateView(symbol: "arrow.triangle.branch", title: "No worktree yet",
                               message: "Changes show up here once the chat's worktree is ready.")
            case .handedOver:
                EmptyStateView(symbol: "arrow.turn.up.right", title: "Worktree handed over",
                               message: "A newer chat started in this chat's worktree and works there now.")
            case .worktreeMissing(let path):
                EmptyStateView(symbol: "folder.badge.questionmark", title: "This chat's worktree is gone",
                               message: "Its folder was moved or deleted outside Abstract:\n\((path as NSString).abbreviatingWithTildeInPath)")
            case .ready(let context):
                content(context)
                    .task(id: context.worktree) { await watch(context) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.btCanvas)
        .environment(\.worktreeIsRemote, sessionId.hasPrefix(RemoteService.mirrorPrefix))
        .task(id: sessionId) { await reload() }
        .onChange(of: model.session(sessionId)?.status) { Task { await reload() } }
        .onChange(of: model.pendingChangeSelection[sessionId]) { takePendingSelection() }
        .onChange(of: ignoreWhitespace) { Task { await reload() } }
    }

    private func reload() async {
        guard case .ready(let context) = model.diffAvailability(sessionId) else { return }
        review.ignoreWhitespace = ignoreWhitespace
        await review.load(context)
        takePendingSelection()
    }

    /// Refresh as the agent (or you) changes files, commits or switches branch.
    private func watch(_ context: DiffContext) async {
        let gitDir = (try? await context.executor.run("git", ["rev-parse", "--absolute-git-dir"], cwd: context.worktree))
            .flatMap { $0.ok ? $0.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil }
        watcher = model.watch([context.worktree] + (gitDir.map { [$0] } ?? []), for: sessionId) {
            Task { await reload() }
        }
    }

    /// Select the file another pane asked for, once it's in the list.
    private func takePendingSelection() {
        guard presentation == .document, review.phase == .loaded, let path = model.pendingChangeSelection[sessionId] else { return }
        model.pendingChangeSelection[sessionId] = nil
        if review.files.contains(where: { $0.path == path }) { showTree = false; review.focus(path) }
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
                           action: ("Try Again", { Task { await reload() } }))
        case .loaded:
            GeometryReader { geo in
                // Side by side needs room; a side pane shows one column.
                let narrow = geo.size.width < 720
                // The file tree sits beside the diff when there's room, else instead of it.
                let rail = presentation == .document && showTree && geo.size.width >= 640
                VStack(spacing: 0) {
                    ReviewToolbar(review: review, context: context, layout: $layout, ignoreWhitespace: $ignoreWhitespace,
                                  showTree: $showTree, narrow: narrow, showsTreeToggle: presentation == .document,
                                  onRefresh: { Task { await reload() } },
                                  onApplyAll: { confirmingApplyAll = true },
                                  onDiscardAll: { discarding = review.files })
                    if let error = review.actionError {
                        DiffErrorBanner(message: error) { review.actionError = nil }
                    }
                    RevundStrip(sessionId: sessionId, review: review)
                    if review.files.isEmpty {
                        ReviewEmptyState(review: review, context: context)
                    } else if presentation == .list {
                        // Paseo's Changes list: a file opens the diff in the main pane.
                        ChangesTree(review: review) { model.openDiffTab(in: sessionId, focus: $0) }
                    } else if showTree, !rail {
                        ChangesTree(review: review) { path in showTree = false; review.focus(path) }
                    } else {
                        HStack(spacing: 0) {
                            if rail {
                                ChangesTree(review: review) { review.focus($0) }
                                    .frame(width: 220)
                                Rectangle().fill(Color.btBorder).frame(width: 1)
                            }
                            DiffFileSections(review: review, context: context, layout: narrow ? .unified : layout,
                                             width: geo.size.width - (rail ? 221 : 0), onDiscard: { discarding = [$0] })
                        }
                    }
                }
            }
            .confirmationDialog("Apply all changes to \(context.projectName)?", isPresented: $confirmingApplyAll,
                                titleVisibility: .visible) {
                Button("Apply All") { Task { await review.acceptAll(context, model: model) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                let count = review.files.filter { !review.isAccepted($0) }.count
                Text("This writes the agent's changes to \(count) file\(count == 1 ? "" : "s") in your main working tree at \(context.root). Nothing is committed, so you can still review them there.")
            }
            .confirmationDialog("Discard changes?", isPresented: Binding(get: { !discarding.isEmpty }, set: { if !$0 { discarding = [] } }),
                                titleVisibility: .visible) {
                Button("Discard", role: .destructive) {
                    let files = discarding
                    Task { await review.discard(files, context, model: model) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(discarding.count == 1
                     ? "Changes to “\(discarding[0].name)” will be permanently discarded."
                     : "Changes to \(discarding.count) files will be permanently discarded.")
            }
        }
    }
}

/// One review per chat, kept while the app runs, so the list in the side
/// panel and the diff in the main pane read and refresh the same one.
@MainActor
final class ReviewStore {
    static let shared = ReviewStore()
    private var reviews: [String: DiffReview] = [:]

    func review(_ sessionId: String) -> DiffReview {
        if let existing = reviews[sessionId] { return existing }
        let review = DiffReview()
        reviews[sessionId] = review
        return review
    }
}

// MARK: - Toolbar

/// Which changes are shown and their size, then the tree, refresh and the
/// review's options.
private struct ReviewToolbar: View {
    @Environment(AppModel.self) private var model
    let review: DiffReview
    let context: DiffContext
    @Binding var layout: DiffLayout
    @Binding var ignoreWhitespace: Bool
    @Binding var showTree: Bool
    let narrow: Bool
    var showsTreeToggle = true
    let onRefresh: () -> Void
    let onApplyAll: () -> Void
    let onDiscardAll: () -> Void

    var body: some View {
        let count = review.files.count
        HStack(spacing: Space.sm) {
            ModeMenu(review: review, context: context)
            if count > 0 {
                DiffCounts(additions: review.totalAdditions, deletions: review.totalDeletions, compact: true)
                    .fixedSize()
                    .help("\(count) file\(count == 1 ? "" : "s")")
            }
            if review.isRefreshing || review.isWorking {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                    .help(review.isWorking ? "Applying…" : "Refreshing…")
            }
            Spacer(minLength: Space.sm)
            RevundReviewButton(sessionId: context.sessionId, branch: review.mode != .uncommitted)
            if showsTreeToggle {
                Button { withAnimation(.snappy(duration: 0.2)) { showTree.toggle() } } label: {
                    Image(systemName: showTree ? "list.bullet.indent" : "list.bullet")
                }
                .buttonStyle(.icon(size: 26))
                .help(showTree ? "Hide the file tree" : "Show the changed files as a tree")
            }
            Button(action: onRefresh) { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.icon(size: 26))
                .keyboardShortcut("r", modifiers: .command)
                .disabled(review.isRefreshing || review.isWorking)
                .help("Refresh (⌘R)")
            Menu {
                Button("Expand All Files") { review.setAllExpanded(true) }
                Button("Collapse All Files") { review.setAllExpanded(false) }
                Divider()
                Toggle("Side by Side", isOn: Binding(get: { layout == .split }, set: { layout = $0 ? .split : .unified }))
                    .disabled(narrow)
                Toggle("Hide Whitespace Changes", isOn: $ignoreWhitespace)
                Divider()
                Button("Apply All to \(context.projectName)…", action: onApplyAll)
                    .disabled(count == 0 || review.isWorking)
                if review.mode == .uncommitted {
                    Button("Discard All Changes…", role: .destructive, action: onDiscardAll)
                        .disabled(count == 0 || review.isWorking)
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .buttonStyle(.icon(size: 26))
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Review options")
        }
        .padding(.leading, Space.md)
        .padding(.trailing, Space.sm)
        .frame(height: 40)
        .background(Color.btCanvas)
        .overlay(alignment: .bottom) { Hairline() }
    }
}

/// "Uncommitted ⌄": what the review compares, and the branch's commits.
private struct ModeMenu: View {
    let review: DiffReview
    let context: DiffContext

    var body: some View {
        Menu {
            Button { Task { await review.show(.uncommitted, context) } } label: {
                Text("Uncommitted")
                Text(review.dirty ? "Work not committed yet" : "Nothing uncommitted")
            }
            if let base = review.base {
                Button { Task { await review.show(.committed, context) } } label: {
                    Text("Committed")
                    Text("This branch → \(base)")
                }
            }
            if !review.commits.isEmpty {
                Section("Commits") {
                    ForEach(review.commits) { commit in
                        Button { Task { await review.show(.commit(commit), context) } } label: {
                            Text(commit.subject)
                            Text([commit.shortSha, commit.author, commit.date.map { RelativeTime.short($0) }].compactMap { $0 }.joined(separator: " · "))
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(title).font(BTFont.ui(13, .medium)).foregroundStyle(Color.btText).lineLimit(1).truncationMode(.tail)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Color.btTextTertiary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        // A commit's subject can be long: it truncates rather than widening
        // the toolbar, and gives way to the buttons beside it.
        .fixedSize(horizontal: false, vertical: true)
        .help(help)
    }

    private var title: String {
        if case .commit(let c) = review.mode { return c.subject }
        return review.mode.label
    }

    private var help: String {
        switch review.mode {
        case .uncommitted: "Changes not committed yet"
        case .committed: "This branch's commits since \(review.base ?? "its base")"
        case .commit(let c): "\(c.shortSha) · \(c.subject)"
        }
    }
}

/// Nothing to show here, and a way to what the other mode has.
private struct ReviewEmptyState: View {
    let review: DiffReview
    let context: DiffContext

    var body: some View {
        VStack(spacing: Space.md) {
            Image(systemName: "checkmark.circle").font(.system(size: 22, weight: .regular)).foregroundStyle(Color.btTextTertiary)
            Text("No changes to display").font(BTFont.ui(14, .medium)).foregroundStyle(Color.btText)
            Text(review.mode == .uncommitted ? "Everything in the worktree is committed." : "This branch has no commits of its own yet.")
                .font(.btCallout).foregroundStyle(Color.btTextSecondary).multilineTextAlignment(.center)
            if review.otherModeHasChanges {
                Button(review.mode == .uncommitted ? "See committed changes" : "See uncommitted changes") {
                    Task { await review.show(review.mode == .uncommitted ? .committed : .uncommitted, context) }
                }
                .buttonStyle(.bt(.ghost, size: .small))
            }
        }
        .padding(Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

// MARK: - Shared bits

/// `+12 −4` in the diff colours.
struct DiffCounts: View {
    let additions: Int
    let deletions: Int
    var hideZeros = false
    /// Large counts as "1.2k", as Paseo shows them.
    var compact = false

    var body: some View {
        HStack(spacing: 5) {
            if !(hideZeros && additions == 0) {
                Text(verbatim: "+" + format(additions)).foregroundStyle(Color.btAdded)
            }
            if !(hideZeros && deletions == 0) {
                Text(verbatim: "−" + format(deletions)).foregroundStyle(Color.btRemoved)
            }
        }
        .font(.btMonoSmall)
        .monospacedDigit()
    }

    private func format(_ n: Int) -> String {
        guard compact, n >= 1000 else { return String(n) }
        let value = Double(n) / (n >= 1_000_000 ? 1_000_000 : 1000)
        let text = value >= 100 ? String(Int(value.rounded())) : String(format: "%.1f", value).replacingOccurrences(of: ".0", with: "")
        return text + (n >= 1_000_000 ? "m" : "k")
    }
}

/// A file's change as a small square: added, deleted, changed, or moved.
struct DiffStatusIcon: View {
    let status: FileDiff.FileStatus

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(tint)
            .help(status.word)
            .accessibilityLabel(status.word)
    }

    private var symbol: String {
        switch status {
        case .added: "plus.square"
        case .deleted: "minus.square"
        case .modified: "dot.square"
        case .renamed: "arrow.right.square"
        }
    }

    private var tint: Color {
        switch status {
        case .added: .btAdded
        case .deleted: .btRemoved
        case .modified, .renamed: .btTextSecondary
        }
    }
}

/// A/M/D/R as a coloured letter.
struct DiffStatusLetter: View {
    let status: FileDiff.FileStatus
    var size: CGFloat = 11

    var body: some View {
        Text(letter)
            .font(BTFont.mono(size, .bold))
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
        case .modified: .btTextSecondary
        case .deleted: .btRemoved
        case .renamed: .btTextTertiary
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
