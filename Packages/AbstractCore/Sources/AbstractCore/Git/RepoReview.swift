import Foundation

/// A submodule's pointer, as one change of its parent's: the commit the
/// parent had it at, and the one it's at now.
public struct PointerChange: Sendable, Hashable, Identifiable {
    public var repo: ChatRepo
    /// Nil when the parent didn't have the submodule yet.
    public var from: String?
    /// Nil when the parent no longer has it.
    public var to: String?
    /// Commits `to` has that `from` doesn't, and the other way round.
    public var ahead: Int
    public var behind: Int
    /// Committed in the parent (Committed, one commit) or not yet (Uncommitted).
    public var isCommitted: Bool

    public var id: String { repo.id }

    public init(repo: ChatRepo, from: String?, to: String?, ahead: Int = 0, behind: Int = 0, isCommitted: Bool) {
        self.repo = repo; self.from = from; self.to = to; self.ahead = ahead; self.behind = behind; self.isCommitted = isCommitted
    }
}

/// One repository of a chat's worktree, reviewed on its own the way a
/// single repository always has been: its uncommitted work, its commits
/// since it left its own base branch, or one of them. Its submodules' files
/// aren't among its files; to it each submodule is a pointer.
public enum RepoReview {
    /// Whether it has anything uncommitted (a moved submodule pointer
    /// included, work inside a submodule not), what Committed measures from,
    /// and its own commits since then, newest first.
    public static func state(_ exec: any Executor, worktree: String, repo: ChatRepo,
                             preferredBase: String?) async -> (dirty: Bool, base: String?, commits: [CommitSummary]) {
        let dir = repo.directory(in: worktree)
        // Polled often, beside agents running git: don't take the index lock to refresh it.
        let status = try? await Git.git(exec, cwd: dir, ["--no-optional-locks", "status", "--porcelain", "--ignore-submodules=dirty"])
        let dirty = status.map { $0.ok && !GitText.trimmed($0.stdout).isEmpty } ?? false
        let base = await Diff.resolveBase(exec, worktree: dir, preferred: preferredBase)
        let commits = if let base { await Diff.commits(exec, worktree: dir, base: base).map { $0.inRepo(repo.path) } } else { [CommitSummary]() }
        return (dirty, base, commits)
    }

    /// The files `compare` changed in `repo` (paths from the worktree), and
    /// its submodules whose pointers `compare` moves.
    public static func changes(_ exec: any Executor, worktree: String, repo: ChatRepo, repos: [ChatRepo], exclude: [String] = [],
                               compare: DiffCompare, ignoreWhitespace: Bool = false) async throws -> (files: [FileDiff], pointers: [PointerChange]) {
        let files = try await files(exec, worktree: worktree, repo: repo, repos: repos, exclude: exclude, compare: compare,
                                    ignoreWhitespace: ignoreWhitespace)
        return (files, await pointers(exec, worktree: worktree, repo: repo, repos: repos, compare: compare))
    }

    static func files(_ exec: any Executor, worktree: String, repo: ChatRepo, repos: [ChatRepo], exclude: [String],
                      compare: DiffCompare, ignoreWhitespace: Bool) async throws -> [FileDiff] {
        // Its own submodules are read on their own; inner repositories git
        // doesn't know about stay out, as they always have.
        let inner = repos.filter { $0.parentPath == repo.path }.compactMap { repo.inside($0.path) }
        return try await Diff.collect(exec, worktree: repo.directory(in: worktree), exclude: exclude.compactMap(repo.inside) + inner,
                                      compare: compare, ignoreWhitespace: ignoreWhitespace).map { $0.inRepo(repo.path) }
    }

    /// Read from `repo`'s own gitlinks, so a submodule that isn't checked out
    /// still counts when a commit moved it.
    static func pointers(_ exec: any Executor, worktree: String, repo: ChatRepo, repos: [ChatRepo],
                         compare: DiffCompare) async -> [PointerChange] {
        let dir = repo.directory(in: worktree)
        let range: [String]
        switch compare {
        case .uncommitted: range = ["HEAD"]
        case .committed(let base): range = [await Diff.mergeBase(exec, worktree: dir, base: base) ?? base, "HEAD"]
        case .commit(let sha, _): range = [sha + "^", sha]
        }
        // Only where a pointer points counts: work inside a submodule is the submodule's.
        guard let out = try? await Git.git(exec, cwd: dir, ["diff", "--raw", "-z", "--no-abbrev", "--no-renames",
                                                            "--ignore-submodules=dirty"] + range), out.ok else { return [] }
        var changes: [PointerChange] = []
        var fields = Submodules.nulFields(out.stdout)[...]
        // ":<old mode> <new mode> <old sha> <new sha> <status>", then the path.
        while let header = fields.popFirst(), let path = fields.popFirst() {
            let parts = header.dropFirst().split(separator: " ").map(String.init)
            guard parts.count >= 4, parts[0] == "160000" || parts[1] == "160000" else { continue }
            let full = repo.isSubmodule ? repo.path + "/" + path : path
            let child = repos.first { $0.path == full } ?? ChatRepo(path: full, depth: repo.depth + 1, parentPath: repo.path)
            let from = parts[0] == "160000" ? parts[2] : nil
            var to = parts[1] == "160000" ? parts[3] : nil
            // In the working tree git leaves the new commit unnamed: it's wherever the submodule is.
            if to.map(isZero) == true { to = await head(exec, cwd: child.directory(in: worktree)) }
            var change = PointerChange(repo: child, from: from, to: to, isCommitted: compare != .uncommitted)
            if let from, let to, repos.contains(where: { $0.path == full }) {
                let childDir = child.directory(in: worktree)
                change.ahead = await commitCount(exec, cwd: childDir, "\(from)..\(to)")
                change.behind = await commitCount(exec, cwd: childDir, "\(to)..\(from)")
            }
            changes.append(change)
        }
        return changes
    }

    private static func isZero(_ sha: String) -> Bool { sha.allSatisfy { $0 == "0" } }

    private static func head(_ exec: any Executor, cwd: String) async -> String? {
        guard let out = try? await Git.git(exec, cwd: cwd, ["rev-parse", "HEAD"]), out.ok else { return nil }
        let sha = GitText.trimmed(out.stdout)
        return sha.isEmpty ? nil : sha
    }

    private static func commitCount(_ exec: any Executor, cwd: String, _ range: String) async -> Int {
        guard let out = try? await Git.git(exec, cwd: cwd, ["rev-list", "--count", range]), out.ok else { return 0 }
        return Int(GitText.trimmed(out.stdout)) ?? 0
    }
}

public extension Diff {
    /// Everything uncommitted in the worktree and its submodules, as one
    /// list: what the chat's summary and the composer's totals count.
    static func collectUncommitted(_ exec: any Executor, worktree: String, exclude: [String] = []) async throws -> [FileDiff] {
        try await collectUncommitted(exec, worktree: worktree, repos: await Submodules.list(exec, worktree: worktree), exclude: exclude)
    }

    /// Read after every change the agent makes, so a submodule the worktree's
    /// status calls clean isn't read, nor are the ones inside it. The
    /// worktree's own failing throws; a submodule that can't be read is left out.
    internal static func collectUncommitted(_ exec: any Executor, worktree: String, repos: [ChatRepo],
                                            exclude: [String]) async throws -> [FileDiff] {
        guard let top = repos.first(where: { !$0.isSubmodule }) else { return [] }
        let own = try await RepoReview.files(exec, worktree: worktree, repo: top, repos: repos, exclude: exclude,
                                             compare: .uncommitted, ignoreWhitespace: false)
        var submodules = repos.filter(\.isSubmodule)
        if !submodules.isEmpty, let changed = await Submodules.changedPaths(exec, worktree: worktree) {
            let clean = submodules.filter { $0.parentPath == "" && !changed.contains($0.path) }
            submodules.removeAll { repo in clean.contains { $0.path == repo.path || $0.inside(repo.path) != nil } }
        }
        var found: [String: [FileDiff]] = [:]
        // A few at a time: each has its own index, so they never wait on each other's lock.
        for start in stride(from: 0, to: submodules.count, by: 4) {
            let batch = Array(submodules[start..<min(start + 4, submodules.count)])
            let done = await withTaskGroup(of: (String, [FileDiff]).self, returning: [(String, [FileDiff])].self) { group in
                for repo in batch {
                    group.addTask {
                        let files = try? await RepoReview.files(exec, worktree: worktree, repo: repo, repos: repos, exclude: exclude,
                                                                compare: .uncommitted, ignoreWhitespace: false)
                        return (repo.path, files ?? [])
                    }
                }
                var out: [(String, [FileDiff])] = []
                for await result in group { out.append(result) }
                return out
            }
            for (path, files) in done { found[path] = files }
        }
        return own + submodules.flatMap { found[$0.path] ?? [] }
    }
}

extension CommitSummary {
    /// The same commit, named as the submodule at `repo`'s.
    func inRepo(_ repo: String) -> CommitSummary {
        var commit = self
        commit.repo = repo
        return commit
    }
}
