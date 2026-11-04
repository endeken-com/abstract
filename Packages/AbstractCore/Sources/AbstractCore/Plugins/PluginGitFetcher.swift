import Foundation

/// What changed in a plugin's folder between two commits, for an update's summary.
public struct PluginGitChanges: Sendable, Hashable {
    /// Commits that touched the plugin's folder; nil when the installed commit
    /// is no longer in the repository's history (a force-push).
    public var commits: Int?
    /// Files changed in the plugin's folder, relative to it.
    public var files: [String]

    public init(commits: Int?, files: [String]) { self.commits = commits; self.files = files }
}

/// Fetches plugin packages from git repositories (ABS-190). Nothing fetched
/// is run: the files go through `PluginPackage.inspect` like any folder.
public protocol PluginGitFetching: Sendable {
    /// The commit `source.ref` points at now; the default branch without one.
    func resolve(_ source: PluginGitSource) async throws -> String
    /// The repository's files at `commit`, under `source.path`, written into `folder`.
    func download(_ source: PluginGitSource, commit: String, into folder: URL) async throws
    /// Commits and files that changed under `source.path` from one commit to another.
    func compare(_ source: PluginGitSource, from: String, to: String) async throws -> PluginGitChanges
}

public enum PluginGitError: Error, LocalizedError, Sendable, Equatable {
    case gitMissing
    case unreachable(String)
    case noSuchRef(String, String)
    case noSuchFolder(String, String)

    public var errorDescription: String? {
        switch self {
        case .gitMissing: "Abstract needs git to install plugins from a repository, and it isn't installed."
        case .unreachable(let repo): "\(repo) couldn't be reached. If it's private, sign in with `gh auth login` or set up git's access to it, then try again."
        case .noSuchRef(let ref, let repo): "\(repo) has no branch, tag or commit named “\(ref)”."
        case .noSuchFolder(let path, let repo): "\(repo) has no folder “\(path)” at that commit."
        }
    }
}

/// The real fetcher: the system's git, with its own credentials, plus the
/// GitHub CLI's for github.com when it's installed — so a private repository
/// you can clone installs too. Fetches are shallow, into a throwaway bare
/// repository: no checkout, no hooks.
public struct GitPluginFetcher: PluginGitFetching {
    let executor: any Executor
    /// GitHub's address; tests point it at a folder of local repositories.
    let githubBase: String

    public init(executor: any Executor = LocalExecutor.shared, githubBase: String = PluginGitSource.githubBase) {
        self.executor = executor; self.githubBase = githubBase
    }

    public func resolve(_ source: PluginGitSource) async throws -> String {
        if let ref = source.ref, PluginGitSource.isCommit(ref) { return ref.lowercased() }
        let want = source.ref ?? "HEAD"
        let patterns = source.ref == nil ? ["HEAD"] : [want, "refs/tags/\(want)^{}"]
        let result = try await git(["ls-remote", "--", source.remote(githubBase: githubBase)] + patterns,
                                   source: source, cwd: nil)
        guard result.ok else { throw PluginGitError.unreachable(source.repository) }
        var found: [String: String] = [:]
        for line in result.stdout.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { continue }
            found[String(parts[1])] = String(parts[0])
        }
        // A tag's commit, then a branch, then the tag itself, then anything ending in it.
        let order = source.ref == nil ? ["HEAD"]
            : ["refs/tags/\(want)^{}", "refs/heads/\(want)", "refs/tags/\(want)", want]
        if let commit = order.lazy.compactMap({ found[$0] }).first
            ?? found.first(where: { $0.key.hasSuffix("/\(want)") })?.value {
            return commit
        }
        throw PluginGitError.noSuchRef(want, source.repository)
    }

    public func download(_ source: PluginGitSource, commit: String, into folder: URL) async throws {
        let scratch = try scratchRepository()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let fetched = try await git(["fetch", "--quiet", "--depth", "1", "--no-tags", "--",
                                     source.remote(githubBase: githubBase), commit], source: source, cwd: scratch)
        guard fetched.ok else { throw PluginGitError.unreachable(source.repository) }
        let tar = scratch.appendingPathComponent("package.tar")
        let tree = source.path.map { "\(commit):\($0)" } ?? "\(commit)^{tree}"
        let archived = try await git(["archive", "--format=tar", "-o", tar.path, tree], source: source, cwd: scratch)
        guard archived.ok else {
            throw source.path.map { PluginGitError.noSuchFolder($0, source.repository) }
                ?? PluginGitError.unreachable(source.repository)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // bsdtar refuses absolute and `..` paths; links and executables are
        // refused next by `PluginPackage.inspect`.
        let unpacked = try await executor.run("/usr/bin/tar", ["-xf", tar.path, "-C", folder.path], cwd: nil, stdin: nil)
        guard unpacked.ok else { throw PluginValidationError.invalidManifest("the repository's files couldn't be unpacked") }
    }

    public func compare(_ source: PluginGitSource, from: String, to: String) async throws -> PluginGitChanges {
        let scratch = try scratchRepository()
        defer { try? FileManager.default.removeItem(at: scratch) }
        // History and trees only: no file contents are needed to count.
        let fetched = try await git(["fetch", "--quiet", "--filter=blob:none", "--no-tags", "--",
                                     source.remote(githubBase: githubBase), to], source: source, cwd: scratch)
        guard fetched.ok else { throw PluginGitError.unreachable(source.repository) }
        let scope = source.path.map { ["--", $0] } ?? []
        let count = try await git(["rev-list", "--count", "\(from)..\(to)"] + scope, source: source, cwd: scratch)
        let diff = try await git(["diff", "--name-only", "--no-renames", from, to] + scope, source: source, cwd: scratch)
        let prefix = source.path.map { $0 + "/" } ?? ""
        let files = diff.ok ? diff.stdout.split(separator: "\n").map { line in
            line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : String(line)
        } : []
        return PluginGitChanges(commits: count.ok ? Int(GitText.trimmed(count.stdout)) : nil, files: files)
    }

    private func scratchRepository() throws -> URL {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("abstract-plugin-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        return scratch
    }

    /// git with no hooks and no prompts; for GitHub, the GitHub CLI's login
    /// after git's own credential helpers.
    private func git(_ args: [String], source: PluginGitSource, cwd: URL?) async throws -> ExecResult {
        var options = ["-c", "core.hooksPath=/dev/null", "-c", "protocol.ext.allow=never",
                       "-c", "transfer.fsckObjects=true"]
        if source.isGitHub, githubBase == PluginGitSource.githubBase, let gh = await executor.which("gh") {
            options += ["-c", "credential.https://github.com.helper=!'\(gh)' auth git-credential"]
        }
        if let cwd {
            if !FileManager.default.fileExists(atPath: cwd.appendingPathComponent("HEAD").path) {
                let made = try await run(["init", "--quiet", "--bare", cwd.path], cwd: nil)
                guard made.ok else { throw PluginGitError.gitMissing }
            }
            options += ["-C", cwd.path]
        }
        return try await run(options + args, cwd: nil)
    }

    private func run(_ args: [String], cwd: URL?) async throws -> ExecResult {
        do { return try await executor.run("git", args, cwd: cwd?.path, stdin: nil) }
        catch AbstractError.notFound { throw PluginGitError.gitMissing }
    }
}
