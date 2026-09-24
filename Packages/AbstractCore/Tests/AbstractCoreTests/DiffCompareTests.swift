import Foundation
import Testing
@testable import AbstractCore

@Suite("Review comparisons")
struct DiffCompareTests {
    let exec = LocalExecutor.shared

    private func git(_ cwd: String, _ args: [String]) async throws -> String {
        let out = try await exec.run("git", args, cwd: cwd)
        try #require(out.ok, "git \(args) failed: \(out.stderr)")
        return out.stdout
    }

    /// A repo on `main` with one commit, then a branch `work` with one more.
    private func makeRepo() async throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("abstract-compare-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        _ = try await git(dir, ["init", "-q", "-b", "main"])
        _ = try await git(dir, ["config", "user.email", "test@abstract.local"])
        _ = try await git(dir, ["config", "user.name", "Abstract Test"])
        _ = try await git(dir, ["config", "commit.gpgsign", "false"])
        try "one\ntwo\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        _ = try await git(dir, ["add", "-A"])
        _ = try await git(dir, ["commit", "-qm", "init"])
        _ = try await git(dir, ["checkout", "-q", "-b", "work"])
        try "one\ntwo\nthree\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        _ = try await git(dir, ["commit", "-qam", "Add three"])
        return dir
    }

    @Test func committedShowsTheBranchsCommitsNotTheWorkingTree() async throws {
        let dir = try await makeRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try "new\n".write(toFile: dir + "/b.txt", atomically: true, encoding: .utf8)

        let committed = try await Diff.collect(exec, worktree: dir, compare: .committed(base: "main"))
        #expect(committed.map(\.path) == ["a.txt"])
        #expect(committed.first?.additions == 1)

        let uncommitted = try await Diff.collect(exec, worktree: dir, compare: .uncommitted)
        #expect(uncommitted.map(\.path) == ["b.txt"])
        #expect(await Diff.isDirty(exec, worktree: dir))
    }

    @Test func aCommitAndTheBranchsCommitList() async throws {
        let dir = try await makeRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let commits = await Diff.commits(exec, worktree: dir, base: "main")
        #expect(commits.map(\.subject) == ["Add three"])
        let files = try await Diff.collect(exec, worktree: dir, compare: .commit(sha: try #require(commits.first).sha))
        #expect(files.map(\.path) == ["a.txt"])
        #expect(await Diff.resolveBase(exec, worktree: dir, preferred: nil) == "main")
        #expect(await Diff.resolveBase(exec, worktree: dir, preferred: "work") == "work")
    }

    @Test func discardRestoresTrackedFilesAndDeletesNewOnes() async throws {
        let dir = try await makeRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try "changed\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        try "new\n".write(toFile: dir + "/b.txt", atomically: true, encoding: .utf8)
        // The review marks new files with intent to add; discard has to cope.
        _ = try await Diff.collect(exec, worktree: dir, compare: .uncommitted)

        try await Diff.discard(exec, worktree: dir, paths: ["a.txt", "b.txt"])
        #expect(try String(contentsOfFile: dir + "/a.txt", encoding: .utf8) == "one\ntwo\nthree\n")
        #expect(!FileManager.default.fileExists(atPath: dir + "/b.txt"))
        #expect(await !Diff.isDirty(exec, worktree: dir))
    }
}
