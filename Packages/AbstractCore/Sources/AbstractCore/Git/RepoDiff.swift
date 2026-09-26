import Foundation

/// What changed in one of a chat's repositories.
public struct RepoDiff: Sendable, Hashable, Identifiable {
    public var repo: ChatRepo
    /// Paths include the repository's own (see `FileDiff.repo`).
    public var files: [FileDiff]
    /// A submodule: the chat's commits in it since its baseline; in
    /// Uncommitted, since the commit its parent's HEAD records, so the ones
    /// the parent hasn't committed yet.
    public var ahead: Int
    /// A submodule that didn't exist where the branch left its base (Committed only).
    public var isNew: Bool
    /// Why this submodule couldn't be read; its files are empty then.
    public var error: String?
    /// A submodule checked out somewhere other than the commit its parent's
    /// HEAD records, so the parent still has a pointer to commit (Uncommitted
    /// only). Its own files can all be committed, leaving nothing else to show.
    public var pointerUncommitted: Bool
    /// With `pointerUncommitted`: the submodule's commits its parent hasn't
    /// recorded yet, newest first. Committed there, so they aren't files to
    /// discard; each opens as one commit instead.
    public var unrecorded: [CommitSummary]

    public var id: String { repo.id }

    public init(repo: ChatRepo, files: [FileDiff] = [], ahead: Int = 0, isNew: Bool = false, error: String? = nil,
                pointerUncommitted: Bool = false, unrecorded: [CommitSummary] = []) {
        self.repo = repo; self.files = files; self.ahead = ahead; self.isNew = isNew; self.error = error
        self.pointerUncommitted = pointerUncommitted; self.unrecorded = unrecorded
    }
}

public extension Diff {
    /// What `compare` changed in each of `repos`, the worktree's own first.
    /// Submodules are compared from their `baselines`, so a committed review
    /// shows the chat's own work in them and not what their main did since.
    /// The worktree's own failing throws; a submodule failing is reported in
    /// its `RepoDiff` and the others still load.
    ///
    /// Read on every change the agent makes, so a submodule with nothing to
    /// show costs little git: in Uncommitted, one the worktree's status calls
    /// clean isn't read, nor are the submodules inside it; in Committed, one
    /// still at its baseline only has its HEAD read; for one commit, only the
    /// commit's repository is read.
    static func collectAll(_ exec: any Executor, worktree: String, repos: [ChatRepo], exclude: [String] = [],
                           compare: DiffCompare, baselines: [String: String] = [:],
                           ignoreWhitespace: Bool = false) async throws -> [RepoDiff] {
        guard let top = repos.first(where: { !$0.isSubmodule }) else { return [] }
        let own = try await collectRepo(exec, worktree: worktree, repo: top, repos: repos, exclude: exclude,
                                        compare: compare, baselines: baselines, ignoreWhitespace: ignoreWhitespace)
        let submodules = repos.filter(\.isSubmodule)
        var found: [String: RepoDiff] = [:]
        // The worktree's status covers everything inside its submodules too.
        if case .uncommitted = compare, !submodules.isEmpty, let changed = await Submodules.changedPaths(exec, worktree: worktree) {
            let clean = submodules.filter { $0.parentPath == "" && !changed.contains($0.path) }
            for repo in submodules where clean.contains(where: { $0.path == repo.path || $0.inside(repo.path) != nil }) {
                found[repo.path] = RepoDiff(repo: repo)
            }
        }
        let toRead = submodules.filter { found[$0.path] == nil }
        // A few at a time: each has its own index, so they never wait on each other's lock.
        for start in stride(from: 0, to: toRead.count, by: 4) {
            let batch = Array(toRead[start..<min(start + 4, toRead.count)])
            let done = await withTaskGroup(of: RepoDiff.self, returning: [RepoDiff].self) { group in
                for repo in batch {
                    group.addTask {
                        do {
                            return try await collectRepo(exec, worktree: worktree, repo: repo, repos: repos, exclude: exclude,
                                                         compare: compare, baselines: baselines, ignoreWhitespace: ignoreWhitespace)
                        } catch {
                            return RepoDiff(repo: repo, error: error.localizedDescription)
                        }
                    }
                }
                var out: [RepoDiff] = []
                for await diff in group { out.append(diff) }
                return out
            }
            for diff in done { found[diff.repo.path] = diff }
        }
        return [own] + submodules.compactMap { found[$0.path] }
    }

    /// Everything uncommitted in the worktree and its submodules, as one
    /// list: what the chat's summary and the composer's totals count.
    static func collectUncommitted(_ exec: any Executor, worktree: String, exclude: [String] = []) async throws -> [FileDiff] {
        let repos = await Submodules.list(exec, worktree: worktree)
        return try await collectAll(exec, worktree: worktree, repos: repos, exclude: exclude, compare: .uncommitted).flatMap(\.files)
    }

    /// The branch's own commits in every repository, newest first, each
    /// naming its repository; a submodule's since its baseline.
    static func commitsAll(_ exec: any Executor, worktree: String, repos: [ChatRepo], base: String,
                           baselines: [String: String], limit: Int = 100) async -> [CommitSummary] {
        var all: [CommitSummary] = []
        for repo in repos {
            guard let from = repo.isSubmodule ? baselines[repo.path] : base else { continue }
            all += await commits(exec, worktree: repo.directory(in: worktree), base: from, limit: limit).map { $0.inRepo(repo.path) }
        }
        guard repos.count > 1 else { return all }
        // Newest first; commits from the same second keep their own order.
        return all.enumerated().sorted { a, b in
            let (x, y) = (a.element.date ?? .distantPast, b.element.date ?? .distantPast)
            return x != y ? x > y : a.offset < b.offset
        }.prefix(limit).map(\.element)
    }

    private static func collectRepo(_ exec: any Executor, worktree: String, repo: ChatRepo, repos: [ChatRepo], exclude: [String],
                                    compare: DiffCompare, baselines: [String: String], ignoreWhitespace: Bool) async throws -> RepoDiff {
        let dir = repo.directory(in: worktree)
        // Its own submodules are read on their own; inner repositories git
        // doesn't know about stay out, as they always have.
        let inner = repos.filter { $0.parentPath == repo.path }.compactMap { repo.inside($0.path) }
        let excluded = exclude.compactMap(repo.inside) + inner
        let baseline = baselines[repo.path]
        var result = RepoDiff(repo: repo)
        let own: DiffCompare
        switch compare {
        case .uncommitted:
            own = .uncommitted
            if repo.isSubmodule, let recorded = await recordedCommit(exec, worktree: worktree, of: repo, repos: repos),
               let head = await head(exec, cwd: dir), head != recorded {
                result.pointerUncommitted = true
                result.ahead = await commitCount(exec, cwd: dir, "\(recorded)..HEAD")
                result.unrecorded = await commits(exec, worktree: dir, base: recorded).map { $0.inRepo(repo.path) }
            }
        case .committed(let base):
            guard repo.isSubmodule else { own = .committed(base: base); break }
            guard let baseline else {
                result.isNew = !baselines.isEmpty
                return result
            }
            guard await head(exec, cwd: dir) != baseline else { return result }
            result.ahead = await commitCount(exec, cwd: dir, "\(baseline)..HEAD")
            // Straight from the recorded commit: a pointer moved back or
            // sideways has no merge base to measure from.
            own = .since(sha: baseline)
        case .since:
            // Not a mode of the review's: the worktree's own alone.
            guard !repo.isSubmodule else { return result }
            own = compare
        case .commit(let sha, let inRepo):
            guard inRepo == repo.path else { return result }
            if repo.isSubmodule, let baseline { result.ahead = await commitCount(exec, cwd: dir, "\(baseline)..HEAD") }
            own = .commit(sha: sha)
        }
        result.files = try await collect(exec, worktree: dir, exclude: excluded, compare: own, ignoreWhitespace: ignoreWhitespace)
            .map { $0.inRepo(repo.path) }
        return result
    }

    /// The commit `repo`'s parent's HEAD records for it; nil when it records none.
    private static func recordedCommit(_ exec: any Executor, worktree: String, of repo: ChatRepo, repos: [ChatRepo]) async -> String? {
        guard let parent = repos.first(where: { $0.path == repo.parentPath }), let inside = parent.inside(repo.path),
              let out = try? await Git.git(exec, cwd: parent.directory(in: worktree), ["rev-parse", "HEAD:\(inside)"]), out.ok
        else { return nil }
        let sha = GitText.trimmed(out.stdout)
        return sha.isEmpty ? nil : sha
    }

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

extension CommitSummary {
    /// The same commit, named as the submodule at `repo`'s.
    func inRepo(_ repo: String) -> CommitSummary {
        var commit = self
        commit.repo = repo
        return commit
    }
}
