import Foundation
import Testing
@testable import AbstractCore

@Suite("Accepting changes into the main tree", .serialized)
struct DiffAcceptTests {
    private let exec = LocalExecutor.shared

    private func git(_ cwd: String, _ args: String...) async throws -> ExecResult {
        try await exec.run("git", args, cwd: cwd)
    }

    private func makeRepoWithWorktree() async throws -> (root: String, worktree: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("accept-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        _ = try await git(root, "init", "-q", "-b", "main")
        _ = try await git(root, "config", "user.email", "t@t")
        _ = try await git(root, "config", "user.name", "t")
        let body = (1...30).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try body.write(toFile: root + "/app.txt", atomically: true, encoding: .utf8)
        _ = try await git(root, "add", "-A")
        _ = try await git(root, "commit", "-qm", "init")
        let wt = root + "-wt"
        try await Git.addWorktree(exec, root: root, path: wt, branch: "abstract/t", baseRef: "HEAD")
        return (root, wt)
    }

    @Test func acceptedChangeLandsUnstaged() async throws {
        let (root, wt) = try await makeRepoWithWorktree()
        defer { try? FileManager.default.removeItem(atPath: root); try? FileManager.default.removeItem(atPath: wt) }
        var lines = try String(contentsOfFile: wt + "/app.txt", encoding: .utf8).components(separatedBy: "\n")
        lines[0] = "FIRST"
        try lines.joined(separator: "\n").write(toFile: wt + "/app.txt", atomically: true, encoding: .utf8)

        let file = try #require(try await Diff.collect(exec, worktree: wt, exclude: []).first)
        let outcome = try await Diff.accept(exec, root: root, patch: Diff.buildPatch(file, hunks: []))
        #expect(outcome == .applied)
        #expect(try await git(root, "diff", "--cached", "--name-only").stdout.isEmpty, "nothing is staged")
        #expect(try String(contentsOfFile: root + "/app.txt", encoding: .utf8).hasPrefix("FIRST\n"))
    }

    @Test func acceptWorksAlongsideTheDevelopersOwnUncommittedEdits() async throws {
        let (root, wt) = try await makeRepoWithWorktree()
        defer { try? FileManager.default.removeItem(atPath: root); try? FileManager.default.removeItem(atPath: wt) }
        // The developer edits the bottom of the file in the main tree…
        var mine = try String(contentsOfFile: root + "/app.txt", encoding: .utf8).components(separatedBy: "\n")
        mine[29] = "MINE"
        try mine.joined(separator: "\n").write(toFile: root + "/app.txt", atomically: true, encoding: .utf8)
        // …while the agent edits the top in its worktree.
        var theirs = try String(contentsOfFile: wt + "/app.txt", encoding: .utf8).components(separatedBy: "\n")
        theirs[0] = "AGENT"
        try theirs.joined(separator: "\n").write(toFile: wt + "/app.txt", atomically: true, encoding: .utf8)

        let file = try #require(try await Diff.collect(exec, worktree: wt, exclude: []).first)
        let outcome = try await Diff.accept(exec, root: root, patch: Diff.buildPatch(file, hunks: []))
        #expect(outcome == .applied)
        let result = try String(contentsOfFile: root + "/app.txt", encoding: .utf8)
        #expect(result.hasPrefix("AGENT\n"), "the agent's change landed")
        #expect(result.contains("MINE"), "the developer's edit survived")
    }
}
