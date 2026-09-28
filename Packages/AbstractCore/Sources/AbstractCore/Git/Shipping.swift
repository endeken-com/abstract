import Foundation

/// What asking a submodule to be on the chat's branch did.
public enum BranchOutcome: Sendable, Hashable {
    case created, switched, alreadyOn
    /// On a branch the agent chose, which is the one it ships.
    case keptOwn(String)
    /// The name belongs to a branch at another commit: left detached.
    case leftDetached
}

/// A submodule's commits that no remote has: they live only in the
/// worktree's own clone of it, and go if the worktree is deleted.
public struct UnpushedWork: Sendable, Hashable {
    public var repo: ChatRepo
    public var commits: Int
}

/// A submodule pointer the worktree's commits would publish that its
/// submodule's origin doesn't have.
public struct UnpublishedPointer: Sendable, Hashable {
    public enum Reason: Sendable, Hashable {
        /// The commit isn't on its origin: the submodule has to be pushed first.
        case notOnOrigin
        /// Its origin couldn't be asked (offline, say), and why.
        case unreachable(String)
    }
    public var repo: ChatRepo
    public var sha: String
    public var reason: Reason
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

    /// Pushes every submodule, `order`ed, whose HEAD has commits no remote
    /// has, onto its branch: the chat's, unless the agent chose another. Stops
    /// at the first that fails, naming it: nothing may point at what didn't go.
    /// Returns the paths pushed.
    @discardableResult
    public static func pushSubmodules(_ exec: any Executor, worktree: String, repos: [ChatRepo], branch: String,
                                      readOnly: Set<String> = []) async throws -> [String] {
        var pushed: [String] = []
        for repo in order(repos) where repo.isSubmodule && !readOnly.contains(repo.path) {
            let dir = repo.directory(in: worktree)
            guard await commitsNoRemoteHas(exec, dir, ["HEAD"]) > 0 else { continue }
            if await ensureBranch(exec, directory: dir, name: branch) == .leftDetached {
                throw AbstractError.message(
                    "\(repo.path) is on a detached commit while its branch \(branch) is somewhere else, so nothing was pushed. "
                    + "Put \(repo.path) on a branch first.")
            }
            let target = ((try? await Git.currentBranch(exec, root: dir)) ?? nil) ?? branch
            do {
                try await Git.push(exec, worktree: dir, branch: target)
            } catch {
                throw AbstractError.message("\(repo.path) didn't push, so nothing that points at it was: \(error.localizedDescription)")
            }
            pushed.append(repo.path)
        }
        return pushed
    }

    /// What deleting the worktree would lose besides uncommitted work: each
    /// submodule's commits, on its HEAD or its branches, that no remote has.
    /// The worktree's own branch is kept on delete, so it isn't counted.
    public static func unpushedWork(_ exec: any Executor, worktree: String, repos: [ChatRepo]) async -> [UnpushedWork] {
        var found: [UnpushedWork] = []
        for repo in order(repos) where repo.isSubmodule {
            let count = await commitsNoRemoteHas(exec, repo.directory(in: worktree), ["HEAD", "--branches"])
            if count > 0 { found.append(UnpushedWork(repo: repo, commits: count)) }
        }
        return found
    }

    private static func commitsNoRemoteHas(_ exec: any Executor, _ directory: String, _ from: [String]) async -> Int {
        guard let out = try? await Git.git(exec, cwd: directory, ["rev-list", "--count"] + from + ["--not", "--remotes"]), out.ok
        else { return 0 }
        return Int(GitText.trimmed(out.stdout)) ?? 0
    }

    /// The pointers the worktree's commits would publish that their
    /// submodules' origins don't have. Only pointers moved by commits origin
    /// doesn't have yet are checked, each after fetching its submodule's
    /// origin; one that can't be fetched counts, since letting a bad pointer
    /// through can't be taken back. A submodule that isn't checked out can't
    /// hold commits of its own, so it isn't asked.
    public static func unpublishedPointers(_ exec: any Executor, worktree: String, repos: [ChatRepo]) async -> [UnpublishedPointer] {
        guard repos.contains(where: \.isSubmodule) else { return [] }
        // What origin has of the branch: its upstream, else where it left origin's default branch.
        let from: String
        if await revision(exec, worktree, "@{upstream}") != nil {
            from = "@{upstream}"
        } else if let base = await Diff.resolveBase(exec, worktree: worktree, preferred: nil),
                  let fork = await Diff.mergeBase(exec, worktree: worktree, base: base) {
            from = fork
        } else {
            // Nothing on origin at all: every pointer at HEAD is new to it.
            from = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
        }
        guard let out = try? await Git.git(exec, cwd: worktree, ["diff", "--raw", "-z", "--no-abbrev", "--no-renames", from, "HEAD"]),
              out.ok else { return [] }
        var found: [UnpublishedPointer] = []
        var fields = Submodules.nulFields(out.stdout)[...]
        // ":<old mode> <new mode> <old sha> <new sha> <status>", then the path.
        while let header = fields.popFirst(), let path = fields.popFirst() {
            let parts = header.dropFirst().split(separator: " ").map(String.init)
            guard parts.count >= 4, parts[1] == "160000", let repo = repos.first(where: { $0.path == path }) else { continue }
            let sha = parts[3], dir = repo.directory(in: worktree)
            do {
                try await fetchOrigin(exec, dir)
            } catch {
                found.append(UnpublishedPointer(repo: repo, sha: sha, reason: .unreachable(error.localizedDescription)))
                continue
            }
            let missing = try? await Git.git(exec, cwd: dir, ["rev-list", sha, "--not", "--remotes=origin"])
            if missing?.ok != true || !GitText.trimmed(missing?.stdout ?? "").isEmpty {
                found.append(UnpublishedPointer(repo: repo, sha: sha, reason: .notOnOrigin))
            }
        }
        return found
    }

    /// `git fetch --prune origin` in the repository at `directory`, never
    /// asking for credentials, giving up after 30 seconds.
    private static func fetchOrigin(_ exec: any Executor, _ directory: String) async throws {
        let spec = LaunchSpec(command: "git", args: ["fetch", "--quiet", "--prune", "--no-tags", "origin"], cwd: directory,
                              env: ["GIT_TERMINAL_PROMPT": "0"], keepStdinOpen: false)
        let result = try await exec.run(spec, timeout: .seconds(30))
        if result.timedOut { throw AbstractError.message("its origin didn't answer within 30 seconds") }
        guard result.ok else { throw AbstractError.message(GitText.failure(result.stderr) ?? result.lastLine ?? "git fetch failed") }
    }
}
