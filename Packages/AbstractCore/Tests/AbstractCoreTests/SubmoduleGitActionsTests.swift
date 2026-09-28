import Foundation
import Testing
@testable import AbstractCore

// One at a time: each test builds a project with submodules from dozens of
// git processes, and running them all at once starves the timing-sensitive
// process tests on a small CI machine.
@Suite("Submodule git actions", .serialized)
struct SubmoduleGitActionsTests {
    let exec = LocalExecutor.shared

    @Test func aSubmoduleAndWhatItHoldsSeenFromItself() {
        let repos = [ChatRepo(path: ""),
                     ChatRepo(path: "libs/core", depth: 1, parentPath: "", branch: "chat", github: "acme/core"),
                     ChatRepo(path: "libs/core/vendor/deep", depth: 2, parentPath: "libs/core"),
                     ChatRepo(path: "libs/other", depth: 1, parentPath: "")]
        let seen = Submodules.subtree(repos, at: repos[1])
        #expect(seen.map(\.path) == ["", "vendor/deep"], "libs/other is beside it, not inside")
        #expect(seen.map(\.depth) == [0, 1])
        #expect(seen.map(\.parentPath) == [nil, ""])
        #expect(seen[0].branch == "chat")
        #expect(seen[0].github == "acme/core")
        #expect(Submodules.subtree(repos, at: repos[0]) == repos, "the worktree's own is already the root")
    }

    @Test func aSubmoduleIsUpdatedFromItsOwnDefaultBranch() async throws {
        let f = try await SubmoduleFixture.make()
        defer { f.remove() }
        let core = f.worktree + "/libs/core"
        try await f.git(core, ["switch", "-q", "-c", "chat"])
        try f.write(core + "/chat.txt", "chat\n")
        try await f.commitAll(core, "Chat work")
        // Its main moves on after the chat started.
        try f.write(f.repo("core") + "/upstream.txt", "upstream\n")
        try await f.commitAll(f.repo("core"), "Upstream work")
        try await f.git(core, ["fetch", "-q", "origin"])

        let before = await GitActions.state(exec, worktree: core, preferredBase: nil)
        #expect(before.base == "origin/main", "its own remote's default branch, not the parent's")
        #expect(before.behindBase == 1)
        #expect(before.aheadOfBase == 1)
        try await GitActions.updateFromBase(exec, worktree: core, base: try #require(before.base))
        #expect(FileManager.default.fileExists(atPath: core + "/upstream.txt"))
        #expect(await GitActions.state(exec, worktree: core, preferredBase: nil).behindBase == 0)
        #expect(try await Git.currentBranch(exec, root: core) == "chat")
        // The parent now has a moved pointer to commit, and nothing committed it.
        #expect(try await f.git(f.worktree, ["status", "--porcelain"]).contains("libs/core"))
    }

    @Test func aSubmoduleIsPulledFromItsOwnUpstream() async throws {
        let f = try await SubmoduleFixture.make()
        defer { f.remove() }
        let core = f.worktree + "/libs/core"
        try await f.git(core, ["switch", "-q", "-c", "chat"])
        try f.write(core + "/c.txt", "c\n")
        try await f.commitAll(core, "Chat work")
        try await Git.push(exec, worktree: core, branch: "chat")
        // Someone else adds to the branch on its origin.
        let other = f.dir + "/core-elsewhere"
        try await f.git(f.dir, ["clone", "-q", "-b", "chat", f.repo("core"), other])
        try await f.identify(other)
        try f.write(other + "/theirs.txt", "theirs\n")
        try await f.commitAll(other, "Their work")
        try await f.git(other, ["push", "-q", "origin", "chat"])
        try await f.git(core, ["fetch", "-q", "origin"])

        let state = await GitActions.state(exec, worktree: core, preferredBase: nil)
        #expect(state.hasUpstream)
        #expect(state.behind == 1)
        try await GitActions.pull(exec, worktree: core)
        #expect(FileManager.default.fileExists(atPath: core + "/theirs.txt"))
    }

    @Test func committingAndPushingASubmoduleLeavesItsParentAlone() async throws {
        let f = try await SubmoduleFixture.make()
        defer { f.remove() }
        let core = f.worktree + "/libs/core"
        try f.write(core + "/vendor/deep/d.txt", "d\n")
        try f.write(core + "/c.txt", "c\n")
        try f.write(f.worktree + "/top.txt", "top\n")
        let parentHead = GitText.trimmed(try await f.git(f.worktree, ["rev-parse", "HEAD"]))
        let repos = await Submodules.list(exec, worktree: f.worktree)
        let root = try #require(repos.first { $0.path == "libs/core" })
        let seen = Submodules.subtree(repos, at: root)

        // Detached, as submodule update leaves it: put on the chat's branch first.
        #expect(await Shipping.ensureBranch(exec, directory: core, name: "chat") == .created)
        let committed = try await Shipping.commit(exec, worktree: core, repos: seen, branch: "chat", message: "Core work")
        #expect(committed == ["vendor/deep", ""], "its own submodule first, then it; not the parent")
        try await Shipping.pushSubmodules(exec, worktree: core, repos: seen, branch: "chat")
        #expect(await Shipping.unpublishedPointers(exec, worktree: core, repos: seen).isEmpty)
        try await Git.push(exec, worktree: core, branch: "chat")

        let pushed = GitText.trimmed(try await f.git(f.repo("core"), ["rev-parse", "chat"]))
        #expect(pushed == GitText.trimmed(try await f.git(core, ["rev-parse", "HEAD"])))
        #expect(GitText.trimmed(try await f.git(f.worktree, ["rev-parse", "HEAD"])) == parentHead, "the parent isn't committed")
        let status = try await f.git(f.worktree, ["status", "--porcelain"])
        #expect(status.contains("top.txt") && status.contains("libs/core"), "its own work and the moved pointer wait for it")
    }
}
