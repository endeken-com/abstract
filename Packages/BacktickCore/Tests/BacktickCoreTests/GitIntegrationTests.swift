// End-to-end check of the git plumbing against the real `git` binary:
// provision a worktree, change files inside it, collect the diff, accept one
// hunk into the main working tree, and reject a change in the worktree.

import Foundation
import Testing
@testable import BacktickCore

private func git(_ exec: any Executor, _ cwd: String, _ args: [String]) async throws -> String {
    let out = try await exec.run("git", args, cwd: cwd)
    try #require(out.ok, "git \(args) failed: \(out.stderr)")
    return out.stdout
}

private struct TempRepo {
    let root: String

    /// Removes the repo and the sibling `-wt` worktree directory.
    func remove() {
        try? FileManager.default.removeItem(atPath: root)
        try? FileManager.default.removeItem(atPath: root + "-wt")
    }

    func write(_ relative: String, _ content: String) throws {
        try content.write(toFile: root + "/" + relative, atomically: true, encoding: .utf8)
    }
}

private func makeRepo(_ exec: any Executor, _ label: String) async throws -> TempRepo {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("backtick-test-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let repo = TempRepo(root: dir.path)
    _ = try await git(exec, repo.root, ["init", "-q", "-b", "main"])
    _ = try await git(exec, repo.root, ["config", "user.email", "test@backtick.local"])
    _ = try await git(exec, repo.root, ["config", "user.name", "Backtick Test"])
    _ = try await git(exec, repo.root, ["config", "commit.gpgsign", "false"])
    try repo.write("app.txt", (1...20).map { "line \($0)\n" }.joined())
    _ = try await git(exec, repo.root, ["add", "-A"])
    _ = try await git(exec, repo.root, ["commit", "-qm", "init"])
    return repo
}

private func read(_ path: String) throws -> String {
    try String(contentsOfFile: path, encoding: .utf8)
}

@Suite struct GitIntegrationTests {
    let exec = LocalExecutor.shared

    @Test func worktreeDiffAcceptAndReject() async throws {
        let repo = try await makeRepo(exec, "flow")
        defer { repo.remove() }
        let wtPath = repo.root + "-wt"

        // 1. Provision an isolated worktree on its own branch.
        try await Git.addWorktree(exec, root: repo.root, path: wtPath, branch: "backtick/test-session", baseRef: "HEAD")
        #expect(FileManager.default.fileExists(atPath: wtPath + "/app.txt"))
        #expect(try await Git.currentBranch(exec, root: wtPath) == "backtick/test-session")
        #expect(await Git.branchExists(exec, root: repo.root, branch: "backtick/test-session"))
        #expect(await !Git.branchExists(exec, root: repo.root, branch: "backtick/nope"))

        let listed = try await Git.worktrees(exec, root: repo.root)
        #expect(listed.count == 2, "main working tree plus the new worktree")
        #expect(listed.contains { $0.branch == "backtick/test-session" })

        // 2. The agent edits an existing file (two separate hunks) and adds a new one.
        // Two edits far enough apart that git emits two separate hunks.
        let edited = (1...20).map { n in n == 1 ? "FIRST\n" : n == 20 ? "LAST\n" : "line \(n)\n" }.joined()
        try edited.write(toFile: wtPath + "/app.txt", atomically: true, encoding: .utf8)
        try "hi\n".write(toFile: wtPath + "/hi.txt", atomically: true, encoding: .utf8)

        // 3. Collect the diff, untracked files included.
        let files = try await Diff.collect(exec, worktree: wtPath, exclude: [])
        let app = try #require(files.first { $0.path == "app.txt" }, "app.txt changed")
        let hi = try #require(files.first { $0.path == "hi.txt" }, "hi.txt is a new file")
        #expect(hi.status == .added)
        #expect(app.status == .modified)
        try #require(app.hunks.count == 2, "edits at both ends of the file are separate hunks")

        // 4. Accept only the first hunk into the project's main working tree.
        try await Diff.apply(exec, cwd: repo.root, patch: Diff.buildPatch(app, hunks: [0]), reverse: false, threeWay: true)
        let mainApp = try read(repo.root + "/app.txt")
        #expect(mainApp.hasPrefix("FIRST\n"), "accepted hunk landed in the main tree")
        #expect(mainApp.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("line 20"),
                "unaccepted hunk stayed behind")

        // 5. Reject the remaining change inside the worktree.
        try await Diff.apply(exec, cwd: wtPath, patch: Diff.buildPatch(app, hunks: [1]), reverse: true, threeWay: false)
        let wtApp = try read(wtPath + "/app.txt")
        #expect(wtApp.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("line 20"),
                "rejected hunk is gone from the worktree")
        #expect(wtApp.hasPrefix("FIRST\n"), "the other hunk survived the rejection")

        // Original and current contents for the side-by-side view.
        #expect(await Diff.original(exec, worktree: wtPath, path: "app.txt").hasPrefix("line 1\n"))
        #expect(await Diff.original(exec, worktree: wtPath, path: "hi.txt") == "")
        #expect(Diff.current(exec, worktree: wtPath, path: "hi.txt") == "hi\n")
        #expect(Diff.current(exec, worktree: wtPath, path: "missing.txt") == "")

        // 6. Tear the worktree down, branch and all.
        try await Git.removeWorktree(exec, root: repo.root, path: wtPath, deleteBranch: "backtick/test-session")
        #expect(!FileManager.default.fileExists(atPath: wtPath))
        let after = try await Git.worktrees(exec, root: repo.root)
        #expect(after.count == 1, "only the main working tree is left")
        #expect(await !Git.branchExists(exec, root: repo.root, branch: "backtick/test-session"))
    }

    @Test func nestedRepositoriesAreFoundAndExcludedFromTheDiff() async throws {
        let repo = try await makeRepo(exec, "nested")
        defer { repo.remove() }

        // A vendored repository inside the project: a worktree cannot carry it.
        let inner = repo.root + "/vendor/inner"
        try FileManager.default.createDirectory(atPath: inner, withIntermediateDirectories: true)
        _ = try await git(exec, inner, ["init", "-q", "-b", "main"])
        try "vendored\n".write(toFile: inner + "/lib.txt", atomically: true, encoding: .utf8)

        let nested = try await Git.nestedRepos(exec, root: repo.root)
        #expect(nested.contains("vendor/inner"), "nested repo reported relative to the project root, got \(nested)")

        try repo.write("tracked.txt", "changed\n")
        let files = try await Diff.collect(exec, worktree: repo.root, exclude: nested)
        #expect(files.contains { $0.path == "tracked.txt" })
        #expect(!files.contains { $0.path.hasPrefix("vendor/") }, "excluded paths must not appear in the diff")
    }

    @Test func anUnknownNestedRepositoryDoesNotHideTheRestOfTheChanges() async throws {
        // The project was added before someone vendored a repository into it, so
        // Backtick has no record of it. A whole-tree `git add -N` fails outright
        // in that situation; the review must still show everything else.
        let repo = try await makeRepo(exec, "unknown-nested")
        defer { repo.remove() }

        let inner = repo.root + "/vendor/surprise"
        try FileManager.default.createDirectory(atPath: inner, withIntermediateDirectories: true)
        _ = try await git(exec, inner, ["init", "-q", "-b", "main"])
        try "vendored\n".write(toFile: inner + "/lib.txt", atomically: true, encoding: .utf8)

        try repo.write("brand-new.txt", "new file\n")
        try repo.write("configuração.md", "olá\n")
        try repo.write("app.txt", "line 1 changed\n")

        let files = try await Diff.collect(exec, worktree: repo.root, exclude: [])
        #expect(files.contains { $0.path == "brand-new.txt" && $0.status == .added },
                "a new file must survive an unregistered nested repo, got \(files.map(\.path))")
        #expect(files.contains { $0.path == "configuração.md" && $0.status == .added },
                "non-ASCII paths come through unquoted, got \(files.map(\.path))")
        #expect(files.contains { $0.path == "app.txt" })
        #expect(!files.contains { $0.path.hasPrefix("vendor/") })
    }

    @Test func repoRootAndAttachingToAnExistingBranch() async throws {
        let repo = try await makeRepo(exec, "attach")
        defer { repo.remove() }
        let wtPath = repo.root + "-wt"

        let sub = repo.root + "/deep/dir"
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        let root = try await Git.repoRoot(exec, dir: sub)
        #expect(URL(fileURLWithPath: root).resolvingSymlinksInPath().path
                == URL(fileURLWithPath: repo.root).resolvingSymlinksInPath().path)
        await #expect(throws: BacktickError.self) {
            try await Git.repoRoot(self.exec, dir: FileManager.default.temporaryDirectory.path)
        }

        // The branch already exists (a restarted automation): attach instead of failing.
        _ = try await git(exec, repo.root, ["branch", "backtick/again"])
        try await Git.addWorktree(exec, root: repo.root, path: wtPath, branch: "backtick/again", baseRef: "")
        #expect(try await Git.currentBranch(exec, root: wtPath) == "backtick/again")

        // Directory deleted behind git's back: removal still succeeds and prunes.
        try FileManager.default.removeItem(atPath: wtPath)
        try await Git.removeWorktree(exec, root: repo.root, path: wtPath)
        try await Git.prune(exec, root: repo.root)
        #expect(try await Git.worktrees(exec, root: repo.root).count == 1)
    }

    @Test func parsesPorcelainWorktreeList() {
        let output = """
        worktree /repo
        HEAD 1111111111111111111111111111111111111111
        branch refs/heads/main

        worktree /wt/detached
        HEAD 2222222222222222222222222222222222222222
        detached

        worktree /wt/locked
        HEAD 3333333333333333333333333333333333333333
        branch refs/heads/backtick/x
        locked reason here

        worktree /bare
        bare

        """
        let list = Git.parseWorktreeList(output)
        #expect(list.map(\.path) == ["/repo", "/wt/detached", "/wt/locked", "/bare"])
        #expect(list[0].branch == "main" && list[0].head?.hasPrefix("1111") == true)
        #expect(list[1].isDetached && list[1].branch == nil)
        #expect(list[2].isLocked && list[2].branch == "backtick/x")
        #expect(list[3].isBare)
        #expect(list[0].id == "/repo")
    }
}
