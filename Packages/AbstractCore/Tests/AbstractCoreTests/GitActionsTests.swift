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
}
