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
            throw AbstractError.command(
                code: out.code, stderr: "git \(args.joined(separator: " ")): \(GitText.trimmed(out.stderr))")
        }
        return out.stdout
    }

    // MARK: Repository

    /// `git rev-parse --show-toplevel`: the real repo root for a directory.
    public static func repoRoot(_ exec: any Executor, dir: String) async throws -> String {
        let out = try await git(exec, cwd: dir, ["rev-parse", "--show-toplevel"])
        guard out.ok else { throw AbstractError.message("\(dir) is not inside a git repository") }
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
    /// With `sparse` folders, only those (plus files at the root) are checked
    /// out, in cone mode; the setting is the worktree's own.
    public static func addWorktree(_ exec: any Executor, root: String, path: String, branch: String,
                                   baseRef: String = "HEAD", sparse: [String] = []) async throws {
        let parent = (path as NSString).deletingLastPathComponent
        if !parent.isEmpty { try exec.createDirectory(parent) }
        let base = GitText.trimmed(baseRef).isEmpty ? "HEAD" : baseRef
        let dirs = SparseCheckout.normalize(sparse)
        let noCheckout = dirs.isEmpty ? [] : ["--no-checkout"]
        var createdBranch = true
        let out = try await git(exec, cwd: root, ["worktree", "add"] + noCheckout + ["-b", branch, path, base])
        if !out.ok {
            createdBranch = false
            let retry = try await git(exec, cwd: root, ["worktree", "add"] + noCheckout + [path, branch])
            if !retry.ok {
                throw AbstractError.command(code: out.code, stderr: "git worktree add: \(GitText.trimmed(out.stderr))")
            }
        }
        if !dirs.isEmpty {
            do {
                _ = try await gitOK(exec, cwd: path, ["sparse-checkout", "set", "--cone"] + dirs)
                _ = try await gitOK(exec, cwd: path, ["checkout"])
            } catch {
                // Never leave a half-made worktree behind: a full checkout
                // might be exactly what sparse was there to avoid.
                try? await removeWorktree(exec, root: root, path: path, deleteBranch: createdBranch ? branch : nil)
                throw AbstractError.message("Sparse checkout failed: \(error.localizedDescription)")
            }
        }
        // Submodules, when present; otherwise the worktree is missing their content.
        if exec.fileExists(GitText.trimTrailingSlashes(root) + "/.gitmodules") {
            _ = try? await git(exec, cwd: path, ["submodule", "update", "--init", "--recursive"])
        }
    }

    // MARK: Publishing

    /// Stages and commits everything in the worktree. Nothing to commit is not an error.
    public static func commitAll(_ exec: any Executor, worktree: String, message: String) async throws {
        _ = try await gitOK(exec, cwd: worktree, ["add", "-A"])
        let staged = try await git(exec, cwd: worktree, ["diff", "--cached", "--quiet"])
        guard !staged.ok else { return }
        _ = try await gitOK(exec, cwd: worktree, ["commit", "-m", message])
    }

    /// Pushes `branch` to `origin`, setting it as the upstream.
    public static func push(_ exec: any Executor, worktree: String, branch: String) async throws {
        _ = try await gitOK(exec, cwd: worktree, ["push", "-u", "origin", "HEAD:refs/heads/\(branch)"])
    }

    /// What publishing a worktree's branch involves: uncommitted files, and
    /// commits `origin` doesn't have yet (all of them when it has no copy).
    public static func publishState(_ exec: any Executor, worktree: String, branch: String) async -> (uncommitted: Int, unpushed: Int) {
        let status = (try? await gitOK(exec, cwd: worktree, ["status", "--porcelain"])) ?? ""
        let uncommitted = status.split(separator: "\n").count
        let remote = "refs/remotes/origin/\(branch)"
        let hasRemote = (try? await git(exec, cwd: worktree, ["rev-parse", "--verify", "--quiet", remote]))?.ok ?? false
        let args = hasRemote ? ["rev-list", "--count", "\(remote)..HEAD"] : ["rev-list", "--count", "HEAD", "--not", "--remotes=origin"]
        let unpushed = Int(GitText.trimmed((try? await gitOK(exec, cwd: worktree, args)) ?? "")) ?? 0
        return (uncommitted, unpushed)
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
