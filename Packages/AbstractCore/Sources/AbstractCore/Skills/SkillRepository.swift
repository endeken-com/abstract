import Foundation

/// A GitHub skill source's checkout (ABS-122): cloned once, kept at its
/// pinned commit, and moved only by `pin` after you have seen the diff.
/// Abstract never refreshes one on its own.
public enum SkillRepository {
    static let timeout: Duration = .seconds(120)

    /// Clones `url` into `folder` and checks out what its default branch
    /// points to now. Returns that commit, the one the source is pinned to.
    public static func clone(_ exec: any Executor, url: String, into folder: String) async throws -> String {
        try? exec.removeItem(folder)
        try exec.createDirectory((folder as NSString).deletingLastPathComponent)
        _ = try await git(exec, cwd: nil, ["clone", "--quiet", "--no-checkout", url, folder])
        guard let commit = await Git.commit(exec, root: folder, ref: "HEAD") else {
            throw AbstractError.message("\(url) has no commits.")
        }
        try await pin(exec, folder: folder, commit: commit)
        return commit
    }

    /// The commit the repository's default branch points to now, fetched
    /// without changing the checkout.
    public static func latest(_ exec: any Executor, folder: String) async throws -> String {
        _ = try await git(exec, cwd: folder, ["fetch", "--quiet", "--no-tags", "origin", "HEAD"])
        guard let commit = await Git.commit(exec, root: folder, ref: "FETCH_HEAD") else {
            throw AbstractError.message("The repository's latest commit couldn't be read.")
        }
        return commit
    }

    /// What changes between two commits, as `git diff` prints it: every
    /// file as text, so the repository's own attributes can't hide a change.
    public static func diff(_ exec: any Executor, folder: String, from: String, to: String) async throws -> String {
        try await git(exec, cwd: folder, ["-c", "core.attributesFile=/dev/null", "diff", "--no-color", "--no-ext-diff",
                                          "--no-textconv", "--text", from, to])
    }

    /// Checks out `commit`, detached; anything changed by hand in the checkout is dropped.
    public static func pin(_ exec: any Executor, folder: String, commit: String) async throws {
        _ = try await git(exec, cwd: folder, ["checkout", "--quiet", "--force", "--detach", commit])
    }

    /// Stdout of a git command that must succeed. Never asks for credentials.
    private static func git(_ exec: any Executor, cwd: String?, _ args: [String]) async throws -> String {
        let spec = LaunchSpec(command: "git", args: args, cwd: cwd ?? exec.homeDirectory,
                              env: ["GIT_TERMINAL_PROMPT": "0"], keepStdinOpen: false)
        let result = try await exec.run(spec, timeout: timeout)
        if result.timedOut { throw AbstractError.message("git \(args.first ?? "") gave up after \(timeout.components.seconds) seconds.") }
        guard result.ok else {
            throw AbstractError.message(GitText.failure(result.stderr) ?? result.lastLine ?? "git \(args.first ?? "") failed.")
        }
        return result.stdout
    }
}
