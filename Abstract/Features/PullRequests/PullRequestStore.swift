import Foundation
import AbstractCore

/// Pull requests for chats, through the GitHub CLI. One `gh pr list` per
/// GitHub project, every few minutes, tells each chat whether its branch has
/// a pull request and how it stands; a chat's Pull Request tab loads the
/// full detail (checks, reviews, comments) when it opens.
extension AppModel {
    private static let refreshInterval: Duration = .seconds(180)

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
    func refreshPullRequests() async {
        for project in projects where project.archivedAt == nil {
            guard await isOnGitHub(project), let list = try? await GitHub.pullRequests(executor, repo: project.rootPath) else { continue }
            projectPullRequests[project.id] = list
            for session in sessions where session.projectId == project.id {
                guard let branch = session.branch, let summary = list.first(where: { $0.head == branch }) else { continue }
                // A loaded detail keeps its reviews and comments until the tab reloads it.
                if let known = pullRequests[session.id], known.number == summary.number, known.updatedAt == summary.updatedAt { continue }
                // Newer state from the list; the tab re-reads reviews and threads itself.
                var updated = summary
                if let known = pullRequests[session.id], known.number == summary.number {
                    (updated.reviews, updated.comments, updated.threads) = (known.reviews, known.comments, known.threads)
                }
                pullRequests[session.id] = updated
            }
        }
    }

    /// The chat's pull request in full; nil when its branch has none.
    @discardableResult
    func refreshPullRequest(_ sessionId: String) async throws -> PullRequest? {
        guard !isDemo else { return pullRequests[sessionId] }
        guard let session = session(sessionId), let branch = session.branch, let project = project(session.projectId),
              await isOnGitHub(project) else { return nil }
        let executor = executor(for: sessionId)
        var pr = try await GitHub.pullRequest(executor, repo: project.rootPath, branch: branch)
        if let number = pr?.number {
            pr?.threads = (try? await GitHub.reviewThreads(executor, repo: project.rootPath, number: number)) ?? []
        }
        pullRequests[sessionId] = pr
        return pr
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
    }

    /// Commits what's in the worktree (if anything) and pushes, updating an open pull request.
    func pushChanges(_ sessionId: String, message: String) async throws {
        guard let session = session(sessionId), let branch = session.branch, let worktree = session.worktreePath else { return }
        try await Git.commitAll(executor(for: sessionId), worktree: worktree, message: message)
        try await Git.push(executor(for: sessionId), worktree: worktree, branch: branch)
        try await refreshPullRequest(sessionId)
    }

    func mergePullRequest(_ sessionId: String, method: MergeMethod) async throws {
        guard let (root, number) = pullRequestTarget(sessionId) else { return }
        try await GitHub.merge(executor(for: sessionId), repo: root, number: number, method: method)
        try await refreshPullRequest(sessionId)
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
