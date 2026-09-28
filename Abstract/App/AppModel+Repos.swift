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
    /// the worktree. A listing that doesn't have the one picked is usually a
    /// git hiccup (a `submodule foreach` blip), not the submodule being gone;
    /// only once `dropRepoIfGone` confirms that with git directly does the
    /// worktree's own become current.
    func currentRepository(_ sessionId: String, worktree: String, exec: any Executor) async -> (repo: ChatRepo, repos: [ChatRepo]) {
        let repos = await Submodules.list(exec, worktree: worktree)
        let path = currentRepoPath(sessionId)
        if let repo = repos.first(where: { $0.path == path }) { return (repo, repos) }
        await dropRepoIfGone(sessionId, path, worktree: worktree, exec: exec)
        return (repos.first { !$0.isSubmodule } ?? ChatRepo(path: ""), repos)
    }

    /// Clears the chat's current repository pick, but only once git itself
    /// says its folder isn't a checkout any more — never on a listing
    /// failure alone, which a remote blip or a `submodule foreach` hiccup can
    /// cause without the submodule really being gone.
    func dropRepoIfGone(_ sessionId: String, _ path: String, worktree: String, exec: any Executor) async {
        guard !path.isEmpty, currentRepoPath(sessionId) == path else { return }
        let dir = ChatRepo(path: path).directory(in: worktree)
        guard !(await Submodules.isCheckedOut(exec, directory: dir)), currentRepoPath(sessionId) == path else { return }
        currentRepo[sessionId] = nil
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
        await fetchOriginIfDue(exec, key: dir, directory: dir, fetch: fetch)
        let state = await GitActions.state(exec, worktree: dir, preferredBase: nil)
        guard branchReads[sessionId] == read, currentRepoPath(sessionId) == repo.path else { return }
        let next = RepoBranchState(path: repo.path, state: state)
        if currentRepoStates[sessionId] != next { currentRepoStates[sessionId] = next }
    }
}
