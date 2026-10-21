import Foundation
import Testing
@testable import AbstractCore

/// Before a code host opens a pull request, Abstract commits and pushes
/// the branch itself: plain git stays in core (ABS-139).
@Suite("Publishing a branch")
struct PublishTests {
    @Test func publishingCommitsAndPushesTheBranch() async throws {
        let exec = LocalExecutor.shared
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("abstract-gh-\(UUID().uuidString)").path
        let remote = base + "/remote.git", work = base + "/work"
        defer { try? FileManager.default.removeItem(atPath: base) }
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        func git(_ cwd: String, _ args: [String]) async throws {
            let out = try await exec.run("git", args, cwd: cwd)
            try #require(out.ok, "git \(args): \(out.stderr)")
        }
        try await git(base, ["init", "-q", "--bare", remote])
        try await git(work, ["init", "-q", "-b", "feature"])
        for (k, v) in [("user.email", "t@abstract.local"), ("user.name", "T"), ("commit.gpgsign", "false")] {
            try await git(work, ["config", k, v])
        }
        try await git(work, ["remote", "add", "origin", remote])
        try "hi\n".write(toFile: work + "/a.txt", atomically: true, encoding: .utf8)

        var state = await Git.publishState(exec, worktree: work, branch: "feature")
        #expect(state.uncommitted == 1)
        try await Git.commitAll(exec, worktree: work, message: "Add a")
        try await Git.commitAll(exec, worktree: work, message: "Nothing left")
        state = await Git.publishState(exec, worktree: work, branch: "feature")
        #expect(state.uncommitted == 0 && state.unpushed == 1)

        try await Git.push(exec, worktree: work, branch: "feature")
        try await git(work, ["fetch", "-q", "origin"])
        state = await Git.publishState(exec, worktree: work, branch: "feature")
        #expect(state.unpushed == 0)
    }
}
