import Foundation
import AbstractCore

/// Pull requests for chats, from each project's code host (ABS-139): the
/// plugin that handles its `origin`, like the bundled GitHub one. One list
/// per project, every minute, tells each chat whether its branch has a pull
/// request and how it stands; a chat's Pull Request tab loads the full
/// detail (checks, reviews, comments) when it opens. With no code host for
/// a project, nothing is asked.
extension AppModel {
    private static let refreshInterval: Duration = .seconds(60)

    func watchPullRequests() async {
        guard !isDemo else { return }
        while !Task.isCancelled {
            await refreshPullRequests()
            // Followed pull requests are read in full, so their new
            // comments reach the plugin following them (ABS-109).
            await refreshSwitchedPullRequests()
            // A code host plugin whose script is still starting is asked again soon.
            try? await Task.sleep(for: codeHostsStarting ? .seconds(3) : Self.refreshInterval)
        }
    }

    /// Re-reads every project's recent pull requests from its code host and matches them to chats by branch.
    func refreshPullRequests(projectId: String? = nil) async {
        for project in projects where project.archivedAt == nil && (projectId == nil || project.id == projectId) {
            let branches = sessions.filter { $0.projectId == project.id }.compactMap(\.branch)
            guard let host = await codeHost(for: project), await !codeHostAccess(host).blocks,
                  let list = try? await host.pullRequests(branches: branches) else { continue }
            projectPullRequests[project.id] = list
            pullRequestsListedAt[project.id] = .now
            for session in sessions where session.projectId == project.id {
                defer { if let pr = pullRequests[session.id] { recordPullRequest(session, pr) } }
                let matches = pullRequestsForChat(session.id)
                let current = pullRequests[session.id]
                // An open pull request before a finished one; a newer one
                // opened after the chat's was closed or merged takes its place.
                let open = matches.first { $0.state == .open }
                if let open, let current, current.state != .open, open.number > current.number,
                   pinnedPullRequests[session.id] != current.number {
                    pullRequests[session.id] = open
                    continue
                }
                // Keep a selected PR if it falls beyond the recent-list limit
                // or has not appeared in the list just after creation.
                guard let summary = matches.first(where: { $0.number == current?.number })
                    ?? (current == nil ? open ?? matches.first : nil) else { continue }
                guard let known = pullRequests[session.id], known.number == summary.number else {
                    pullRequests[session.id] = summary
                    continue
                }
                pullRequests[session.id] = known.refreshingSummary(with: summary)
            }
        }
    }

    /// The chat's turns belong to its pull request, and, once it's merged,
    /// so does the commit it became on its base branch.
    private func recordPullRequest(_ session: Session, _ pr: PullRequest) {
        turnRecorder.notePullRequest(session.id, number: pr.number, body: pr.body, branch: session.branch)
        if pr.state == .merged, let sha = pr.mergeCommit { turnRecorder.linkMerge(session.id, number: pr.number, sha: sha) }
    }

    /// Lists the project's pull requests again unless that happened in the last `interval`.
    func refreshPullRequestsIfStale(projectId: String?, interval: Duration = .seconds(20)) async {
        guard !isDemo, let projectId else { return }
        if let listed = pullRequestsListedAt[projectId], ContinuousClock.now - listed < interval { return }
        await refreshPullRequests(projectId: projectId)
    }

    func pullRequestsForChat(_ sessionId: String) -> [PullRequest] {
        guard let session = session(sessionId), let branch = session.branch,
              let projectId = session.projectId else { return [] }
        return (projectPullRequests[projectId] ?? []).filter { $0.head == branch }
    }

    func selectPullRequest(_ sessionId: String, number: Int) async throws {
        guard let summary = pullRequestsForChat(sessionId).first(where: { $0.number == number }) else { return }
        pinnedPullRequests[sessionId] = number
        pullRequests[sessionId] = summary
        try await refreshPullRequest(sessionId)
    }

    /// The chat's pull request in full; nil when its branch has none.
    @discardableResult
    func refreshPullRequest(_ sessionId: String) async throws -> PullRequest? {
        guard !isDemo else { return pullRequests[sessionId] }
        guard let session = session(sessionId), let branch = session.branch, let project = project(session.projectId),
              let host = await codeHost(for: project, chatId: sessionId) else { return nil }
        let selected = pullRequests[sessionId]?.number
        var pr: PullRequest?
        if let selected {
            pr = try await host.pullRequest(number: selected)
        } else {
            pr = try await host.pullRequest(branch: branch)
        }
        if let number = pr?.number, host.answers(.reviewThreads) {
            pr?.threads = (try? await host.reviewThreads(number: number)) ?? []
        }
        if pullRequests[sessionId]?.number == selected { pullRequests[sessionId] = pr }
        return pr
    }

    // MARK: The branch

    enum OriginFetch { case never, ifStale, now }

    /// Fetches `directory`'s origin: `.ifStale` at most once a minute per
    /// `key`, `.now` regardless. Offline (or any other failure) never blocks
    /// reading the branch state, so a failed fetch is silently skipped. Never
    /// asks for credentials, gives up after 30 seconds.
    func fetchOriginIfDue(_ exec: any Executor, key: String, directory: String, fetch: OriginFetch) async {
        let stale = originFetchedAt[key].map { ContinuousClock.now - $0 >= .seconds(60) } ?? true
        guard fetch == .now || (fetch == .ifStale && stale) else { return }
        originFetchedAt[key] = .now
        let spec = LaunchSpec(command: "git", args: ["fetch", "--quiet", "--prune", "origin"], cwd: directory,
                              env: ["GIT_TERMINAL_PROMPT": "0"], keepStdinOpen: false)
        // A background read's fetch counts against the background budget too.
        if let reader = exec as? BudgetedExecutor {
            _ = try? await reader.budget.run(in: directory, what: "`git fetch`", timeout: .seconds(30)) {
                try await reader.base.run(spec, timeout: .seconds(30))
            }
        } else {
            _ = try? await exec.run(spec, timeout: .seconds(30))
        }
    }

    /// Re-reads where a chat's branch stands, fetching from origin first:
    /// `.ifStale` at most once a minute per project, `.now` regardless.
    /// Pruned, so a branch deleted on origin (a merged PR's) shows as gone.
    func refreshBranch(_ sessionId: String, fetch: OriginFetch = .never) async {
        guard let session = session(sessionId), let worktree = session.worktreePath else { return }
        let exec = reader(for: sessionId)
        await fetchOriginIfDue(exec, key: session.projectId ?? sessionId, directory: worktree, fetch: fetch)
        let read = (branchReads[sessionId] ?? 0) + 1
        branchReads[sessionId] = read
        let state = await GitActions.state(exec, worktree: worktree, preferredBase: session.baseRef)
        guard branchReads[sessionId] == read else { return }
        if let moved = state.movedBranch(from: session.branch) { followBranch(sessionId, to: moved) }
        if branchStates[sessionId] != state { branchStates[sessionId] = state }
        await refreshCurrentSubmodule(sessionId, worktree: worktree, exec: exec, fetch: fetch, read: read)
    }

    /// The chat's worktree is on another branch than it records (the agent
    /// renamed it, or switched): the chat records that one, so Push and the
    /// Pull Request tab use it. A chat on another Mac is that Mac's to update.
    /// Never onto its base: Push would then push straight to it.
    func followBranch(_ sessionId: String, to branch: String) {
        guard !sessionId.hasPrefix(RemoteService.mirrorPrefix), var session = session(sessionId), session.branch != branch,
              BranchState.mayFollow(branch, bases: [session.baseRef, project(session.projectId)?.defaultBaseRef,
                                                    branchStates[sessionId]?.base]) else { return }
        session.branch = branch
        try? store.save(session)
        // The old branch's pull request isn't this one's.
        pullRequests[sessionId] = nil
        pinnedPullRequests[sessionId] = nil
        reload()
    }

    /// Before the chat's branch is pushed or proposed: the one its worktree
    /// is on now, should the agent have renamed it since the last read.
    func followWorktreeBranch(_ sessionId: String) async {
        guard let worktree = session(sessionId)?.worktreePath,
              let current = try? await Git.currentBranch(executor(for: sessionId), root: worktree) else { return }
        followBranch(sessionId, to: current)
    }

    // MARK: The code host

    /// The project's `origin`, read once per run; nil when it has none.
    func origin(of project: Project) async -> String? {
        if let known = projectOrigins[project.id] { return known.isEmpty ? nil : known }
        let origin = await Git.originURL(executor(forProject: project.id), root: project.rootPath)
        projectOrigins[project.id] = origin ?? ""
        return origin
    }

    /// The project's code host: the enabled plugin that handles its
    /// `origin`, with its script running. `chatId` names the chat a call is
    /// about, so its commands run in that chat's worktree, on its Mac.
    func codeHost(for project: Project, chatId: String? = nil) async -> CodeHost? {
        let origin = await origin(of: project)
        if let origin { plugins.enableBitbucketForRemote(origin) }
        return codeHost(remote: origin, context: CodeHostContext(projectKey: pluginProjectKey(project.id), chatId: chatId))
    }

    /// What PR screens say about a project without a code host: the host
    /// its origin is on, or that it has none.
    func codeHostMissing(_ project: Project) async -> String {
        guard let origin = await origin(of: project) else { return "\(project.name) has no origin to open pull requests on." }
        return CodeHosts.needsPlugin(GitRemote.host(origin))
    }

    /// Whether the code host's tool is there and signed in on this Mac,
    /// asked once a minute at most per plugin; `fresh` asks again now. It is
    /// asked in no folder, as it's about the tool and not any one chat. A
    /// call that couldn't be made isn't kept.
    func codeHostAccess(_ host: CodeHost, fresh: Bool = false) async -> CodeHostAccess {
        if !fresh, let known = codeHostAccess[host.pluginId],
           known.access.isReady || ContinuousClock.now - known.at < .seconds(60) { return known.access }
        let access = await codeHost(pluginId: host.pluginId, declaration: host.declaration, context: CodeHostContext()).access()
        if case .unavailable = access { return access }
        codeHostAccess[host.pluginId] = (access, .now)
        return access
    }

    /// Who is signed in to each code host, for "Yours" on the Pull Requests screen.
    var codeHostViewers: Set<String> {
        Set(codeHostAccess.values.compactMap { if case .ready(let viewer) = $0.access { viewer } else { nil } })
    }

    /// A code host plugin is on but its script isn't running yet.
    var codeHostsStarting: Bool {
        plugins.usable.contains { $0.manifest?.contributes.codeHost != nil && pluginBackground?.isRunning($0.id) != true }
    }

    /// Whether you can push to `owner/name`, asked of its code host once
    /// per run. Unknown (and asked again later) while it can't say.
    func access(to slug: String) async -> RepoAccess {
        if let known = repoAccess[slug] { return known }
        guard !isDemo, let host = codeHost(remote: "https://github.com/\(slug)", context: CodeHostContext()),
              host.answers(.pushAccess) else { return .unknown }
        let found = await host.pushAccess(slug: slug)
        if found != .unknown { repoAccess[slug] = found }
        return found
    }

    // MARK: Actions

    func createPullRequest(_ sessionId: String, title: String, body: String, base: String?, draft: Bool, commitFirst: Bool) async throws {
        await followWorktreeBranch(sessionId)
        guard let session = session(sessionId), let branch = session.branch, let worktree = session.worktreePath,
              let project = project(session.projectId) else { return }
        // Its submodules committed and pushed first, and its pointers checked, before the branch goes.
        // The Pull Request tab shows the worktree's own pull request for now.
        if commitFirst { try await commitEverything(sessionId, in: "", message: title) }
        try await prepareParentPush(sessionId, in: "")
        guard let host = await codeHost(for: project, chatId: sessionId) else { throw CodeHostError.noHost(nil) }
        // Plain git stays here: the branch is pushed, then the code host opens the pull request.
        try await Git.push(executor(for: sessionId), worktree: worktree, branch: branch)
        pullRequests[sessionId] = try await host.create(branch: branch, base: base, title: title, body: body, draft: draft)
        pinnedPullRequests[sessionId] = nil
        await refreshPullRequests(projectId: project.id)
        await refreshBranch(sessionId)
    }

    /// Commits what's in the worktree (if anything) and pushes, updating an open pull request.
    func pushChanges(_ sessionId: String, message: String) async throws {
        guard session(sessionId)?.worktreePath != nil else { return }
        try await commitEverything(sessionId, in: "", message: message)
        try await pushEverything(sessionId, in: "")
        await refreshBranch(sessionId)
        try await refreshPullRequest(sessionId)
    }

    func mergePullRequest(_ sessionId: String, method: MergeMethod) async throws {
        guard let (host, number) = try await pullRequestTarget(sessionId) else { return }
        try await host.merge(number: number, method: method)
        try await refreshPullRequest(sessionId)
        // The base moved on the code host.
        await refreshBranch(sessionId, fetch: .now)
    }

    func markPullRequestReady(_ sessionId: String) async throws {
        guard let (host, number) = try await pullRequestTarget(sessionId) else { return }
        try await host.markReady(number: number)
        try await refreshPullRequest(sessionId)
    }

    func closePullRequest(_ sessionId: String) async throws {
        guard let (host, number) = try await pullRequestTarget(sessionId) else { return }
        try await host.close(number: number)
        try await refreshPullRequest(sessionId)
    }

    /// The chat's pull request and the code host to act on it through.
    private func pullRequestTarget(_ sessionId: String) async throws -> (CodeHost, Int)? {
        guard let pr = pullRequests[sessionId], let project = project(session(sessionId)?.projectId) else { return nil }
        guard let host = await codeHost(for: project, chatId: sessionId) else { throw CodeHostError.noHost(nil) }
        return (host, pr.number)
    }

    /// The chat whose branch a pull request comes from.
    func chat(for pr: PullRequest, in projectId: String) -> Session? {
        sessions.first { $0.projectId == projectId && $0.branch == pr.head && $0.archivedAt == nil }
    }

    // MARK: Asking the agent

    /// Hands failed checks to the chat's agent to investigate.
    func askToFixChecks(_ sessionId: String, _ checks: [PullRequest.Check]) {
        guard let pr = pullRequests[sessionId], !checks.isEmpty else { return }
        let list = checks.map { c in "- \(c.workflow.map { "\($0) / " } ?? "")\(c.name)" + (c.url.map { ": \($0.absoluteString)" } ?? "") }
        send(sessionId, """
        These checks failed on pull request #\(pr.number):

        \(list.joined(separator: "\n"))

        Find out why (each check's link shows its failing steps), fix it, and tell me when it's ready to push.
        """)
    }

    /// Hands reviewers' feedback to the chat's agent: reviews, comments, and
    /// every open thread on the code.
    func askToAddressReviews(_ sessionId: String) {
        guard let pr = pullRequests[sessionId] else { return }
        let reviews = pr.reviews.filter { !$0.body.isEmpty && $0.verdict != .approved }
            .map { "**\($0.author)** (\($0.verdict == .changesRequested ? "requested changes" : "commented")):\n\($0.body)" }
        let comments = pr.comments.filter { !$0.isBot && !$0.body.isEmpty }.map { "**\($0.author)**:\n\($0.body)" }
        let open = pr.threads.filter { !$0.isResolved }
        let threads = open.map(Self.describe)
        guard !(reviews + comments + threads).isEmpty else { return }
        keepAsNotes(sessionId, open)
        send(sessionId, """
        Reviewers left feedback on pull request #\(pr.number). Address it, then tell me what you changed.

        \((reviews + comments + threads).joined(separator: "\n\n"))
        """)
    }

    /// Hands one thread on the code to the chat's agent.
    func askToAddressThread(_ sessionId: String, _ thread: PullRequest.ReviewThread) {
        guard let pr = pullRequests[sessionId] else { return }
        keepAsNotes(sessionId, [thread])
        send(sessionId, "A review thread on pull request #\(pr.number) needs a change. Address it, then tell me what you did.\n\n" + Self.describe(thread))
    }

    private static func describe(_ thread: PullRequest.ReviewThread) -> String {
        let place = "`\(thread.path)" + ((thread.line ?? thread.originalLine).map { ":\($0)" } ?? "") + "`"
        let conversation = thread.comments.map { "**\($0.author)**: \($0.body)" }.joined(separator: "\n\n")
        return place + (thread.isOutdated ? " (on code that has changed since)" : "") + "\n" + conversation
    }

    /// Review threads going to the agent are kept as notes on their lines,
    /// for the turn they lead to.
    private func keepAsNotes(_ sessionId: String, _ threads: [PullRequest.ReviewThread]) {
        for thread in threads {
            let conversation = thread.comments.map { "\($0.author): \($0.body)" }.joined(separator: "\n\n")
            try? store.save(CodeNote(sessionId: sessionId, kind: .reviewComment, path: thread.path, line: thread.line ?? thread.originalLine,
                                     commit: thread.commit, body: conversation, author: thread.comments.first?.author))
        }
    }

    private func send(_ sessionId: String, _ text: String) {
        if sessionId.hasPrefix(RemoteService.mirrorPrefix) {
            Task {
                do { try await sendRemoteFollowUp(sessionId, text: text) }
                catch { flash(error.localizedDescription, isError: true) }
            }
            return
        }
        do { try sendFollowUp(sessionId, text: text) } catch { flash(error.localizedDescription, isError: true) }
    }
}
