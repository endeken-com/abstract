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

    /// Shows `path` in `review` and makes it the chat's current repository.
    /// Already current while the review fell back to the worktree's own (a
    /// listing that missed it): shows it again.
    func showRepo(_ path: String, in review: DiffReview, _ context: DiffContext) {
        if currentRepoPath(context.sessionId) == path {
            if review.selectedRepo != path { Task { await review.select(path, context) } }
        } else {
            selectRepo(context.sessionId, path)
        }
    }

    /// Whether `path` is still checked out in `worktree`, as git says; nil when
    /// git couldn't be asked (a remote Mac offline), which never counts as gone.
    func isStillCheckedOut(_ exec: any Executor, worktree: String, path: String) async -> Bool? {
        guard let out = try? await exec.run("git", ["-C", path, "rev-parse", "--show-prefix"], cwd: worktree) else { return nil }
        // A checkout's own top prints an empty prefix; an empty folder inside the parent prints its path.
        return out.ok && out.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The chat's current submodule, once git says it's still checked out;
    /// nil while the worktree's own is current. Asked of git directly, not
    /// through a listing, which a `submodule foreach` hiccup can miss. Gone:
    /// the pick is dropped. Git couldn't be asked (a remote Mac offline): the
    /// pick stands, with nothing to read for now.
    func currentSubmodule(_ sessionId: String, worktree: String, exec: any Executor) async -> ChatRepo? {
        let path = currentRepoPath(sessionId)
        guard !path.isEmpty else { return nil }
        switch await isStillCheckedOut(exec, worktree: worktree, path: path) {
        case true?: return ChatRepo(path: path)
        case false?: dropPick(sessionId, path)
        case nil: break
        }
        return nil
    }

    /// Clears the chat's current repository pick, but only once git itself
    /// says its folder isn't a checkout any more — never on a listing
    /// failure alone, or while git can't be asked (a remote Mac offline):
    /// neither means the submodule is gone.
    func dropRepoIfGone(_ sessionId: String, _ path: String, worktree: String, exec: any Executor) async {
        guard !path.isEmpty, currentRepoPath(sessionId) == path else { return }
        if await isStillCheckedOut(exec, worktree: worktree, path: path) == false { dropPick(sessionId, path) }
    }

    /// Back to the worktree's own, unless another pick was made while git was asked.
    private func dropPick(_ sessionId: String, _ path: String) {
        if currentRepoPath(sessionId) == path { currentRepo[sessionId] = nil }
    }

    /// With a submodule current, where its branch stands: fetched in its own
    /// folder (at most once a minute, `.ifStale`) and measured against its own
    /// default branch. Dropped while the worktree's own is current, or while
    /// its folder can't be asked.
    func refreshCurrentSubmodule(_ sessionId: String, worktree: String, exec: any Executor, fetch: OriginFetch, read: Int) async {
        guard let repo = await currentSubmodule(sessionId, worktree: worktree, exec: exec) else {
            // A newer read clears (or fills) it itself.
            if branchReads[sessionId] == read, currentRepoStates[sessionId] != nil { currentRepoStates[sessionId] = nil }
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
