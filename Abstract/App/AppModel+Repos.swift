import Foundation
import AbstractCore

/// A submodule's branch state, and which submodule it's for: a read that
/// lands after the chat switched repositories is never shown under the new one.
struct RepoBranchState: Equatable {
    let path: String
    let state: BranchState
}

/// The repository a chat is working in (see `AppModel.currentRepo`).
extension AppModel {
    /// The chat's current repository's path; "" for the worktree's own.
    func currentRepoPath(_ sessionId: String) -> String { currentRepo[sessionId] ?? "" }

    /// Makes `path` the chat's current repository ("" for the worktree's own)
    /// and reads where its branch stands.
    func selectRepo(_ sessionId: String, _ path: String) {
        guard currentRepoPath(sessionId) != path else { return }
        currentRepo[sessionId] = path.isEmpty ? nil : path
        Task { await refreshBranch(sessionId, fetch: .ifStale) }
    }

    /// The chat's current repository as listed now, with every repository in
    /// the worktree. When the one picked isn't checked out any more, the
    /// worktree's own, which then becomes current.
    func currentRepository(_ sessionId: String, worktree: String, exec: any Executor) async -> (repo: ChatRepo, repos: [ChatRepo]) {
        let repos = await Submodules.list(exec, worktree: worktree)
        let path = currentRepoPath(sessionId)
        if let repo = repos.first(where: { $0.path == path }) { return (repo, repos) }
        if !path.isEmpty { currentRepo[sessionId] = nil }
        return (repos.first { !$0.isSubmodule } ?? ChatRepo(path: ""), repos)
    }

    /// With a submodule current, where its branch stands: fetched in its own
    /// folder (at most once a minute, `.ifStale`) and measured against its own
    /// default branch. Dropped while the worktree's own is current.
    func refreshCurrentSubmodule(_ sessionId: String, worktree: String, exec: any Executor, fetch: OriginFetch, read: Int) async {
        guard !currentRepoPath(sessionId).isEmpty else {
            currentRepoStates[sessionId] = nil
            return
        }
        let (repo, _) = await currentRepository(sessionId, worktree: worktree, exec: exec)
        guard repo.isSubmodule else {
            currentRepoStates[sessionId] = nil
            return
        }
        let dir = repo.directory(in: worktree)
        // Each worktree has its own clone of a submodule, so its fetches are its own.
        let stale = originFetchedAt[dir].map { ContinuousClock.now - $0 >= .seconds(60) } ?? true
        if fetch == .now || (fetch == .ifStale && stale) {
            originFetchedAt[dir] = .now
            _ = try? await exec.run("git", ["fetch", "--quiet", "--prune", "origin"], cwd: dir)
        }
        let state = await GitActions.state(exec, worktree: dir, preferredBase: nil)
        guard branchReads[sessionId] == read, currentRepoPath(sessionId) == repo.path else { return }
        let next = RepoBranchState(path: repo.path, state: state)
        if currentRepoStates[sessionId] != next { currentRepoStates[sessionId] = next }
    }
}
