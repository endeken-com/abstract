import Foundation

/// What asking a submodule to be on the chat's branch did.
public enum BranchOutcome: Sendable, Hashable {
    case created, switched, alreadyOn
    /// On a branch the agent chose, which is the one it ships.
    case keptOwn(String)
    /// The name belongs to a branch at another commit: left detached.
    case leftDetached
    /// git couldn't make or switch to the branch, and why: left as it was.
    case failed(String)
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
        /// Which pointers the branch moves couldn't be read, and why.
        case unreadable(String)
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
    /// When git refuses for another reason, says why.
    @discardableResult
    public static func ensureBranch(_ exec: any Executor, directory: String, name: String) async -> BranchOutcome {
        if let current = (try? await Git.currentBranch(exec, root: directory)) ?? nil {
            return current == name ? .alreadyOn : .keptOwn(current)
        }
        guard let head = await revision(exec, directory, "HEAD") else { return .failed("its HEAD couldn't be read") }
        if let existing = await revision(exec, directory, "refs/heads/" + name) {
            guard existing == head else { return .leftDetached }
            return await switchBranch(exec, directory, ["switch", "-q", name], .switched)
        }
        return await switchBranch(exec, directory, ["switch", "-q", "-c", name], .created)
    }

    /// `git switch` with `args`: `outcome` when it worked, else git's reason.
    private static func switchBranch(_ exec: any Executor, _ directory: String, _ args: [String],
                                     _ outcome: BranchOutcome) async -> BranchOutcome {
        do {
            let out = try await Git.git(exec, cwd: directory, args)
            return out.ok ? outcome : .failed(reason(out, "git switch failed"))
        } catch {
            return .failed(error.localizedDescription)
        }
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
    /// path) are left as they are, and no commit moves their pointer. While
    /// any other has unresolved conflicts, nothing is committed anywhere.
    /// Returns the paths of the repositories committed.
    @discardableResult
    public static func commit(_ exec: any Executor, worktree: String, repos: [ChatRepo], branch: String,
                              readOnly: Set<String> = [], message: String) async throws -> [String] {
        let targets = order(repos).filter { !readOnly.contains($0.path) }
        // Committing would take the conflict markers in as they are, and each
        // parent a pointer to them; checked first so none is half-committed.
        for repo in targets where await Diff.hasConflicts(exec, repo: repo.directory(in: worktree)) {
            throw AbstractError.message("\(repo.isSubmodule ? repo.path : "The worktree") has unresolved conflicts. Resolve them, then commit.")
        }
        var committed: [String] = []
        for repo in targets {
            let dir = repo.directory(in: worktree)
            guard await Diff.isDirty(exec, worktree: dir) else { continue }
            if repo.isSubmodule { await ensureBranch(exec, directory: dir, name: branch) }
            let keep = repos.filter { $0.parentPath == repo.path && readOnly.contains($0.path) }.compactMap { repo.inside($0.path) }
            let before = await revision(exec, dir, "HEAD")
            do {
                try await Git.commitAll(exec, worktree: dir, message: message, exclude: keep)
            } catch {
                guard repo.isSubmodule else { throw error }
                throw AbstractError.message("Couldn't commit \(repo.path): \(error.localizedDescription)")
            }
            if await revision(exec, dir, "HEAD") != before { committed.append(repo.path) }
        }
        return committed
    }

    /// Pushes every submodule, `order`ed, whose HEAD has commits no remote
    /// has, onto its branch: the chat's, unless the agent chose another. One
    /// with submodules of its own is a parent too, so its pointers are checked
    /// first, as the worktree's are. Stops at the first that can't go, naming
    /// it and what went before it: nothing may point at what didn't go.
    /// Returns the paths pushed.
    @discardableResult
    public static func pushSubmodules(_ exec: any Executor, worktree: String, repos: [ChatRepo], branch: String,
                                      readOnly: Set<String> = []) async throws -> [String] {
        var pushed: [String] = []
        func stop(_ why: String) -> AbstractError {
            .message((pushed.isEmpty ? "" : "Pushed \(pushed.joined(separator: ", ")). ") + why)
        }
        for repo in order(repos) where repo.isSubmodule && !readOnly.contains(repo.path) {
            let dir = repo.directory(in: worktree)
            guard await commitsNoRemoteHas(exec, dir, ["HEAD"]) > 0 else { continue }
            switch await ensureBranch(exec, directory: dir, name: branch) {
            case .leftDetached:
                throw stop("\(repo.path) is on a detached commit while its branch \(branch) is somewhere else, so it wasn't pushed. "
                           + "Put \(repo.path) on a branch first.")
            case .failed(let why):
                throw stop("Couldn't put \(repo.path) on branch \(branch), so it wasn't pushed: \(why)")
            case .created, .switched, .alreadyOn, .keptOwn:
                break
            }
            // Its submodules were pushed before it, so what's still missing won't come.
            if repos.contains(where: { $0.path != repo.path && repo.inside($0.path) != nil }),
               let problem = await unpublishedPointers(exec, worktree: worktree, repos: repos, in: repo, base: nil).first {
                throw stop(explain(problem, in: repo))
            }
            let target = ((try? await Git.currentBranch(exec, root: dir)) ?? nil) ?? branch
            do {
                try await Git.push(exec, worktree: dir, branch: target)
            } catch {
                throw stop("\(repo.path) didn't push, so nothing that points at it was: \(error.localizedDescription)")
            }
            pushed.append(repo.path)
        }
        return pushed
    }

    /// Why submodule `repo` wasn't pushed, from the first of its own pointers
    /// its submodule's origin doesn't have.
    private static func explain(_ pointer: UnpublishedPointer, in repo: ChatRepo) -> String {
        let child = repo.inside(pointer.repo.path) ?? pointer.repo.path
        switch pointer.reason {
        case .notOnOrigin:
            return "Didn't push \(repo.path): it points at \(child)'s \(pointer.sha.prefix(7)), which isn't on \(child)'s origin."
        case .unreachable(let why):
            return "Didn't push \(repo.path): couldn't check \(child) against its origin (\(why))."
        case .unreadable(let why):
            return "Didn't push \(repo.path): couldn't read which submodule pointers it moves (\(why))."
        }
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

    /// Commits from `from` that no remote-tracking branch holds, nor a tag:
    /// the repository's own stand for what was released (the guard still
    /// asks origin about a pointer), origin's for what it has.
    private static func commitsNoRemoteHas(_ exec: any Executor, _ directory: String, _ from: [String]) async -> Int {
        let args = ["rev-list", "--count"] + from + ["--not", "--remotes", "--tags", "--glob=\(originTags)*"]
        guard let out = try? await Git.git(exec, cwd: directory, args), out.ok else { return 0 }
        return Int(GitText.trimmed(out.stdout)) ?? 0
    }

    /// The pointers the worktree's commits would publish that their
    /// submodules' origins don't have. Only pointers moved by commits origin
    /// doesn't have yet are checked, each after fetching its submodule's
    /// origin; one that can't be fetched counts, since letting a bad pointer
    /// through can't be taken back. A submodule that isn't checked out can't
    /// hold commits of its own, so it isn't asked. `base` is what the branch
    /// was made from, for when it has no upstream yet.
    public static func unpublishedPointers(_ exec: any Executor, worktree: String, repos: [ChatRepo],
                                           base: String? = nil) async -> [UnpublishedPointer] {
        let top = repos.first(where: \.path.isEmpty) ?? ChatRepo(path: "")
        return await unpublishedPointers(exec, worktree: worktree, repos: repos, in: top, base: base)
    }

    /// The same for the pointers `repo`'s own commits publish: the worktree's,
    /// or a submodule's that has submodules of its own, theirs read by their
    /// paths inside it.
    static func unpublishedPointers(_ exec: any Executor, worktree: String, repos: [ChatRepo], in repo: ChatRepo,
                                    base: String?) async -> [UnpublishedPointer] {
        let dir = repo.directory(in: worktree)
        // What origin has of the branch: its upstream, else where it left its base.
        let from: String
        if await revision(exec, dir, "@{upstream}") != nil {
            from = "@{upstream}"
        } else if let base = await Diff.resolveBase(exec, worktree: dir, preferred: base),
                  let fork = await Diff.mergeBase(exec, worktree: dir, base: base) {
            from = fork
        } else {
            // Nothing on origin at all: every pointer at HEAD is new to it.
            from = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
        }
        let out: ExecResult
        do {
            out = try await Git.git(exec, cwd: dir, ["diff", "--raw", "-z", "--no-abbrev", "--no-renames", from, "HEAD"])
        } catch {
            return [unreadable(repo, error.localizedDescription)]
        }
        guard out.ok else { return [unreadable(repo, reason(out, "git diff failed"))] }
        var found: [UnpublishedPointer] = []
        var fields = Submodules.nulFields(out.stdout)[...]
        // ":<old mode> <new mode> <old sha> <new sha> <status>", then the path.
        while let header = fields.popFirst(), let path = fields.popFirst() {
            let parts = header.dropFirst().split(separator: " ").map(String.init)
            guard parts.count >= 4, parts[1] == "160000" else { continue }
            let sha = parts[3]
            guard let child = repos.first(where: { $0.isSubmodule && repo.inside($0.path) == path }) else {
                // Checked out yet not listed: listing the submodules failed, so
                // what it holds can't be told.
                let unlisted = ChatRepo(path: repo.isSubmodule ? repo.path + "/" + path : path, depth: repo.depth + 1, parentPath: repo.path)
                if await Submodules.isCheckedOut(exec, directory: unlisted.directory(in: worktree)) {
                    found.append(UnpublishedPointer(repo: unlisted, sha: sha, reason: .unreadable("couldn't list \(unlisted.path)")))
                }
                continue
            }
            let childDir = child.directory(in: worktree)
            do {
                try await fetchOrigin(exec, childDir)
            } catch {
                found.append(UnpublishedPointer(repo: child, sha: sha, reason: .unreachable(error.localizedDescription)))
                continue
            }
            let missing = try? await Git.git(exec, cwd: childDir, ["rev-list", sha, "--not", "--remotes=origin", "--glob=\(originTags)*"])
            if missing?.ok != true || !GitText.trimmed(missing?.stdout ?? "").isEmpty {
                found.append(UnpublishedPointer(repo: child, sha: sha, reason: .notOnOrigin))
            }
        }
        return found
    }

    /// Blocking `repo` itself, since its pointers couldn't be read: blocking
    /// by mistake beats letting a bad one through.
    private static func unreadable(_ repo: ChatRepo, _ why: String) -> UnpublishedPointer {
        UnpublishedPointer(repo: repo, sha: "", reason: .unreadable(why))
    }

    /// Why a git run failed, in git's words.
    private static func reason(_ out: ExecResult, _ fallback: String) -> String {
        let trimmed = GitText.trimmed(out.stderr)
        return GitText.failure(out.stderr) ?? (trimmed.isEmpty ? fallback : trimmed)
    }

    /// Where origin's tags are fetched to, apart from the repository's own:
    /// a local tag says nothing of what origin has.
    static let originTags = "refs/abstract/origin-tags/"

    /// Fetches every branch and tag of origin into the repository at
    /// `directory`, whatever its own fetch refspec names (a shallow
    /// submodule's names one branch): a branch just pushed, or a release only
    /// a tag holds, is on origin too. In a shallow clone this brings the
    /// history of branches and tags its shallow commits don't reach; `--depth`
    /// would cut the clone's own history at each tip instead, hiding the
    /// agent's commits. Never asks for credentials, gives up after 30 seconds.
    private static func fetchOrigin(_ exec: any Executor, _ directory: String) async throws {
        let spec = LaunchSpec(command: "git", args: ["fetch", "--quiet", "--prune", "--no-tags", "origin",
                                                     "+refs/heads/*:refs/remotes/origin/*", "+refs/tags/*:\(originTags)*"],
                              cwd: directory, env: ["GIT_TERMINAL_PROMPT": "0"], keepStdinOpen: false)
        let result = try await exec.run(spec, timeout: .seconds(30))
        if result.timedOut { throw AbstractError.message("its origin didn't answer within 30 seconds") }
        guard result.ok else { throw AbstractError.message(GitText.failure(result.stderr) ?? result.lastLine ?? "git fetch failed") }
    }
}
