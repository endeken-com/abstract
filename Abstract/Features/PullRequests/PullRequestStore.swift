import Foundation
import AbstractCore

/// Pull requests for chats, through the GitHub CLI. One `gh pr list` per
/// GitHub project, every few minutes, tells each chat whether its branch has
/// a pull request and how it stands; a chat's Pull Request tab loads the
/// full detail (checks, reviews, comments) when it opens.
extension AppModel {
    private static let refreshInterval: Duration = .seconds(60)

    func watchPullRequests() async {
        guard !isDemo else { return }
        githubAccess = await GitHub.access(executor)
        guard githubAccess == .ready else { return }
        githubViewer = await GitHub.viewer(executor)
        while !Task.isCancelled {
            await refreshPullRequests()
            try? await Task.sleep(for: Self.refreshInterval)
        }
    }

    /// Re-reads every GitHub project's recent pull requests and matches them to chats by branch.
    func refreshPullRequests(projectId: String? = nil) async {
        for project in projects where project.archivedAt == nil && (projectId == nil || project.id == projectId) {
            guard await isOnGitHub(project), let list = try? await GitHub.pullRequests(executor, repo: project.rootPath) else { continue }
            projectPullRequests[project.id] = list
            pullRequestsListedAt[project.id] = .now
            for session in sessions where session.projectId == project.id {
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

    /// Lists the project's pull requests again unless that happened in the last `interval`.
    func refreshPullRequestsIfStale(projectId: String?, interval: Duration = .seconds(20)) async {
        guard !isDemo, githubAccess == .ready, let projectId else { return }
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
              await isOnGitHub(project) else { return nil }
        let executor = executor(for: sessionId)
        let selected = pullRequests[sessionId]?.number
        var pr: PullRequest?
        if let selected {
            pr = try await GitHub.pullRequest(executor, repo: project.rootPath, number: selected)
        } else {
            pr = try await GitHub.pullRequest(executor, repo: project.rootPath, branch: branch)
        }
        if let number = pr?.number {
            pr?.threads = (try? await GitHub.reviewThreads(executor, repo: project.rootPath, number: number)) ?? []
        }
        if pullRequests[sessionId]?.number == selected { pullRequests[sessionId] = pr }
        return pr
    }

    // MARK: The branch

    enum OriginFetch { case never, ifStale, now }

    /// Re-reads where a chat's branch stands, fetching from origin first:
    /// `.ifStale` at most once a minute per project, `.now` regardless.
    /// Pruned, so a branch deleted on origin (a merged PR's) shows as gone.
    func refreshBranch(_ sessionId: String, fetch: OriginFetch = .never) async {
        guard let session = session(sessionId), let worktree = session.worktreePath else { return }
        let exec = executor(for: sessionId)
        let key = session.projectId ?? sessionId
        let stale = originFetchedAt[key].map { ContinuousClock.now - $0 >= .seconds(60) } ?? true
        if fetch == .now || (fetch == .ifStale && stale) {
            originFetchedAt[key] = .now
            _ = try? await exec.run("git", ["fetch", "--quiet", "--prune", "origin"], cwd: worktree)
        }
        let read = (branchReads[sessionId] ?? 0) + 1
        branchReads[sessionId] = read
        let state = await GitActions.state(exec, worktree: worktree, preferredBase: session.baseRef)
        guard branchReads[sessionId] == read, branchStates[sessionId] != state else { return }
        branchStates[sessionId] = state
    }

    func isOnGitHub(_ project: Project) async -> Bool {
        if let known = githubProjects[project.id] { return known }
        let out = try? await executor(forProject: project.id).run("git", ["remote", "get-url", "origin"], cwd: project.rootPath)
        let onGitHub = out.map { $0.ok && GitRemote.githubOwner($0.stdout) != nil } ?? false
        githubProjects[project.id] = onGitHub
        return onGitHub
    }

    // MARK: Actions

    func createPullRequest(_ sessionId: String, title: String, body: String, base: String?, draft: Bool, commitFirst: Bool) async throws {
        guard let session = session(sessionId), let branch = session.branch, let worktree = session.worktreePath,
              let project = project(session.projectId) else { return }
        pullRequests[sessionId] = try await GitHub.create(executor(for: sessionId), repo: project.rootPath, worktree: worktree, branch: branch,
                                                          base: base, title: title, body: body, draft: draft,
                                                          commitMessage: commitFirst ? title : nil)
        pinnedPullRequests[sessionId] = nil
        await refreshPullRequests(projectId: project.id)
        await refreshBranch(sessionId)
    }

    /// Commits what's in the worktree (if anything) and pushes, updating an open pull request.
    func pushChanges(_ sessionId: String, message: String) async throws {
        guard let session = session(sessionId), let branch = session.branch, let worktree = session.worktreePath else { return }
        try await Git.commitAll(executor(for: sessionId), worktree: worktree, message: message)
        try await Git.push(executor(for: sessionId), worktree: worktree, branch: branch)
        await refreshBranch(sessionId)
        try await refreshPullRequest(sessionId)
    }

    func mergePullRequest(_ sessionId: String, method: MergeMethod) async throws {
        guard let (root, number) = pullRequestTarget(sessionId) else { return }
        try await GitHub.merge(executor(for: sessionId), repo: root, number: number, method: method)
        try await refreshPullRequest(sessionId)
        // The base moved on GitHub.
        await refreshBranch(sessionId, fetch: .now)
    }

    func markPullRequestReady(_ sessionId: String) async throws {
        guard let (root, number) = pullRequestTarget(sessionId) else { return }
        try await GitHub.markReady(executor(for: sessionId), repo: root, number: number)
        try await refreshPullRequest(sessionId)
    }

    func closePullRequest(_ sessionId: String) async throws {
        guard let (root, number) = pullRequestTarget(sessionId) else { return }
        try await GitHub.close(executor(for: sessionId), repo: root, number: number)
        try await refreshPullRequest(sessionId)
    }

    private func pullRequestTarget(_ sessionId: String) -> (String, Int)? {
        guard let pr = pullRequests[sessionId], let root = project(session(sessionId)?.projectId)?.rootPath else { return nil }
        return (root, pr.number)
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

        Find out why (`gh run view --log-failed` shows the failing steps), fix it, and tell me when it's ready to push.
        """)
    }

    /// Hands reviewers' feedback to the chat's agent: reviews, comments, and
    /// every open thread on the code.
    func askToAddressReviews(_ sessionId: String) {
        guard let pr = pullRequests[sessionId] else { return }
        let reviews = pr.reviews.filter { !$0.body.isEmpty && $0.verdict != .approved }
            .map { "**\($0.author)** (\($0.verdict == .changesRequested ? "requested changes" : "commented")):\n\($0.body)" }
        let comments = pr.comments.filter { !$0.isBot && !$0.body.isEmpty }.map { "**\($0.author)**:\n\($0.body)" }
        let threads = pr.threads.filter { !$0.isResolved }.map(Self.describe)
        guard !(reviews + comments + threads).isEmpty else { return }
        send(sessionId, """
        Reviewers left feedback on pull request #\(pr.number). Address it, then tell me what you changed.

        \((reviews + comments + threads).joined(separator: "\n\n"))
        """)
    }

    /// Hands one thread on the code to the chat's agent.
    func askToAddressThread(_ sessionId: String, _ thread: PullRequest.ReviewThread) {
        guard let pr = pullRequests[sessionId] else { return }
        send(sessionId, "A review thread on pull request #\(pr.number) needs a change. Address it, then tell me what you did.\n\n" + Self.describe(thread))
    }

    private static func describe(_ thread: PullRequest.ReviewThread) -> String {
        let place = "`\(thread.path)" + ((thread.line ?? thread.originalLine).map { ":\($0)" } ?? "") + "`"
        let conversation = thread.comments.map { "**\($0.author)**: \($0.body)" }.joined(separator: "\n\n")
        return place + (thread.isOutdated ? " (on code that has changed since)" : "") + "\n" + conversation
    }

    private func send(_ sessionId: String, _ text: String) {
        do { try sendFollowUp(sessionId, text: text) } catch { flash(error.localizedDescription, isError: true) }
    }
}
