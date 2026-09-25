import Foundation

/// Where a chat's branch stands, for the git actions button.
public struct BranchState: Sendable, Equatable {
    public var dirty = false
    public var hasOrigin = false
    public var hasUpstream = false
    /// The branch tracked one on origin that's since been deleted, as
    /// GitHub does when a pull request is merged.
    public var upstreamGone = false
    /// Commits the upstream (or, with none, `origin`) doesn't have.
    public var ahead = 0
    /// Commits on the upstream this branch doesn't have.
    public var behind = 0
    public var aheadOfBase = 0
    public var behindBase = 0
    /// The ref the branch is compared with, e.g. `origin/main`.
    public var base: String?

    public init() {}

    /// The base's branch name without its remote: `main`.
    public var baseName: String? { base.map { $0.hasPrefix("origin/") ? String($0.dropFirst(7)) : $0 } }
}

/// The git actions behind the Commit button, after Paseo's (Apache-2.0,
/// Copyright (c) 2025-present Mohamed Boudra). Merges, never rebases; a
/// merge that conflicts is aborted and reported, leaving things as they were.
public enum GitActions {
    public enum Failure: Error, LocalizedError, Equatable {
        case dirty
        case conflict(String)
        case baseNotCheckedOut(String)
        public var errorDescription: String? {
            switch self {
            case .dirty: "Commit or discard the uncommitted changes first."
            case .conflict(let what): "\(what) had conflicts, so nothing was changed."
            case .baseNotCheckedOut(let base): "Check out \(base) in the project first."
            }
        }
    }

    public static func state(_ exec: any Executor, worktree: String, preferredBase: String?) async -> BranchState {
        var state = BranchState()
        func out(_ args: [String]) async -> String? {
            guard let r = try? await Git.git(exec, cwd: worktree, args), r.ok else { return nil }
            return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func count(_ args: [String]) async -> Int { Int(await out(args) ?? "") ?? 0 }
        state.dirty = await Diff.isDirty(exec, worktree: worktree)
        state.hasOrigin = await out(["remote", "get-url", "origin"]) != nil
        if await out(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"]) != nil {
            state.hasUpstream = true
            state.ahead = await count(["rev-list", "--count", "@{upstream}..HEAD"])
            state.behind = await count(["rev-list", "--count", "HEAD..@{upstream}"])
        } else if state.hasOrigin {
            state.ahead = await count(["rev-list", "--count", "HEAD", "--not", "--remotes=origin"])
            if let branch = await out(["symbolic-ref", "--short", "HEAD"]) {
                state.upstreamGone = await out(["config", "branch.\(branch).merge"]) != nil
            }
        }
        state.base = await Diff.resolveBase(exec, worktree: worktree, preferred: preferredBase)
        if let base = state.base {
            state.aheadOfBase = await count(["rev-list", "--count", "\(base)..HEAD"])
            state.behindBase = await count(["rev-list", "--count", "HEAD..\(base)"])
        }
        return state
    }

    /// A step the git actions button can take.
    public enum Step: Sendable, Hashable {
        case commit, pull, push, pullAndPush, updateFromBase, mergeLocally, createPR, viewPR, archive
    }

    /// How the branch's pull request stands, as far as the next step goes.
    public enum PullRequestStanding: Sendable, Hashable {
        case open, conflicting, closed, merged

        public init(_ pr: PullRequest) {
            switch pr.state {
            case .open: self = pr.hasConflicts ? .conflicting : .open
            case .closed: self = .closed
            case .merged: self = .merged
            }
        }
    }

    /// The likeliest next step, after Paseo's order: commit what's
    /// uncommitted; take what's new upstream; then see the work through its
    /// pull request, or merge it yourself. `.commit` with nothing to commit
    /// means there's nothing to do.
    public static func suggestion(_ s: BranchState, pullRequest pr: PullRequestStanding?, onGitHub: Bool) -> Step {
        if s.dirty { return .commit }
        if s.behind > 0 { return s.ahead > 0 ? .pullAndPush : .pull }
        let unpushed = s.hasOrigin && s.ahead > 0
        switch pr {
        case .merged?:
            // It landed; commits left over from a squash merge aren't news.
            return .archive
        case .open?, .conflicting?:
            if unpushed { return .push }
            return pr == .conflicting && s.behindBase > 0 ? .updateFromBase : .viewPR
        case .closed?, nil:
            // Opening the pull request pushes the branch too.
            if s.aheadOfBase > 0, onGitHub { return .createPR }
            if unpushed { return .push }
            if s.behindBase > 0 { return .updateFromBase }
            return s.aheadOfBase > 0 ? .mergeLocally : .commit
        }
    }

    public static func pull(_ exec: any Executor, worktree: String) async throws {
        let result = try await Git.git(exec, cwd: worktree, ["pull", "--no-rebase"])
        guard result.ok else {
            _ = try? await Git.git(exec, cwd: worktree, ["merge", "--abort"])
            throw AbstractError.message(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Merges the base into the branch: whichever of `main` and
    /// `origin/main` is further ahead.
    public static func updateFromBase(_ exec: any Executor, worktree: String, base: String) async throws {
        guard !(await Diff.isDirty(exec, worktree: worktree)) else { throw Failure.dirty }
        let ref = await mostAhead(exec, worktree: worktree, base: base)
        try await merge(exec, cwd: worktree, ref: ref, what: "Updating from \(ref)")
    }

    /// Merges the branch into the base in the project's own checkout, which
    /// must have the base checked out and nothing uncommitted.
    public static func mergeLocally(_ exec: any Executor, root: String, branch: String, base: String) async throws {
        let name = base.hasPrefix("origin/") ? String(base.dropFirst(7)) : base
        let current = try await Git.currentBranch(exec, root: root)
        guard current == name else { throw Failure.baseNotCheckedOut(name) }
        guard !(await Diff.isDirty(exec, worktree: root)) else { throw Failure.dirty }
        try await merge(exec, cwd: root, ref: branch, what: "Merging \(branch) into \(name)")
    }

    private static func merge(_ exec: any Executor, cwd: String, ref: String, what: String) async throws {
        let result = try await Git.git(exec, cwd: cwd, ["merge", "--no-edit", ref])
        guard result.ok else {
            _ = try? await Git.git(exec, cwd: cwd, ["merge", "--abort"])
            if (result.stdout + result.stderr).contains("CONFLICT") { throw Failure.conflict(what) }
            throw AbstractError.message(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// `main` or `origin/main`, whichever contains the other.
    static func mostAhead(_ exec: any Executor, worktree: String, base: String) async -> String {
        let name = base.hasPrefix("origin/") ? String(base.dropFirst(7)) : base
        let local = name, remote = "origin/" + name
        func exists(_ ref: String) async -> Bool {
            (try? await Git.git(exec, cwd: worktree, ["rev-parse", "--verify", "--quiet", ref]))?.ok ?? false
        }
        let hasLocal = await exists(local), hasRemote = await exists(remote)
        guard hasLocal, hasRemote else { return hasRemote ? remote : local }
        let localBehind = (try? await Git.git(exec, cwd: worktree, ["merge-base", "--is-ancestor", local, remote]))?.ok ?? false
        return localBehind ? remote : local
    }
}
