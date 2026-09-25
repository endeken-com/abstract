import Foundation

/// What changed in one of a chat's repositories.
public struct RepoDiff: Sendable, Hashable, Identifiable {
    public var repo: ChatRepo
    /// Paths include the repository's own (see `FileDiff.repo`).
    public var files: [FileDiff]
    /// A submodule: the chat's commits in it since its baseline.
    public var ahead: Int
    /// A submodule that didn't exist where the branch left its base.
    public var isNew: Bool
    /// Why this submodule couldn't be read; its files are empty then.
    public var error: String?

    public var id: String { repo.id }

    public init(repo: ChatRepo, files: [FileDiff] = [], ahead: Int = 0, isNew: Bool = false, error: String? = nil) {
        self.repo = repo; self.files = files; self.ahead = ahead; self.isNew = isNew; self.error = error
    }
}

public extension Diff {
    /// What `compare` changed in each of `repos`, the worktree's own first.
    /// Submodules are compared from their `baselines`, so a committed review
    /// shows the chat's own work in them and not what their main did since.
    /// The worktree's own failing throws; a submodule failing is reported in
    /// its `RepoDiff` and the others still load.
    static func collectAll(_ exec: any Executor, worktree: String, repos: [ChatRepo], exclude: [String] = [],
                           compare: DiffCompare, baselines: [String: String] = [:],
                           ignoreWhitespace: Bool = false) async throws -> [RepoDiff] {
        guard let top = repos.first(where: { !$0.isSubmodule }) else { return [] }
        let own = try await collectRepo(exec, worktree: worktree, repo: top, repos: repos, exclude: exclude,
                                        compare: compare, baselines: baselines, ignoreWhitespace: ignoreWhitespace)
        let submodules = repos.filter(\.isSubmodule)
        var found: [String: RepoDiff] = [:]
        // A few at a time: each has its own index, so they never wait on each other's lock.
        for start in stride(from: 0, to: submodules.count, by: 4) {
            let batch = Array(submodules[start..<min(start + 4, submodules.count)])
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
            all += await commits(exec, worktree: repo.directory(in: worktree), base: from, limit: limit).map { commit in
                var commit = commit
                commit.repo = repo.path
                return commit
            }
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
        var result = RepoDiff(repo: repo, isNew: repo.isSubmodule && !baselines.isEmpty && baseline == nil)
        if repo.isSubmodule, let baseline { result.ahead = await commitCount(exec, cwd: dir, "\(baseline)..HEAD") }
        let own: DiffCompare? = switch compare {
        case .uncommitted: .uncommitted
        case .committed(let base): repo.isSubmodule ? baseline.map { DiffCompare.committed(base: $0) } : .committed(base: base)
        case .commit(let sha, let inRepo): inRepo == repo.path ? .commit(sha: sha) : nil
        }
        guard let own else { return result }
        result.files = try await collect(exec, worktree: dir, exclude: excluded, compare: own, ignoreWhitespace: ignoreWhitespace)
            .map { $0.inRepo(repo.path) }
        return result
    }

    private static func commitCount(_ exec: any Executor, cwd: String, _ range: String) async -> Int {
        guard let out = try? await Git.git(exec, cwd: cwd, ["rev-list", "--count", range]), out.ok else { return 0 }
        return Int(GitText.trimmed(out.stdout)) ?? 0
    }
}
