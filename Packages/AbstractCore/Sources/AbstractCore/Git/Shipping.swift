import Foundation

/// What asking a submodule to be on the chat's branch did.
public enum BranchOutcome: Sendable, Hashable {
    case created, switched, alreadyOn
    /// On a branch the agent chose, which is the one it ships.
    case keptOwn(String)
    /// The name belongs to a branch at another commit: left detached.
    case leftDetached
}

/// Shipping a chat's work when its worktree holds submodules: each submodule
/// on a branch, committed and pushed before the parent that points at it.
public enum Shipping {
    /// Deepest first, the worktree's own last: a parent's commit then takes in
    /// the pointers its submodules' commits just moved.
    public static func order(_ repos: [ChatRepo]) -> [ChatRepo] {
        repos.sorted { $0.depth != $1.depth ? $0.depth > $1.depth : $0.path < $1.path }
    }

    /// Puts the repository at `directory` on branch `name`, so the commits
    /// made there land somewhere that can be pushed. Detached with no such
    /// branch: made at HEAD. Detached at that branch's commit: switched to.
    /// On a branch already, or the name taken elsewhere: left as it is.
    @discardableResult
    public static func ensureBranch(_ exec: any Executor, directory: String, name: String) async -> BranchOutcome {
        if let current = (try? await Git.currentBranch(exec, root: directory)) ?? nil {
            return current == name ? .alreadyOn : .keptOwn(current)
        }
        guard let head = await revision(exec, directory, "HEAD") else { return .leftDetached }
        if let existing = await revision(exec, directory, "refs/heads/" + name) {
            guard existing == head, (try? await Git.git(exec, cwd: directory, ["switch", "-q", name]))?.ok == true else {
                return .leftDetached
            }
            return .switched
        }
        return (try? await Git.git(exec, cwd: directory, ["switch", "-q", "-c", name]))?.ok == true ? .created : .leftDetached
    }

    /// The commit `rev` names in the repository at `directory`; nil when none.
    static func revision(_ exec: any Executor, _ directory: String, _ rev: String) async -> String? {
        guard let out = try? await Git.git(exec, cwd: directory, ["rev-parse", "--verify", "--quiet", rev + "^{commit}"]), out.ok
        else { return nil }
        let sha = GitText.trimmed(out.stdout)
        return sha.isEmpty ? nil : sha
    }

    /// Commits in every repository with something to commit, `order`ed, with
    /// one message: each parent's commit then takes in the pointers its
    /// submodules' just moved. Submodules you can't push to (`readOnly`, by
    /// path) are left as they are, and no commit moves their pointer.
    /// Returns the paths of the repositories committed.
    @discardableResult
    public static func commit(_ exec: any Executor, worktree: String, repos: [ChatRepo], branch: String,
                              readOnly: Set<String> = [], message: String) async throws -> [String] {
        var committed: [String] = []
        for repo in order(repos) where !readOnly.contains(repo.path) {
            let dir = repo.directory(in: worktree)
            guard await Diff.isDirty(exec, worktree: dir) else { continue }
            if repo.isSubmodule { await ensureBranch(exec, directory: dir, name: branch) }
            let keep = repos.filter { $0.parentPath == repo.path && readOnly.contains($0.path) }.compactMap { repo.inside($0.path) }
            let before = await revision(exec, dir, "HEAD")
            try await Git.commitAll(exec, worktree: dir, message: message, exclude: keep)
            if await revision(exec, dir, "HEAD") != before { committed.append(repo.path) }
        }
        return committed
    }
}
