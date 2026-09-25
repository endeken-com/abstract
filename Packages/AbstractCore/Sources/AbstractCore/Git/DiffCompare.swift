import Foundation

/// What a review compares. After Paseo's checkout diff (Apache-2.0,
/// Copyright (c) 2025-present Mohamed Boudra): the work not yet committed,
/// the branch's commits since it left its base, or one commit.
public enum DiffCompare: Sendable, Hashable {
    /// The working tree and index against HEAD, new files included.
    case uncommitted
    /// HEAD against where it left `base` (their merge base).
    case committed(base: String)
    /// One commit against its first parent.
    case commit(sha: String)
}

/// A commit on the branch, for the review's commit list.
public struct CommitSummary: Sendable, Hashable, Identifiable {
    public let sha: String
    public let shortSha: String
    public let author: String
    public let date: Date?
    public let subject: String
    public var id: String { sha }
}

extension Diff {
    /// The files `compare` changed. `ignoreWhitespace` is `git diff -w`.
    public static func collect(_ exec: any Executor, worktree: String, exclude: [String] = [],
                               compare: DiffCompare, ignoreWhitespace: Bool = false) async throws -> [FileDiff] {
        let excludes = exclude
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { ":(exclude)" + GitText.trimTrailingSlashes($0) }
        let space = ignoreWhitespace ? ["-w"] : []
        switch compare {
        case .uncommitted:
            guard ignoreWhitespace else { return try await collect(exec, worktree: worktree, exclude: exclude) }
            _ = try await collect(exec, worktree: worktree, exclude: exclude)
            return parse(try await Git.gitOK(exec, cwd: worktree, ["-c", "core.quotePath=false", "--no-pager", "diff", "HEAD", "--no-color",
                                                                    "--no-ext-diff", "-M", "-w", "--", "."] + excludes))
        case .committed(let base):
            let from = await mergeBase(exec, worktree: worktree, base: base) ?? base
            return parse(try await Git.gitOK(exec, cwd: worktree, ["-c", "core.quotePath=false", "--no-pager", "diff", from, "HEAD", "--no-color",
                                                                    "--no-ext-diff", "-M"] + space + ["--", "."] + excludes))
        case .commit(let sha):
            return parse(try await Git.gitOK(exec, cwd: worktree, ["-c", "core.quotePath=false", "--no-pager", "show", sha, "--format=",
                                                                    "--diff-merges=first-parent", "--no-color", "--no-ext-diff", "-M"] + space))
        }
    }

    /// Whether anything is uncommitted, new files included.
    public static func isDirty(_ exec: any Executor, worktree: String) async -> Bool {
        // Polled often, beside agents running git: don't take the index lock to refresh it.
        guard let status = try? await Git.git(exec, cwd: worktree, ["--no-optional-locks", "status", "--porcelain"]), status.ok else { return false }
        return !status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func mergeBase(_ exec: any Executor, worktree: String, base: String) async -> String? {
        guard let out = try? await Git.git(exec, cwd: worktree, ["merge-base", base, "HEAD"]), out.ok else { return nil }
        let sha = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }

    /// The ref a branch is compared with: the one it was made from if that
    /// still exists, else the remote's default branch, else main or master.
    /// A bare branch name prefers its `origin/` copy.
    public static func resolveBase(_ exec: any Executor, worktree: String, preferred: String?) async -> String? {
        func exists(_ ref: String) async -> Bool {
            (try? await Git.git(exec, cwd: worktree, ["rev-parse", "--verify", "--quiet", ref + "^{commit}"]))?.ok ?? false
        }
        func best(_ name: String) async -> String? {
            if !name.contains("/"), await exists("origin/" + name) { return "origin/" + name }
            return await exists(name) ? name : nil
        }
        if let preferred, !preferred.isEmpty, preferred != "HEAD", let ref = await best(preferred) { return ref }
        if let head = try? await Git.git(exec, cwd: worktree, ["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"]), head.ok {
            let ref = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "refs/remotes/", with: "")
            if !ref.isEmpty, await exists(ref) { return ref }
        }
        for name in ["main", "master"] { if let ref = await best(name) { return ref } }
        return nil
    }

    /// The branch's own commits, newest first.
    public static func commits(_ exec: any Executor, worktree: String, base: String, limit: Int = 100) async -> [CommitSummary] {
        let from = await mergeBase(exec, worktree: worktree, base: base) ?? base
        guard let out = try? await Git.git(exec, cwd: worktree, ["log", "\(from)..HEAD", "-n", "\(limit)", "--diff-merges=first-parent",
                                                                  "--format=%H%x00%h%x00%an%x00%aI%x00%s"]), out.ok else { return [] }
        let dates = ISO8601DateFormatter()
        return GitText.lines(out.stdout).compactMap { line in
            let f = line.components(separatedBy: "\u{0}")
            guard f.count == 5 else { return nil }
            return CommitSummary(sha: f[0], shortSha: f[1], author: f[2], date: dates.date(from: f[3]), subject: f[4])
        }
    }

    /// Throws away uncommitted changes to `paths`: tracked files go back to
    /// HEAD, new ones are deleted. Paseo's discard, command for command.
    public static func discard(_ exec: any Executor, worktree: String, paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        let reset = try await Git.git(exec, cwd: worktree, ["--literal-pathspecs", "reset", "-q", "HEAD", "--"] + paths)
        if !reset.ok {
            // No commit yet: unstage by removing from the index instead.
            _ = try await Git.git(exec, cwd: worktree, ["--literal-pathspecs", "rm", "--cached", "-r", "-q", "--ignore-unmatch", "--"] + paths)
        }
        let status = try await Git.gitOK(exec, cwd: worktree, ["--literal-pathspecs", "status", "--porcelain=v1", "-z", "--"] + paths)
        var tracked: [String] = []
        var untracked: [String] = []
        var entries = status.split(separator: "\u{0}", omittingEmptySubsequences: true).map(String.init)[...]
        while let entry = entries.popFirst(), entry.count > 3 {
            let code = entry.prefix(2)
            let path = String(entry.dropFirst(3))
            // A rename's entry is followed by its old path.
            if code.contains("R") || code.contains("C") { _ = entries.popFirst() }
            if code == "??" { untracked.append(path) } else { tracked.append(path) }
        }
        if !tracked.isEmpty { _ = try await Git.gitOK(exec, cwd: worktree, ["--literal-pathspecs", "checkout", "-q", "--"] + tracked) }
        if !untracked.isEmpty { _ = try await Git.gitOK(exec, cwd: worktree, ["--literal-pathspecs", "clean", "-fd", "-q", "--"] + untracked) }
    }
}
