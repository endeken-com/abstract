import SwiftUI
import AppKit
import AbstractCore

/// A button with a menu beside it, as Paseo draws its header actions: one
/// hairline frame, the action on the left, a chevron for the rest.
struct SplitButton<Label: View, Items: View>: View {
    let help: String
    var muted = false
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @ViewBuilder let items: () -> Items
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                label()
                    .padding(.horizontal, 8)
                    .frame(minWidth: 26, maxHeight: .infinity)
                    .background(hovering ? Color.btHover : .clear)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(muted ? 0.6 : 1)
            .onHover { hovering = $0 }
            .help(help)
            Rectangle().fill(Color.btBorder).frame(width: 1)
            Menu { items() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.btTextTertiary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .frame(width: 24)
        }
        .frame(height: 26)
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.btBorderStrong, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .fixedSize()
    }
}

// MARK: - Open in editor

/// The worktree (or the file showing, at the caret's line) in your editor.
/// The chevron picks which one; the choice is remembered.
struct OpenInEditorButton: View {
    @Environment(AppModel.self) private var model
    let session: Session
    @AppStorage("editor.preferred") private var preferred = ""

    private var editors: [ExternalEditor] { ExternalEditors.installed }
    private var current: ExternalEditor? {
        editors.first { $0.id == preferred } ?? editors.first { $0.isEditor } ?? editors.first
    }

    var body: some View {
        if let current, let worktree = session.worktreePath {
            SplitButton(help: "Open in \(current.name)") {
                open(current, worktree)
            } label: {
                EditorIcon(editor: current)
            } items: {
                ForEach(editors) { editor in
                    Button {
                        preferred = editor.id
                        open(editor, worktree)
                    } label: {
                        if let icon = editor.icon { Image(nsImage: resized(icon)) }
                        Text(editor.name)
                        if editor.id == current.id { Image(systemName: "checkmark") }
                    }
                }
            }
        }
    }

    private func open(_ editor: ExternalEditor, _ worktree: String) {
        var file: String?
        var line: Int?
        if case let .file(sessionId, path)? = model.activeTab?.kind, sessionId == session.id {
            file = FileIndex.join(worktree, path)
            line = model.activeFileDocument?.line
        }
        ExternalEditors.open(editor, worktree: worktree, file: file, line: line)
    }

    private func resized(_ image: NSImage) -> NSImage {
        let copy = image.copy() as! NSImage
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }
}

private struct EditorIcon: View {
    let editor: ExternalEditor

    var body: some View {
        if let icon = editor.icon {
            Image(nsImage: icon).resizable().frame(width: 16, height: 16)
        } else {
            Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: 11))
        }
    }
}

// MARK: - Git actions

/// What can be done with a chat's branch, after Paseo's git actions button:
/// the likeliest next step as the button (commit, then pull, push, open a
/// pull request…), the rest in its menu, each saying why when it can't run.
struct GitActionsButton: View {
    @Environment(AppModel.self) private var model
    let session: Session
    @State private var running: GitAction?
    @State private var onGitHub = false
    @State private var watcher: AnyObject?
    @State private var pendingRead: Task<Void, Never>?

    typealias GitAction = GitActions.Step

    /// Shared with the Pull Request tab, which reads it too.
    private var state: BranchState? { model.branchStates[session.id] }
    private var pr: PullRequest? { model.pullRequests[session.id] }

    var body: some View {
        let primary = primaryAction
        SplitButton(help: reason(primary) ?? why(primary) ?? title(primary), muted: reason(primary) != nil) {
            perform(primary)
        } label: {
            HStack(spacing: 5) {
                if running != nil {
                    ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 14, height: 14)
                } else {
                    glyph(primary)
                }
                Text(running.map(pendingTitle) ?? title(primary)).font(BTFont.ui(13)).foregroundStyle(Color.btText)
            }
        } items: {
            item(.pull)
            item(.push)
            item(.pullAndPush)
            Divider()
            item(.updateFromBase)
            item(.mergeLocally)
            item(pr == nil || pr?.state == .closed ? .createPR : .viewPR)
            Divider()
            Button { model.requestArchive = session.id } label: {
                Label { Text("Archive Chat") } icon: { Image(nsImage: Octicon.archive) }
            }
            .keyboardShortcut(.delete, modifiers: [.command, .shift])
        }
        .disabled(running != nil)
        .task(id: "\(session.id)|\(session.status.rawValue)") {
            await refresh(fetch: .ifStale)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if !Task.isCancelled { await refresh(fetch: .ifStale) }
            }
        }
        .task(id: session.worktreePath) { await watch() }
        // Back from the terminal or the browser: see what happened there.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                await model.refreshPullRequestsIfStale(projectId: session.projectId)
                await refresh(fetch: .ifStale)
            }
        }
        // Merged or closed on GitHub: the base (or the branch) moved there.
        .onChange(of: pr.map { GitActions.PullRequestStanding($0) }) { old, new in
            guard old != nil, new == .merged || new == .closed else { return }
            Task { await refresh(fetch: .now) }
        }
    }

    @ViewBuilder
    private func item(_ action: GitAction) -> some View {
        let why = reason(action)
        Button { perform(action) } label: {
            Label { Text(title(action)); if let why { Text(why) } } icon: { menuIcon(action) }
        }
        .disabled(why != nil)
    }

    /// Menus draw images, not views: every icon goes in as a template image.
    private func menuIcon(_ action: GitAction) -> some View {
        Image(nsImage: icon(action))
    }

    /// Open, draft, merged or closed: the chat's pull request as it stands.
    private var prKind: PullRequestGlyph.Kind { pr?.glyph ?? .open }

    // MARK: Policy

    private var primaryAction: GitAction {
        guard let s = state else { return .commit }
        return GitActions.suggestion(s, pullRequest: pr.map { GitActions.PullRequestStanding($0) }, onGitHub: onGitHub)
    }

    /// Why the button suggests an action, for its tooltip.
    private func why(_ action: GitAction) -> String? {
        guard let s = state else { return nil }
        let base = s.baseName ?? "the base branch"
        func commits(_ n: Int) -> String { "\(n) commit\(n == 1 ? "" : "s")" }
        switch action {
        case .commit: return s.dirty ? "Commit the changes in the worktree" : nil
        case .pull: return "Pull \(commits(s.behind)) new on origin"
        case .push: return "Push \(commits(s.ahead)) origin doesn't have yet"
        case .pullAndPush: return "Pull \(commits(s.behind)) from origin, then push \(commits(s.ahead))"
        case .updateFromBase:
            let conflicts = pr.flatMap { $0.hasConflicts ? ", which \($0.label) conflicts with" : nil } ?? ""
            return "Merge \(commits(s.behindBase)) from \(base)\(conflicts)"
        case .mergeLocally: return "Merge \(commits(s.aheadOfBase)) into \(base)"
        case .createPR: return "Push and open a pull request for \(commits(s.aheadOfBase))"
        case .viewPR: return pr?.summary
        case .archive: return pr.map { "\($0.label) was merged. Archive this chat" }
        }
    }

    /// Why an action can't run now; nil when it can.
    private func reason(_ action: GitAction) -> String? {
        guard let s = state else { return "Checking the branch…" }
        let base = s.baseName ?? "the base branch"
        switch action {
        case .commit: return s.dirty ? nil : "Nothing to commit"
        case .pull:
            if s.upstreamGone { return "Its branch on origin was deleted" }
            if !s.hasUpstream { return "This branch isn't on origin yet" }
            return s.behind > 0 ? nil : "Already up to date"
        case .push:
            if !s.hasOrigin { return "This repository has no origin" }
            return s.ahead > 0 ? nil : "Nothing new to send"
        case .pullAndPush:
            if s.upstreamGone { return "Its branch on origin was deleted" }
            if !s.hasUpstream { return "This branch isn't on origin yet" }
            return s.ahead > 0 || s.behind > 0 ? nil : "Already in step with origin"
        case .updateFromBase:
            if s.dirty { return "Commit first" }
            return s.behindBase > 0 ? nil : "Already has everything from \(base)"
        case .mergeLocally:
            if s.dirty { return "Commit first" }
            return s.aheadOfBase > 0 ? nil : "No commits to merge into \(base)"
        case .createPR:
            if !onGitHub { return "This project isn't on GitHub" }
            return s.aheadOfBase > 0 || s.dirty ? nil : "This branch has no new commits yet"
        case .viewPR, .archive: return nil
        }
    }

    private func title(_ action: GitAction) -> String {
        let base = state?.baseName ?? "Base"
        return switch action {
        case .commit: "Commit"
        case .pull: "Pull"
        case .push: "Push"
        case .pullAndPush: "Pull and Push"
        case .updateFromBase: "Update from \(base)"
        case .mergeLocally: "Merge into \(base)"
        case .createPR: "Create PR"
        case .viewPR: pr.map { "View \($0.label)" } ?? "View PR"
        case .archive: "Archive Chat"
        }
    }

    private func pendingTitle(_ action: GitAction) -> String {
        switch action {
        case .commit: "Committing…"
        case .pull: "Pulling…"
        case .push: "Pushing…"
        case .pullAndPush: "Syncing…"
        case .updateFromBase: "Updating…"
        case .mergeLocally: "Merging…"
        case .createPR, .viewPR, .archive: title(action)
        }
    }

    private func icon(_ action: GitAction) -> NSImage {
        switch action {
        case .commit: Octicon.gitCommit
        case .pull: Octicon.arrowDown
        case .push: Octicon.arrowUp
        case .pullAndPush: Octicon.arrowSwitch
        case .updateFromBase: Octicon.sync
        case .mergeLocally: Octicon.gitMerge
        case .createPR, .viewPR: PullRequestGlyph.image(prKind)
        case .archive: Octicon.archive
        }
    }

    private func glyph(_ action: GitAction) -> some View {
        let tint = (action == .createPR || action == .viewPR)
            ? pr?.tint ?? Color.btTextSecondary
            : Color.btTextSecondary
        return Image(nsImage: icon(action)).renderingMode(.template).resizable()
            .frame(width: 13, height: 13).foregroundStyle(tint)
    }

    // MARK: Running

    /// The base comparison needs fresh remote refs when main moves elsewhere,
    /// so this fetches too; `.ifStale` keeps it to once a minute.
    private func refresh(fetch: AppModel.OriginFetch = .never) async {
        if let project = model.project(session.projectId) { onGitHub = await model.isOnGitHub(project) }
        await model.refreshBranch(session.id, fetch: fetch)
    }

    /// Re-read as soon as files change or the branch moves, from here or a
    /// terminal: the worktree, its git folder, and the shared refs (pushes).
    private func watch() async {
        guard let worktree = session.worktreePath else { return }
        let exec = model.executor(for: session.id)
        func dir(_ flag: String) async -> String? {
            guard let out = try? await exec.run("git", ["rev-parse", flag], cwd: worktree), out.ok else { return nil }
            return out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let gitDir = await dir("--absolute-git-dir")
        let refs = await dir("--git-common-dir").map { (($0 as NSString).isAbsolutePath ? $0 : worktree + "/" + $0) + "/refs" }
        watcher = model.watch([worktree] + [gitDir, refs].compactMap { $0 }, for: session.id) {
            // An agent writing files calls this often: one read per half second.
            guard pendingRead == nil else { return }
            pendingRead = Task {
                try? await Task.sleep(for: .milliseconds(500))
                await model.refreshBranch(session.id)
                pendingRead = nil
            }
        }
    }

    private func perform(_ action: GitAction) {
        if let why = reason(action) { model.flash(why); return }
        switch action {
        case .createPR, .viewPR:
            model.showPane(.review, in: session.id)
            return
        case .archive:
            model.requestArchive = session.id
            return
        default:
            break
        }
        guard let worktree = session.worktreePath else { return }
        let exec = model.executor(for: session.id)
        running = action
        Task {
            defer { running = nil }
            do {
                switch action {
                case .commit:
                    // The chat's name already says what it did, in a few words.
                    let message = String(session.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(72))
                    try await Git.commitAll(exec, worktree: worktree, message: message.isEmpty ? "Update files" : message)
                    model.flash("Committed")
                case .pull:
                    try await GitActions.pull(exec, worktree: worktree)
                    model.flash("Pulled")
                case .push:
                    guard let branch = session.branch else { return }
                    try await Git.push(exec, worktree: worktree, branch: branch)
                    model.flash("Pushed")
                case .pullAndPush:
                    guard let branch = session.branch else { return }
                    try await GitActions.pull(exec, worktree: worktree)
                    try await Git.push(exec, worktree: worktree, branch: branch)
                    model.flash("Pulled and pushed")
                case .updateFromBase:
                    guard let base = state?.base else { return }
                    try await GitActions.updateFromBase(exec, worktree: worktree, base: base)
                    model.flash("Updated from \(state?.baseName ?? base)")
                case .mergeLocally:
                    guard let base = state?.base, let branch = session.branch,
                          let root = model.project(session.projectId)?.rootPath else { return }
                    try await GitActions.mergeLocally(exec, root: root, branch: branch, base: base)
                    model.flash("Merged into \(state?.baseName ?? base)")
                case .createPR, .viewPR, .archive:
                    break
                }
            } catch {
                model.flash(error.localizedDescription, isError: true)
            }
            await refresh()
            // New commits on the branch restart its pull request's checks.
            if pr != nil, [.push, .pullAndPush].contains(action) {
                await model.refreshPullRequests(projectId: session.projectId)
                _ = try? await model.refreshPullRequest(session.id)
            }
        }
    }
}
