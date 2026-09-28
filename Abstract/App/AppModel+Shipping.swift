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

    /// Commits the chat's work in the repository at `path` ("" for the
    /// worktree's own) and the repositories inside it, innermost first, with
    /// one message. Nothing outside it is committed: a submodule's commit
    /// leaves its parent's pointer for the parent. Submodules you can't push
    /// to are left alone. Without a branch (an agent's own worktree not yet
    /// on one), commits that repository only, as it always did.
    func commitEverything(_ sessionId: String, in path: String, message: String) async throws {
        guard let session = session(sessionId), let worktree = session.worktreePath else { return }
        let exec = executor(for: sessionId)
        guard let branch = session.branch else {
            // A submodule's commits would land on no branch at all.
            guard path.isEmpty else { throw AbstractError.message("This chat has no branch to commit \(path) on.") }
            try await Git.commitAll(exec, worktree: worktree, message: message)
            return
        }
        let root = try await shippingRoot(exec, worktree: worktree, path: path)
        if root.repo.isSubmodule { try await putOnBranch(exec, root, branch) }
        try await Shipping.commit(exec, worktree: root.dir, repos: root.repos, branch: branch, readOnly: root.readOnly, message: message)
    }

    /// Before the repository at `path` is pushed: pushes the repositories
    /// inside it that have commits no remote has, then makes sure every
    /// pointer it publishes is on its submodule's origin. Throws, naming the
    /// submodule and what was pushed already, when it can't go yet, or saying
    /// so when there's no branch at all.
    func prepareParentPush(_ sessionId: String, in path: String) async throws {
        guard let session = session(sessionId), let worktree = session.worktreePath else { return }
        guard let branch = session.branch else { throw AbstractError.message("This chat has no branch to push.") }
        let exec = executor(for: sessionId)
        try await preparePush(exec, try await shippingRoot(exec, worktree: worktree, path: path), branch: branch, base: session.baseRef)
    }

    /// Pushes the repository at `path`, the repositories inside it first. A
    /// submodule goes to the branch it's on (the chat's, unless the agent
    /// chose another); the worktree's own to the chat's branch.
    func pushEverything(_ sessionId: String, in path: String) async throws {
        guard let session = session(sessionId), let worktree = session.worktreePath else { return }
        guard let branch = session.branch else { throw AbstractError.message("This chat has no branch to push.") }
        let exec = executor(for: sessionId)
        let root = try await shippingRoot(exec, worktree: worktree, path: path)
        if root.repo.isSubmodule { try await putOnBranch(exec, root, branch) }
        try await preparePush(exec, root, branch: branch, base: session.baseRef)
        let target = root.repo.isSubmodule ? (((try? await Git.currentBranch(exec, root: root.dir)) ?? nil) ?? branch) : branch
        try await Git.push(exec, worktree: root.dir, branch: target)
    }

    /// A repository shipped on its own: the one acted on, its folder, the
    /// repositories seen from it (itself as the worktree's own, see
    /// `Submodules.subtree`), and the ones among them you can't push to.
    /// Paths in what it reports are as seen from it.
    private struct ShippingRoot {
        let repo: ChatRepo
        let dir: String
        let repos: [ChatRepo]
        let readOnly: Set<String>
    }

    /// The repository at `path` as a `ShippingRoot`. Refuses a submodule
    /// that isn't checked out, or that you can't push to.
    private func shippingRoot(_ exec: any Executor, worktree: String, path: String) async throws -> ShippingRoot {
        let all = await Submodules.list(exec, worktree: worktree)
        guard let repo = all.first(where: { $0.path == path }) else {
            throw AbstractError.message("\(path) isn't checked out in this worktree.")
        }
        let readOnly = await readOnlySubmodules(all)
        if readOnly.contains(repo.path) {
            throw AbstractError.message("You can't push to \(repo.github ?? repo.path), so Abstract doesn't commit or push in \(repo.path).")
        }
        return ShippingRoot(repo: repo, dir: repo.directory(in: worktree), repos: Submodules.subtree(all, at: repo),
                            readOnly: Set(readOnly.compactMap(repo.inside)))
    }

    /// Pushes what's inside `root` that has commits no remote has, then
    /// checks every pointer `root` publishes. Guarded even when only `root`
    /// is listed: listing the ones inside it may have failed. Without any,
    /// nothing is pushed first and the guard reads its commits alone.
    private func preparePush(_ exec: any Executor, _ root: ShippingRoot, branch: String, base: String?) async throws {
        let pushed = try await Shipping.pushSubmodules(exec, worktree: root.dir, repos: root.repos, branch: branch, readOnly: root.readOnly)
        // A submodule is measured from its own default branch; the worktree's own from the chat's base.
        let base = root.repo.isSubmodule ? nil : base
        if let blocked = await Shipping.unpublishedPointers(exec, worktree: root.dir, repos: root.repos, base: base).first {
            let went = pushed.isEmpty ? "" : "Pushed \(pushed.joined(separator: ", ")). "
            throw AbstractError.message(went + Self.explain(blocked, readOnly: root.readOnly.contains(blocked.repo.path)))
        }
    }

    /// Puts a submodule on the chat's branch before its work is committed or
    /// pushed, or says why it can't be.
    private func putOnBranch(_ exec: any Executor, _ root: ShippingRoot, _ branch: String) async throws {
        switch await Shipping.ensureBranch(exec, directory: root.dir, name: branch) {
        case .leftDetached:
            throw AbstractError.message("It's on a detached commit while its branch \(branch) is somewhere else. Put it on a branch first.")
        case .failed(let why):
            throw AbstractError.message("Couldn't put it on branch \(branch): \(why)")
        case .created, .switched, .alreadyOn, .keptOwn:
            break
        }
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
            // Its branch was just pushed, if it had anything to push.
            return "Didn't push: \(path) points at \(short), which isn't on its origin even after pushing \(path)'s branch. "
                + "Check which commit \(path) is on."
        }
    }
}
