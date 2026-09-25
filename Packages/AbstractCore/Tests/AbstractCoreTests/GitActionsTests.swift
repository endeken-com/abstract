import Foundation
import Testing
@testable import AbstractCore

@Suite("Git actions")
struct GitActionsTests {
    let exec = LocalExecutor.shared

    private func git(_ cwd: String, _ args: [String]) async throws {
        let out = try await exec.run("git", args, cwd: cwd)
        try #require(out.ok, "git \(args) failed: \(out.stderr)")
    }

    /// `main` with one commit, and a worktree on `work` beside it.
    private func makeRepo() async throws -> (root: String, worktree: String) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("abstract-actions-\(UUID().uuidString)").path
        let root = base + "/repo", worktree = base + "/wt"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try await git(root, ["init", "-q", "-b", "main"])
        try await git(root, ["config", "user.email", "test@abstract.local"])
        try await git(root, ["config", "user.name", "Abstract Test"])
        try await git(root, ["config", "commit.gpgsign", "false"])
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        try await git(root, ["add", "-A"])
        try await git(root, ["commit", "-qm", "init"])
        try await git(root, ["worktree", "add", "-q", "-b", "work", worktree])
        return (root, worktree)
    }

    @Test func stateCountsWorkAgainstTheBase() async throws {
        let (root, wt) = try await makeRepo()
        defer { try? FileManager.default.removeItem(atPath: (root as NSString).deletingLastPathComponent) }
        try "two\n".write(toFile: wt + "/b.txt", atomically: true, encoding: .utf8)
        var state = await GitActions.state(exec, worktree: wt, preferredBase: "main")
        #expect(state.dirty && state.aheadOfBase == 0 && !state.hasOrigin && state.base == "main")
        try await git(wt, ["add", "-A"])
        try await git(wt, ["commit", "-qm", "Add b"])
        state = await GitActions.state(exec, worktree: wt, preferredBase: "main")
        #expect(!state.dirty && state.aheadOfBase == 1 && state.behindBase == 0)
    }

    @Test func updateFromBaseThenMergeLocally() async throws {
        let (root, wt) = try await makeRepo()
        defer { try? FileManager.default.removeItem(atPath: (root as NSString).deletingLastPathComponent) }
        try "main\n".write(toFile: root + "/m.txt", atomically: true, encoding: .utf8)
        try await git(root, ["add", "-A"])
        try await git(root, ["commit", "-qm", "On main"])
        try "work\n".write(toFile: wt + "/w.txt", atomically: true, encoding: .utf8)
        try await git(wt, ["add", "-A"])
        try await git(wt, ["commit", "-qm", "On work"])

        try await GitActions.updateFromBase(exec, worktree: wt, base: "main")
        #expect(FileManager.default.fileExists(atPath: wt + "/m.txt"))
        try await GitActions.mergeLocally(exec, root: root, branch: "work", base: "main")
        #expect(FileManager.default.fileExists(atPath: root + "/w.txt"))
    }

    @Test func aConflictLeavesTheBranchAsItWas() async throws {
        let (root, wt) = try await makeRepo()
        defer { try? FileManager.default.removeItem(atPath: (root as NSString).deletingLastPathComponent) }
        try "main side\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        try await git(root, ["commit", "-qam", "Main edits a"])
        try "work side\n".write(toFile: wt + "/a.txt", atomically: true, encoding: .utf8)
        try await git(wt, ["commit", "-qam", "Work edits a"])

        await #expect(throws: GitActions.Failure.conflict("Updating from main")) {
            try await GitActions.updateFromBase(exec, worktree: wt, base: "main")
        }
        #expect(try String(contentsOfFile: wt + "/a.txt", encoding: .utf8) == "work side\n")
        #expect(await !Diff.isDirty(exec, worktree: wt))
    }

    // MARK: Suggestion

    private func branch(_ edit: (inout BranchState) -> Void) -> BranchState {
        var state = BranchState()
        state.hasOrigin = true
        state.hasUpstream = true
        state.base = "origin/main"
        edit(&state)
        return state
    }

    @Test func uncommittedWorkComesFirst() {
        let state = branch { $0.dirty = true; $0.behind = 2; $0.ahead = 1 }
        #expect(GitActions.suggestion(state, pullRequest: .open, onGitHub: true) == .commit)
    }

    @Test func aBranchThatMovedBothWaysSyncs() {
        #expect(GitActions.suggestion(branch { $0.behind = 1 }, pullRequest: nil, onGitHub: true) == .pull)
        #expect(GitActions.suggestion(branch { $0.behind = 1; $0.ahead = 2 }, pullRequest: nil, onGitHub: true) == .pullAndPush)
    }

    @Test func aMergedPullRequestSuggestsArchiving() {
        // Squash merges leave the branch's commits unknown to origin.
        let state = branch { $0.hasUpstream = false; $0.ahead = 3; $0.aheadOfBase = 3 }
        #expect(GitActions.suggestion(state, pullRequest: .merged, onGitHub: true) == .archive)
    }

    @Test func anOpenPullRequestTakesNewCommitsThenShowsItself() {
        let ahead = branch { $0.ahead = 1; $0.aheadOfBase = 4 }
        #expect(GitActions.suggestion(ahead, pullRequest: .open, onGitHub: true) == .push)
        let sent = branch { $0.aheadOfBase = 4; $0.behindBase = 2 }
        #expect(GitActions.suggestion(sent, pullRequest: .open, onGitHub: true) == .viewPR)
        #expect(GitActions.suggestion(sent, pullRequest: .conflicting, onGitHub: true) == .updateFromBase)
    }

    @Test func newWorkOnGitHubOpensAPullRequestWhichPushesIt() {
        let unpushed = branch { $0.hasUpstream = false; $0.ahead = 2; $0.aheadOfBase = 2 }
        #expect(GitActions.suggestion(unpushed, pullRequest: nil, onGitHub: true) == .createPR)
        #expect(GitActions.suggestion(unpushed, pullRequest: .closed, onGitHub: true) == .createPR)
    }

    @Test func withoutGitHubWorkIsPushedThenMergedLocally() {
        let unpushed = branch { $0.ahead = 2; $0.aheadOfBase = 2 }
        #expect(GitActions.suggestion(unpushed, pullRequest: nil, onGitHub: false) == .push)
        let behind = branch { $0.aheadOfBase = 2; $0.behindBase = 1 }
        #expect(GitActions.suggestion(behind, pullRequest: nil, onGitHub: false) == .updateFromBase)
        #expect(GitActions.suggestion(branch { $0.aheadOfBase = 2 }, pullRequest: nil, onGitHub: false) == .mergeLocally)
    }

    @Test func aBranchWithNothingOfItsOwnCatchesUpWithItsBase() {
        #expect(GitActions.suggestion(branch { $0.behindBase = 3 }, pullRequest: nil, onGitHub: true) == .updateFromBase)
        #expect(GitActions.suggestion(branch { _ in }, pullRequest: nil, onGitHub: true) == .commit)
    }

    @Test func stateSeesABranchDeletedOnOrigin() async throws {
        let (root, wt) = try await makeRepo()
        defer { try? FileManager.default.removeItem(atPath: (root as NSString).deletingLastPathComponent) }
        let remote = (root as NSString).deletingLastPathComponent + "/origin.git"
        try await git(root, ["init", "-q", "--bare", remote])
        try await git(wt, ["remote", "add", "origin", remote])
        try await git(wt, ["push", "-q", "-u", "origin", "work"])
        var state = await GitActions.state(exec, worktree: wt, preferredBase: "main")
        #expect(state.hasUpstream && !state.upstreamGone)
        try await git(wt, ["push", "-q", "origin", "--delete", "work"])
        state = await GitActions.state(exec, worktree: wt, preferredBase: "main")
        #expect(!state.hasUpstream && state.upstreamGone)
    }
}
