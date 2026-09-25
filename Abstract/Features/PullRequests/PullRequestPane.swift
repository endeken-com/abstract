import SwiftUI
import AppKit
import AbstractCore

// MARK: - State marks

extension PullRequest {
    /// `#4438`, never localized: a number, not an amount, so no `4.438`.
    var label: String { "#" + String(number) }

    /// For tooltips: state and number, then how it stands.
    var summary: String { [stateLabel + " pull request " + label, standing].compactMap { $0 }.joined(separator: "\n") }

    var stateLabel: String {
        switch state {
        case .merged: "Merged"
        case .closed: "Closed"
        case .open: isDraft ? "Draft" : "Open"
        }
    }

    var glyph: PullRequestGlyph.Kind {
        switch state {
        case .merged: .merged
        case .closed: .closed
        case .open: isDraft ? .draft : .open
        }
    }

    /// GitHub's state colours, with failed checks taking priority on open PRs.
    var tint: Color {
        switch state {
        case .open where checksSummary.failed > 0: .btRemoved
        default: stateTint
        }
    }

    var stateTint: Color {
        switch state {
        case .open: isDraft ? .btPullRequestDraftInk : .btPullRequestOpenInk
        case .merged: .btPullRequestMergedInk
        case .closed: .btPullRequestClosedInk
        }
    }

    /// One line on how it stands: checks first, then reviews.
    var standing: String? {
        guard state == .open else { return nil }
        let sum = checksSummary
        if sum.failed > 0 { return "\(sum.failed) check\(sum.failed == 1 ? "" : "s") failing" }
        if hasConflicts { return "Conflicts with \(base)" }
        if sum.pending > 0 { return "Checks running" }
        switch reviewDecision {
        case .changesRequested: return "Changes requested"
        case .approved: return "Approved"
        case .reviewRequired: return "Waiting for review"
        case nil: return sum.total > 0 ? "Checks passed" : nil
        }
    }
}

/// The chat's pull request beside its title, as a menu: its number on a
/// soft wash of the state's colour (green open, grey draft, purple merged,
/// red closed), with the pull request's actions behind it.
struct PullRequestPill: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    let sessionId: String
    @State private var hovering = false

    var body: some View {
        Menu {
            Button("Show Pull Request") { model.showPane(.review, in: sessionId) }
            if let url = pr.url {
                Button("Open on GitHub") { NSWorkspace.shared.open(url) }
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
            }
            if pr.state == .open {
                Divider()
                if pr.isDraft {
                    Button("Ready for Review") { act { try await model.markPullRequestReady(sessionId) } }
                } else {
                    Menu("Merge") {
                        Button("Squash and Merge") { act { try await model.mergePullRequest(sessionId, method: .squash) } }
                        Button("Create a Merge Commit") { act { try await model.mergePullRequest(sessionId, method: .merge) } }
                        Button("Rebase and Merge") { act { try await model.mergePullRequest(sessionId, method: .rebase) } }
                    }
                    .disabled(pr.hasConflicts)
                }
                Button("Close Pull Request") { act { try await model.closePullRequest(sessionId) } }
            }
            Divider()
            Button("Refresh") { act { try await model.refreshPullRequest(sessionId) } }
        } label: {
            HStack(spacing: 5) {
                Text(verbatim: pr.label).font(BTFont.ui(12.5, .semibold)).monospacedDigit()
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(ink)
            .padding(.leading, 9)
            .padding(.trailing, 8)
            .frame(height: 24)
            .background(wash.opacity(hovering ? 0.26 : 0.18), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help(pr.summary)
    }

    private var wash: Color {
        switch pr.state {
        case .open: pr.isDraft ? .btPullRequestDraft : .btPullRequestOpen
        case .merged: .btPullRequestMerged
        case .closed: .btPullRequestClosed
        }
    }

    private var ink: Color {
        switch pr.state {
        case .open: pr.isDraft ? .btPullRequestDraftInk : .btPullRequestOpenInk
        case .merged: .btPullRequestMergedInk
        case .closed: .btPullRequestClosedInk
        }
    }

    private func act(_ action: @escaping () async throws -> Void) {
        Task { do { try await action() } catch { model.flash(error.localizedDescription, isError: true) } }
    }
}

/// A pull request's state as a glyph, in the size of a status mark.
struct PullRequestMark: View {
    let pr: PullRequest
    var size: CGFloat = 12

    var body: some View {
        PullRequestGlyph(kind: pr.glyph)
            .foregroundStyle(pr.tint)
            .frame(width: size, height: size)
            .help(pr.summary)
    }
}

/// GitHub's own pull-request marks, from Primer Octicons:
/// open, draft, merged, closed. Template images, so they take the foreground style.
struct PullRequestGlyph: View {
    enum Kind { case open, draft, merged, closed }
    let kind: Kind

    /// Stands for the glyph where a system symbol name is expected.
    static let symbol = "abstract.pullrequest"

    var body: some View {
        Image(nsImage: Self.image(kind)).renderingMode(.template).resizable().aspectRatio(contentMode: .fit)
    }

    /// The 16px mark. Menus draw images, not views, so they take it as is.
    static func image(_ kind: Kind) -> NSImage {
        switch kind {
        case .open: Octicon.gitPullRequest
        case .draft: Octicon.gitPullRequestDraft
        case .merged: Octicon.gitMerge
        case .closed: Octicon.gitPullRequestClosed
        }
    }
}

// MARK: - The chat's Pull Request tab

/// The chat's pull request: how it stands (checks, reviews, comments) with
/// the next step at hand, or a short form to open one.
struct PullRequestPane: View {
    @Environment(AppModel.self) private var model
    @AppStorage("chat.font") private var chatFont: ChatFont = .inter
    let session: Session
    @State private var phase: Phase = .loading
    @State private var working: String?
    @State private var error: String?
    @State private var loadedAt: ContinuousClock.Instant?

    private enum Phase: Equatable { case loading, ready, unavailable(String, String) }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .unavailable(title, message):
                EmptyStateView(symbol: PullRequestGlyph.symbol, title: title, message: message)
            case .ready:
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.lg) {
                        if let error { ErrorLine(text: error) { self.error = nil } }
                        let requests = model.pullRequestsForChat(session.id)
                        if requests.count > 1 {
                            Menu {
                                ForEach(requests) { request in
                                    Button {
                                        run("Loading pull request…") {
                                            try await model.selectPullRequest(session.id, number: request.number)
                                        }
                                    } label: {
                                        Text("\(request.label) · \(request.stateLabel) · \(request.title)")
                                        if request.number == model.pullRequests[session.id]?.number {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            } label: {
                                Label("Pull request \(model.pullRequests[session.id]?.label ?? "")", systemImage: "chevron.down")
                            }
                            .menuStyle(.button)
                            .disabled(working != nil)
                        }
                        let pr = model.pullRequests[session.id]
                        if let pr {
                            PullRequestDetail(session: session, pr: pr, working: $working, run: { run($0, $1) })
                        }
                        // A closed pull request can be followed by a new one.
                        if pr == nil || pr?.state == .closed {
                            CreatePullRequestForm(session: session, working: $working, run: { run($0, $1) })
                        }
                    }
                    .padding(Space.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.btCanvas)
        // Comments read a size down from the chat, to sit with the panel's text.
        .environment(\.proseStyle, ProseStyle(font: chatFont, size: .small))
        .task(id: session.id) {
            await load()
            // While the tab is open, keep checks and reviews current; more
            // often while checks run, to catch them finishing.
            while !Task.isCancelled {
                try? await Task.sleep(for: checksRunning ? .seconds(10) : .seconds(30))
                if !Task.isCancelled { await load() }
            }
        }
        .onChange(of: session.status) { Task { await load() } }
        // Pushed from here, a terminal or the git actions button: the pull
        // request has new commits, and its checks start over.
        .onChange(of: model.branchStates[session.id]?.ahead ?? 0) { old, new in
            if new < old { Task { await load() } }
        }
        // Back from GitHub in the browser, unless it was only just loaded.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard loadedAt.map({ ContinuousClock.now - $0 > .seconds(15) }) ?? true else { return }
            Task { await load() }
        }
    }

    private var checksRunning: Bool {
        guard let pr = model.pullRequests[session.id], pr.state == .open else { return false }
        return pr.checksSummary.pending > 0
    }

    private func load() async {
        loadedAt = .now
        guard model.isDemo || session.branch != nil, let project = model.project(session.projectId) else {
            phase = .unavailable("No branch", "This chat has no worktree branch to open a pull request from.")
            return
        }
        if !model.isDemo {
            // A chat on another Mac uses that Mac's GitHub sign-in.
            let remote = model.remoteLink(for: session.id) != nil
            if model.githubAccess == nil, !remote { model.githubAccess = await GitHub.access(model.executor) }
            switch remote ? await GitHub.access(model.executor(for: session.id)) : model.githubAccess {
            case .missing?:
                phase = .unavailable("GitHub CLI needed", "Install it with `brew install gh`, then run `gh auth login`.")
                return
            case .signedOut?:
                phase = .unavailable("Sign in to GitHub", "Run `gh auth login` in a terminal, then come back here.")
                return
            default: break
            }
            guard await model.isOnGitHub(project) else {
                phase = .unavailable("Not a GitHub repository", "\(project.name)'s origin isn't on GitHub.")
                return
            }
        }
        do {
            if !model.isDemo { await model.refreshPullRequests(projectId: project.id) }
            try await model.refreshPullRequest(session.id)
            phase = .ready
        } catch {
            if phase != .ready { phase = .ready }
            self.error = error.localizedDescription
        }
    }

    /// Runs an action with the tab showing it's busy, and reports a failure in place.
    private func run(_ label: String, _ action: @escaping () async throws -> Void) {
        guard working == nil else { return }
        working = label
        error = nil
        Task {
            do { try await action() } catch { self.error = error.localizedDescription }
            working = nil
        }
    }
}

private struct ErrorLine: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(Color.btRemoved)
            Text(text).font(.btCallout).foregroundStyle(Color.btText).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.icon(size: 20))
        }
    }
}

// MARK: Detail

private struct PullRequestDetail: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let pr: PullRequest
    @Binding var working: String?
    let run: (String, @escaping () async throws -> Void) -> Void
    @State private var publish: (uncommitted: Int, unpushed: Int) = (0, 0)
    @State private var showsBots = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            header
            if !listedChecks.isEmpty { checks }
            RevundPullRequestSection(session: session, pr: pr)
            if !pr.reviews.isEmpty || !pr.comments.isEmpty || !pr.threads.isEmpty || pr.reviewDecision != nil { conversation }
            actions
        }
        .task(id: "\(pr.number)-\(pr.updatedAt?.timeIntervalSince1970 ?? 0)-\(session.status.rawValue)") { await readPublish() }
        // Committed or pushed elsewhere: the Push button follows.
        .onChange(of: model.branchStates[session.id]) { Task { await readPublish() } }
    }

    private func readPublish() async {
        guard let worktree = session.worktreePath, let branch = session.branch, !model.isDemo else { return }
        publish = await Git.publishState(model.executor(for: session.id), worktree: worktree, branch: branch)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                PullRequestMark(pr: pr, size: 12)
                Text(pr.stateLabel).font(.btCallout).foregroundStyle(pr.stateTint)
                Text(verbatim: pr.label).font(.btCallout).foregroundStyle(Color.btTextTertiary)
                Spacer(minLength: Space.sm)
                Button {
                    run("Refreshing…") {
                        await model.refreshPullRequests(projectId: session.projectId)
                        try await model.refreshPullRequest(session.id)
                    }
                } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.icon(size: 24))
                    .disabled(working != nil)
                    .help("Refresh pull request")
                if let url = pr.url {
                    Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.forward.square") }
                        .buttonStyle(.icon(size: 24))
                        .help("Open on GitHub")
                }
            }
            Text(pr.title)
                .font(BTFont.ui(15, .medium))
                .foregroundStyle(Color.btText)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: 6) {
                if let author = pr.author {
                    GitHubAvatar(login: author, size: 16)
                    Text(author).font(.btCallout).foregroundStyle(Color.btTextSecondary).fixedSize()
                }
                Text("\(pr.head) → \(pr.base)").font(.btMonoSmall).foregroundStyle(Color.btTextTertiary)
                    .lineLimit(1).truncationMode(.middle)
                if let additions = pr.additions, let deletions = pr.deletions {
                    DiffCounts(additions: additions, deletions: deletions, hideZeros: true).fixedSize()
                }
            }
            if let standing = pr.standing {
                Text(standing).font(.btCallout).foregroundStyle(pr.checksSummary.failed > 0 ? Color.btRemoved : Color.btTextSecondary)
            }
        }
    }

    /// Revund's checks show in its own section once it has loaded.
    private var listedChecks: [PullRequest.Check] {
        RevundService.shared.pullRequests[session.id] == nil ? pr.checks : pr.checks.filter { !Revund.isCheck($0.name) }
    }

    private var checks: some View {
        let failed = listedChecks.filter { $0.outcome == .failed }
        return VStack(alignment: .leading, spacing: 2) {
            SectionHeading(title: "Checks", detail: summary) {
                if !failed.isEmpty, pr.state == .open {
                    Button("Ask Agent to Fix") { model.askToFixChecks(session.id, failed) }
                        .buttonStyle(.bt(.ghost, size: .small))
                        .help("Send the failing checks to this chat's agent")
                }
            }
            // Failures first, then what's still running.
            ForEach(listedChecks.sorted { order($0.outcome) < order($1.outcome) }) { check in
                CheckRow(check: check)
            }
        }
    }

    private var summary: String {
        let s = pr.checksSummary
        return [(s.failed, "failed"), (s.pending, "running"), (s.passed, "passed"), (s.skipped, "skipped")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
    }

    private func order(_ outcome: PullRequest.Check.Outcome) -> Int {
        switch outcome { case .failed: 0; case .pending: 1; case .passed: 2; case .skipped: 3 }
    }

    /// Threads on the code first (open before resolved), then what was said
    /// on the pull request as a whole, in order. Each reads as one block.
    private var conversation: some View {
        let said = (pr.reviews.filter { !$0.body.isEmpty }.map {
            Said(author: $0.author, verdict: verdict($0.verdict), text: $0.body, date: $0.submittedAt, isBot: false)
        } + pr.comments.map {
            Said(author: $0.author, verdict: nil, text: $0.body, date: $0.createdAt, isBot: $0.isBot)
        }).sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
        // A verdict with nothing written is one quiet line, not a block.
        let verdicts = pr.reviews.filter { $0.body.isEmpty && $0.verdict != .commented && $0.verdict != .pending }
        let people = said.filter { !$0.isBot }
        let bots = said.filter(\.isBot)
        let threads = pr.threads.sorted { !$0.isResolved && $1.isResolved }
        let feedback = people.contains { !$0.text.isEmpty } || threads.contains { !$0.isResolved }
        return VStack(alignment: .leading, spacing: Space.sm) {
            SectionHeading(title: "Reviews", detail: decision) {
                if feedback, pr.state == .open {
                    Button("Send All to Agent") { model.askToAddressReviews(session.id) }
                        .buttonStyle(.bt(.ghost, size: .small))
                        .help("Send the open threads, reviews and comments to this chat's agent")
                }
            }
            ForEach(Array(verdicts.enumerated()), id: \.offset) { _, review in
                HStack(spacing: Space.sm) {
                    GitHubAvatar(login: review.author, size: 18)
                    Text(review.author).font(.btCallout.weight(.semibold)).foregroundStyle(Color.btText)
                    Text(verdict(review.verdict) ?? "").font(.btCallout).foregroundStyle(Color.btTextSecondary)
                    Spacer(minLength: Space.sm)
                    if let date = review.submittedAt { Text(RelativeTime.short(date)).font(.btCaption).foregroundStyle(Color.btTextTertiary) }
                }
                .padding(.horizontal, Space.md)
                .frame(height: 30)
            }
            ForEach(threads) { thread in
                ThreadBlock(thread: thread, canSend: pr.state == .open) { model.askToAddressThread(session.id, thread) }
            }
            ForEach(Array(people.enumerated()), id: \.offset) { _, entry in
                Block { CommentBlock(author: entry.author, verdict: entry.verdict, text: entry.text, date: entry.date) }
            }
            if !bots.isEmpty {
                Button(showsBots ? "Hide automated comments" : "\(bots.count) automated comment\(bots.count == 1 ? "" : "s")") {
                    withAnimation(.snappy(duration: 0.2)) { showsBots.toggle() }
                }
                .buttonStyle(.plain)
                .font(.btCaption)
                .foregroundStyle(Color.btTextTertiary)
                .padding(.horizontal, Space.md)
                .padding(.vertical, Space.xs)
                if showsBots {
                    ForEach(Array(bots.enumerated()), id: \.offset) { _, entry in
                        Block { CommentBlock(author: entry.author, verdict: nil, text: entry.text, date: entry.date) }
                    }
                }
            }
        }
    }

    private struct Said {
        let author: String
        let verdict: String?
        let text: String
        let date: Date?
        let isBot: Bool
    }

    private var decision: String? {
        switch pr.reviewDecision {
        case .approved: "Approved"
        case .changesRequested: "Changes requested"
        case .reviewRequired: "Review required"
        case nil: nil
        }
    }

    private func verdict(_ v: PullRequest.Review.Verdict) -> String? {
        switch v {
        case .approved: "approved"
        case .changesRequested: "requested changes"
        case .commented: nil
        case .dismissed: "review dismissed"
        case .pending: "review pending"
        }
    }

    @ViewBuilder
    private var actions: some View {
        let busy = working != nil
        VStack(alignment: .leading, spacing: Space.sm) {
            Hairline()
            if let working {
                HStack(spacing: Space.sm) {
                    ProgressView().controlSize(.small)
                    Text(working).font(.btCallout).foregroundStyle(Color.btTextSecondary)
                }
                .frame(height: 28)
            } else if pr.state == .open {
                HStack(spacing: Space.sm) {
                    if publish.uncommitted > 0 || publish.unpushed > 0 {
                        Button(pushLabel) {
                            run("Pushing…") { try await model.pushChanges(session.id, message: session.name) }
                        }
                        .buttonStyle(.bt(.secondary, size: .small))
                        .help("Commit what's in the worktree and push it to the pull request")
                    }
                    Spacer(minLength: 0)
                    Button("Close") { run("Closing…") { try await model.closePullRequest(session.id) } }
                        .buttonStyle(.bt(.ghost, size: .small))
                    if pr.isDraft {
                        Button("Ready for Review") { run("Marking ready…") { try await model.markPullRequestReady(session.id) } }
                            .buttonStyle(.bt(.primary, size: .small))
                    } else {
                        Menu {
                            ForEach(MergeMethod.allCases, id: \.self) { method in
                                Button(title(method)) { run("Merging…") { try await model.mergePullRequest(session.id, method: method) } }
                            }
                        } label: {
                            Text("Merge")
                        }
                        .menuStyle(.button)
                        .buttonStyle(.bt(.primary, size: .small))
                        .fixedSize()
                        .disabled(pr.hasConflicts)
                        .help(pr.hasConflicts ? "Resolve the conflicts with \(pr.base) first" : "Merge on GitHub")
                    }
                }
                .disabled(busy)
            }
        }
    }

    private var pushLabel: String {
        publish.uncommitted > 0 ? "Commit and Push" : "Push \(publish.unpushed) Commit\(publish.unpushed == 1 ? "" : "s")"
    }

    private func title(_ method: MergeMethod) -> String {
        switch method {
        case .squash: "Squash and Merge"
        case .merge: "Create a Merge Commit"
        case .rebase: "Rebase and Merge"
        }
    }
}

struct SectionHeading<Accessory: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: Space.sm) {
            Text(title).font(.btBodyMedium).foregroundStyle(Color.btText)
            if let detail { Text(detail).font(.btCaption).foregroundStyle(Color.btTextTertiary).lineLimit(1) }
            Spacer(minLength: Space.sm)
            accessory
        }
        .frame(minHeight: 26)
    }
}

private struct CheckRow: View {
    let check: PullRequest.Check
    @State private var hovering = false

    var body: some View {
        Button { if let url = check.url { NSWorkspace.shared.open(url) } } label: {
            HStack(spacing: Space.sm) {
                glyph.frame(width: 14)
                Text(check.name).font(.btCallout).foregroundStyle(hovering ? Color.btText : Color.btTextSecondary).lineLimit(1)
                if let workflow = check.workflow {
                    Text(workflow).font(.btCaption).foregroundStyle(Color.btTextTertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if check.url != nil {
                    Image(systemName: "arrow.up.forward").font(.system(size: 9)).foregroundStyle(Color.btTextTertiary)
                        .opacity(hovering ? 1 : 0)
                }
            }
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(check.url == nil ? check.name : "Open the check's log")
    }

    @ViewBuilder
    private var glyph: some View {
        switch check.outcome {
        case .passed: Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.btTextSecondary)
        case .failed: Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.btRemoved)
        case .pending: ProgressView().controlSize(.mini)
        case .skipped: Image(systemName: "minus").font(.system(size: 10)).foregroundStyle(Color.btTextTertiary)
        }
    }
}

/// One unit of feedback on a quiet fill, so where it starts and ends is plain.
private struct Block<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.btSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Who, what they decided, when, and then what they said, set under their name.
private struct CommentBlock: View {
    let author: String
    var avatar: URL? = nil
    let verdict: String?
    let text: String
    let date: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Space.sm) {
                GitHubAvatar(login: author, url: avatar, size: 18)
                Text(author).font(.btCallout.weight(.semibold)).foregroundStyle(Color.btText).lineLimit(1)
                if let verdict { Text(verdict).font(.btCallout).foregroundStyle(Color.btTextSecondary).lineLimit(1) }
                Spacer(minLength: Space.sm)
                if let date { Text(RelativeTime.short(date)).font(.btCaption).foregroundStyle(Color.btTextTertiary).fixedSize() }
            }
            if !text.isEmpty {
                AgentProse(markdown: text).padding(.leading, 26)
            }
        }
    }
}

/// A thread on the code as one block: the file and line, the code it's
/// about, then each comment in order. Resolved threads fold to their header.
private struct ThreadBlock: View {
    let thread: PullRequest.ReviewThread
    let canSend: Bool
    let send: () -> Void
    @State private var open: Bool?
    @State private var hovering = false

    var body: some View {
        let expanded = open ?? !thread.isResolved
        Block {
            HStack(spacing: Space.sm) {
                Button { withAnimation(.snappy(duration: 0.2)) { open = !expanded } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Color.btTextTertiary).rotationEffect(.degrees(expanded ? 90 : 0))
                        Text((thread.path as NSString).lastPathComponent).font(.btMonoSmall).foregroundStyle(Color.btText).lineLimit(1)
                        if let line = thread.line ?? thread.originalLine {
                            Text("line \(line)").font(.btCaption).foregroundStyle(Color.btTextTertiary).fixedSize()
                        }
                        if thread.isResolved { Tag(text: "Resolved") } else if thread.isOutdated { Tag(text: "Outdated") }
                        Spacer(minLength: Space.sm)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(thread.path)
                if canSend, !thread.isResolved {
                    Button("Send to Agent", action: send)
                        .buttonStyle(.bt(.ghost, size: .small))
                        .help("Ask this chat's agent to address the thread")
                        .opacity(hovering ? 1 : 0)
                } else if !expanded {
                    Text("\(thread.comments.count)").font(.btCaption).foregroundStyle(Color.btTextTertiary)
                        .help("\(thread.comments.count) comment\(thread.comments.count == 1 ? "" : "s")")
                }
            }
            if expanded {
                if let hunk = thread.diffHunk { HunkExcerpt(hunk: hunk, endLine: thread.line ?? thread.originalLine).padding(.top, Space.sm) }
                ForEach(Array(thread.comments.enumerated()), id: \.element.id) { index, comment in
                    CommentBlock(author: comment.author, avatar: comment.avatar, verdict: nil, text: comment.body, date: comment.createdAt)
                        .padding(.top, Space.md)
                        .overlay(alignment: .top) { if index > 0 { Hairline().padding(.top, Space.md / 2) } }
                }
            }
        }
        .onHover { hovering = $0 }
    }
}

private struct Tag: View {
    let text: String
    var body: some View {
        Text(text).font(.btCaption).foregroundStyle(Color.btTextSecondary)
            .padding(.horizontal, 6).frame(height: 17)
            .background(Color.btHover, in: Capsule())
            .fixedSize()
    }
}

/// The last lines of the diff a thread was left on, ending at its line,
/// numbered on the new side.
private struct HunkExcerpt: View {
    let hunk: String
    /// The thread's line: GitHub's hunk ends on it, so numbering counts back from it.
    let endLine: Int?

    var body: some View {
        let rows = Self.rows(hunk, endLine: endLine).suffix(3)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 0) {
                    Text(row.number.map(String.init) ?? "")
                        .font(.btMonoSmall).foregroundStyle(Color.btTextTertiary)
                        .frame(width: 30, alignment: .trailing).padding(.trailing, 8)
                    Text(row.text.isEmpty ? " " : row.text)
                        .font(.btMonoSmall)
                        .foregroundStyle(row.kind == .context ? Color.btTextSecondary : Color.btText)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 2)
                .background(row.kind == .added ? Color.btAddedWash : row.kind == .removed ? Color.btRemovedWash : .clear)
            }
        }
        .padding(.vertical, 4)
        .background(Color.btCanvas, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private enum Kind { case context, added, removed }
    private struct Row { let kind: Kind; let number: Int?; let text: String }

    /// The hunk's lines after its `@@` header, numbered on the new side so
    /// the last one is `endLine` (or counted from the header without it).
    private static func rows(_ hunk: String, endLine: Int?) -> [Row] {
        var lines = hunk.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let header = lines.first, header.hasPrefix("@@") else { return [] }
        lines.removeFirst()
        let newSide = lines.filter { $0.first != "-" }.count
        let start = header.split(separator: "+").dropFirst().first.flatMap { Int($0.prefix { $0.isNumber }) } ?? 1
        var number = endLine.map { $0 - newSide + 1 } ?? start
        return lines.map { line in
            let text = String(line.dropFirst())
            switch line.first {
            case "+": defer { number += 1 }; return Row(kind: .added, number: number, text: text)
            case "-": return Row(kind: .removed, number: nil, text: text)
            default: defer { number += 1 }; return Row(kind: .context, number: number, text: text)
            }
        }
    }
}

// MARK: Opening one

private struct CreatePullRequestForm: View {
    @Environment(AppModel.self) private var model
    let session: Session
    @Binding var working: String?
    let run: (String, @escaping () async throws -> Void) -> Void
    @State private var title = ""
    @State private var summary = ""
    @State private var base = ""
    @State private var draft = false
    @State private var publish: (uncommitted: Int, unpushed: Int) = (0, 0)

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.pullRequests[session.id] == nil ? "No pull request yet" : "Open a new pull request").font(BTFont.ui(15, .medium)).foregroundStyle(Color.btText)
                Text(state).font(.btCallout).foregroundStyle(Color.btTextSecondary).fixedSize(horizontal: false, vertical: true)
            }
            BTTextField("Title", text: $title, prompt: "Title")
            BTTextEditor(text: $summary, placeholder: "What changed, and why (optional)", minHeight: 96)
            HStack(spacing: Space.sm) {
                Text("Into").font(.btCallout).foregroundStyle(Color.btTextSecondary)
                BTTextField("Base branch", text: $base, prompt: "default branch", mono: true, compact: true)
                    .frame(maxWidth: 180)
                Spacer(minLength: 0)
                Toggle("Draft", isOn: $draft).toggleStyle(.checkbox).font(.btCallout)
            }
            HStack {
                if let working {
                    ProgressView().controlSize(.small)
                    Text(working).font(.btCallout).foregroundStyle(Color.btTextSecondary)
                }
                Spacer(minLength: 0)
                Button("Create Pull Request") {
                    let (t, b, into, d, commit) = (title.trimmingCharacters(in: .whitespaces), summary, base.trimmingCharacters(in: .whitespaces), draft, publish.uncommitted > 0)
                    run(commit ? "Committing, pushing and opening…" : "Pushing and opening…") {
                        try await model.createPullRequest(session.id, title: t, body: b, base: into.isEmpty ? nil : into, draft: d, commitFirst: commit)
                    }
                }
                .buttonStyle(.bt(.primary, size: .small))
                .disabled(working != nil || title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear {
            if title.isEmpty { title = session.name }
            if base.isEmpty { base = Self.branchName(session.baseRef) ?? model.project(session.projectId).flatMap { Self.branchName($0.defaultBaseRef) } ?? "" }
        }
        .task(id: session.status) { await readPublish() }
        .onChange(of: model.branchStates[session.id]) { Task { await readPublish() } }
    }

    private func readPublish() async {
        guard let worktree = session.worktreePath, let branch = session.branch, !model.isDemo else { return }
        publish = await Git.publishState(model.executor(for: session.id), worktree: worktree, branch: branch)
    }

    private var state: String {
        let branch = session.branch ?? "This branch"
        switch (publish.uncommitted, publish.unpushed) {
        case (0, 0): return "\(branch) is up to date with GitHub."
        case (let files, 0): return "\(files) changed file\(files == 1 ? "" : "s") in \(branch) will be committed as the title, then pushed."
        case (0, let commits): return "\(commits) commit\(commits == 1 ? "" : "s") in \(branch) will be pushed."
        case (let files, let commits): return "\(files) changed file\(files == 1 ? "" : "s") will be committed and \(commits + 1) commits pushed from \(branch)."
        }
    }

    /// A base the chat started from, when it names a branch (not HEAD or a commit).
    private static func branchName(_ ref: String?) -> String? {
        guard let ref, !ref.isEmpty, ref != "HEAD", ref.range(of: "^[0-9a-f]{7,40}$", options: .regularExpression) == nil else { return nil }
        return ref.hasPrefix("origin/") ? String(ref.dropFirst(7)) : ref
    }
}
