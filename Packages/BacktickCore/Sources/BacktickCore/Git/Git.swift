import Foundation

public struct WorktreeInfo: Sendable, Hashable, Identifiable {
    public var path: String
    public var head: String?
    public var branch: String?
    public var isBare: Bool
    public var isDetached: Bool
    public var isLocked: Bool

    public var id: String { path }

    public init(path: String, head: String? = nil, branch: String? = nil, isBare: Bool = false,
                isDetached: Bool = false, isLocked: Bool = false) {
        self.path = path; self.head = head; self.branch = branch
        self.isBare = isBare; self.isDetached = isDetached; self.isLocked = isLocked
    }
}

/// Git plumbing over an `Executor`, so it works unchanged on any host.
public enum Git {
    // MARK: Running git

    static func git(_ exec: any Executor, cwd: String?, _ args: [String]) async throws -> ExecResult {
        try await exec.run("git", args, cwd: cwd)
    }

    /// Stdout of a git command that must succeed.
    static func gitOK(_ exec: any Executor, cwd: String?, _ args: [String]) async throws -> String {
        let out = try await git(exec, cwd: cwd, args)
        guard out.ok else {
            throw BacktickError.command(
                code: out.code, stderr: "git \(args.joined(separator: " ")): \(GitText.trimmed(out.stderr))")
        }
        return out.stdout
    }

    // MARK: Repository

    /// `git rev-parse --show-toplevel`: the real repo root for a directory.
    public static func repoRoot(_ exec: any Executor, dir: String) async throws -> String {
        let out = try await git(exec, cwd: dir, ["rev-parse", "--show-toplevel"])
        guard out.ok else { throw BacktickError.message("\(dir) is not inside a git repository") }
        return GitText.trimmed(out.stdout)
    }

    /// The checked-out branch, or nil when HEAD is detached.
    public static func currentBranch(_ exec: any Executor, root: String) async throws -> String? {
        let out = try await git(exec, cwd: root, ["symbolic-ref", "--short", "HEAD"])
        let branch = GitText.trimmed(out.stdout)
        return out.ok && !branch.isEmpty ? branch : nil
    }

    public static func branchExists(_ exec: any Executor, root: String, branch: String) async -> Bool {
        (try? await git(exec, cwd: root, ["rev-parse", "--verify", "--quiet", branch]))?.ok ?? false
    }

    /// Inner repositories / submodules under `root` (relative paths), which a
    /// single worktree cannot carry.
    public static func nestedRepos(_ exec: any Executor, root: String) async throws -> [String] {
        let out = try await exec.run(
            "find",
            [root, "-mindepth", "2", "-maxdepth", "5", "-name", ".git",
             "-not", "-path", "*/node_modules/*", "-not", "-path", "*/.git/*"],
            cwd: nil)
        let rootTrimmed = GitText.trimTrailingSlashes(root)
        return GitText.lines(out.stdout).prefix(50).compactMap { line -> String? in
            let p = GitText.trimmed(line)
            if p.isEmpty { return nil }
            var dir = p.hasSuffix("/.git") ? String(p.dropLast(5)) : p
            if GitText.hasPrefix(dir, rootTrimmed) { dir = GitText.dropPrefix(dir, rootTrimmed) }
            let rel = String(dir.drop(while: { $0 == "/" }))
            return rel.isEmpty ? nil : rel
        }
    }

    // MARK: Worktrees

    public static func worktrees(_ exec: any Executor, root: String) async throws -> [WorktreeInfo] {
        parseWorktreeList(try await gitOK(exec, cwd: root, ["worktree", "list", "--porcelain"]))
    }

    static func parseWorktreeList(_ output: String) -> [WorktreeInfo] {
        var result: [WorktreeInfo] = []
        var current: WorktreeInfo?
        for rawLine in GitText.lines(output) {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            if line.isEmpty {
                if let w = current { result.append(w) }
                current = nil
                continue
            }
            let (key, value) = GitText.splitOnce(line, " ") ?? (line, "")
            switch key {
            case "worktree":
                if let w = current { result.append(w) }
                current = WorktreeInfo(path: value)
            case "HEAD": current?.head = value
            case "branch": current?.branch = GitText.dropPrefix(value, "refs/heads/")
            case "bare": current?.isBare = true
            case "detached": current?.isDetached = true
            case "locked": current?.isLocked = true
            default: break
            }
        }
        if let w = current { result.append(w) }
        return result
    }

    /// Create a worktree at `path` on a new `branch` from `baseRef`. When the
    /// branch already exists (a restarted automation), attach to it instead.
    public static func addWorktree(_ exec: any Executor, root: String, path: String, branch: String,
                                   baseRef: String = "HEAD") async throws {
        let parent = (path as NSString).deletingLastPathComponent
        if !parent.isEmpty { try exec.createDirectory(parent) }
        let base = GitText.trimmed(baseRef).isEmpty ? "HEAD" : baseRef
        let out = try await git(exec, cwd: root, ["worktree", "add", "-b", branch, path, base])
        if !out.ok {
            let retry = try await git(exec, cwd: root, ["worktree", "add", path, branch])
            if !retry.ok {
                throw BacktickError.command(code: out.code, stderr: "git worktree add: \(GitText.trimmed(out.stderr))")
            }
        }
        // Submodules, when present; otherwise the worktree is missing their content.
        if exec.fileExists(GitText.trimTrailingSlashes(root) + "/.gitmodules") {
            _ = try? await git(exec, cwd: path, ["submodule", "update", "--init", "--recursive"])
        }
    }

    /// Force-remove a worktree (falling back to deleting the directory and
    /// pruning), optionally deleting its branch too.
    public static func removeWorktree(_ exec: any Executor, root: String, path: String,
                                      deleteBranch: String? = nil) async throws {
        let out = try await git(exec, cwd: root, ["worktree", "remove", "--force", path])
        if !out.ok {
            // The directory may already be gone, or hold submodules git refuses to remove.
            try exec.removeItem(path)
            _ = try? await git(exec, cwd: root, ["worktree", "prune"])
        }
        if let branch = deleteBranch {
            _ = try? await git(exec, cwd: root, ["branch", "-D", branch])
        }
    }

    public static func prune(_ exec: any Executor, root: String) async throws {
        _ = try await gitOK(exec, cwd: root, ["worktree", "prune"])
    }
}
