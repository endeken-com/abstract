import Foundation
import AbstractCore

/// Shipping a chat whose worktree holds submodules (see `Shipping`), for the
/// git actions, the Pull Request tab and the delete confirmations.
extension AppModel {
    /// What deleting `worktree` loses beyond its uncommitted work: commits in
    /// its submodules that no remote has. They live in the worktree's own
    /// clone of each and go with it. Nil when there are none.
    func unpushedSubmoduleWarning(_ exec: any Executor, worktree: String) async -> String? {
        let repos = await Submodules.list(exec, worktree: worktree)
        let lost = await Shipping.unpushedWork(exec, worktree: worktree, repos: repos)
        guard !lost.isEmpty else { return nil }
        let list = lost.map { "\($0.repo.path) (\($0.commits) commit\($0.commits == 1 ? "" : "s"))" }.joined(separator: ", ")
        return "\(list) \(lost.count == 1 ? "has" : "have") commits no remote has. They're only in this worktree and are lost with it."
    }

    /// Commits the chat's work in every repository with some, its submodules
    /// first, with one message. Submodules you can't push to are left alone.
    func commitEverything(_ sessionId: String, message: String) async throws {
        guard let session = session(sessionId), let worktree = session.worktreePath, let branch = session.branch else { return }
        let exec = executor(for: sessionId)
        let repos = await Submodules.list(exec, worktree: worktree)
        try await Shipping.commit(exec, worktree: worktree, repos: repos, branch: branch,
                                  readOnly: await readOnlySubmodules(repos), message: message)
    }

    /// Before the chat's branch is pushed: pushes its submodules that have
    /// commits no remote has, then makes sure every pointer the branch
    /// publishes is on its submodule's origin. Throws, naming the submodule,
    /// when the branch can't go yet.
    func prepareParentPush(_ sessionId: String) async throws {
        guard let session = session(sessionId), let worktree = session.worktreePath, let branch = session.branch else { return }
        let exec = executor(for: sessionId)
        let repos = await Submodules.list(exec, worktree: worktree)
        // Without submodules, pushing is what it always was.
        guard repos.count > 1 else { return }
        let readOnly = await readOnlySubmodules(repos)
        try await Shipping.pushSubmodules(exec, worktree: worktree, repos: repos, branch: branch, readOnly: readOnly)
        if let blocked = await Shipping.unpublishedPointers(exec, worktree: worktree, repos: repos).first {
            throw AbstractError.message(Self.explain(blocked, readOnly: readOnly.contains(blocked.repo.path)))
        }
    }

    /// Pushes the chat's branch, its submodules first.
    func pushEverything(_ sessionId: String) async throws {
        guard let session = session(sessionId), let worktree = session.worktreePath, let branch = session.branch else { return }
        try await prepareParentPush(sessionId)
        try await Git.push(executor(for: sessionId), worktree: worktree, branch: branch)
    }

    /// Submodules on GitHub you can't push to, by path.
    private func readOnlySubmodules(_ repos: [ChatRepo]) async -> Set<String> {
        var paths: Set<String> = []
        for repo in repos where repo.isSubmodule {
            if let slug = repo.github, await access(to: slug) == .readOnly { paths.insert(repo.path) }
        }
        return paths
    }

    private static func explain(_ pointer: UnpublishedPointer, readOnly: Bool) -> String {
        let short = String(pointer.sha.prefix(7)), path = pointer.repo.path
        switch pointer.reason {
        case .unreachable(let why):
            return "Didn't push: couldn't check \(path) against its origin (\(why))."
        case .unreadable(let why):
            return "Didn't push: couldn't read which submodule pointers the branch moves (\(why))."
        case .notOnOrigin where readOnly:
            return "Didn't push: \(path) points at \(short), which isn't on its origin, and you can't push to "
                + "\(pointer.repo.github ?? path). Keep its pointer where it was."
        case .notOnOrigin:
            return "Didn't push: \(path) points at \(short), which isn't on its origin. Push \(path) first."
        }
    }
}
