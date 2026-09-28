import Foundation
import Testing
@testable import AbstractCore

@Suite("Shipping")
struct ShippingTests {
    let exec = LocalExecutor.shared

    @Test func submodulesComeBeforeTheirParents() {
        let repos = [ChatRepo(path: ""), ChatRepo(path: "b", depth: 1, parentPath: ""),
                     ChatRepo(path: "a/x", depth: 2, parentPath: "a"), ChatRepo(path: "a", depth: 1, parentPath: "")]
        #expect(Shipping.order(repos).map(\.path) == ["a/x", "a", "b", ""])
    }

    @Test func aSubmoduleIsPutOnTheChatsBranch() async throws {
        let f = try await SubmoduleFixture.make()
        defer { f.remove() }
        let core = f.worktree + "/libs/core"
        // Detached, no such branch: made there, at the same commit.
        let head = GitText.trimmed(try await f.git(core, ["rev-parse", "HEAD"]))
        #expect(await Shipping.ensureBranch(exec, directory: core, name: "chat") == .created)
        #expect(try await Git.currentBranch(exec, root: core) == "chat")
        #expect(GitText.trimmed(try await f.git(core, ["rev-parse", "HEAD"])) == head)
        #expect(await Shipping.ensureBranch(exec, directory: core, name: "chat") == .alreadyOn)
        // Detached at the branch's commit: switched to it.
        try await f.git(core, ["switch", "-q", "--detach"])
        #expect(await Shipping.ensureBranch(exec, directory: core, name: "chat") == .switched)
        // On a branch the agent chose: that's the one it ships.
        try await f.git(core, ["switch", "-q", "-c", "mine"])
        #expect(await Shipping.ensureBranch(exec, directory: core, name: "chat") == .keptOwn("mine"))
        // Detached elsewhere while the name is taken: left detached.
        try await f.git(core, ["switch", "-q", "--detach", "HEAD~1"])
        #expect(await Shipping.ensureBranch(exec, directory: core, name: "chat") == .leftDetached)
        #expect(try await Git.currentBranch(exec, root: core) == nil)
    }

    @Test func aNewWorktreePutsEverySubmoduleOnItsBranch() async throws {
        let f = try await SubmoduleFixture.make()
        defer { f.remove() }
        let path = f.dir + "/wt2"
        try await Git.addWorktree(exec, root: f.app, path: path, branch: "chat2", baseRef: "main")
        // Top level only: cloning the nested local-path submodule needs protocol.file.allow
        // in libs/core's own config, which a test can't give a clone that doesn't exist yet.
        for sub in ["libs/core", "libs/other lib", "libs/unused"] {
            #expect(try await Git.currentBranch(exec, root: path + "/" + sub) == "chat2", "\(sub)")
        }
    }

    // MARK: Committing

    @Test func commitsGoInnermostFirstAndEachParentTakesTheirPointers() async throws {
        let f = try await SubmoduleFixture.make()
        defer { f.remove() }
        let wt = f.worktree
        try f.write(wt + "/libs/core/vendor/deep/d.txt", "d\n")
        try f.write(wt + "/libs/core/c.txt", "c\n")
        try f.write(wt + "/top.txt", "top\n")
        let repos = await Submodules.list(exec, worktree: wt)

        let committed = try await Shipping.commit(exec, worktree: wt, repos: repos, branch: "chat", message: "Ship")
        #expect(committed == ["libs/core/vendor/deep", "libs/core", ""], "libs/other lib had nothing")
        #expect(try await Git.currentBranch(exec, root: wt + "/libs/core") == "chat", "committed on a branch that can be pushed")
        let core = try await f.git(wt + "/libs/core", ["show", "--name-only", "--format=%s", "HEAD"])
        #expect(core.contains("Ship") && core.contains("c.txt") && core.contains("vendor/deep"))
        let parent = try await f.git(wt, ["show", "--name-only", "--format=%s", "HEAD"])
        #expect(parent.contains("Ship") && parent.contains("libs/core") && parent.contains("top.txt"))
        #expect(await !Diff.isDirty(exec, worktree: wt))
        #expect(try await Shipping.commit(exec, worktree: wt, repos: repos, branch: "chat", message: "Again") == [])
    }

    @Test func aReadOnlySubmoduleIsNeitherCommittedNorMoved() async throws {
        let f = try await SubmoduleFixture.make()
        defer { f.remove() }
        let wt = f.worktree, other = wt + "/libs/other lib"
        // The agent committed in it anyway, and left more.
        try f.write(other + "/o.txt", "o\n")
        try await f.commitAll(other, "Agent's own")
        try f.write(other + "/p.txt", "p\n")
        try f.write(wt + "/top.txt", "top\n")
        let repos = await Submodules.list(exec, worktree: wt)

        let committed = try await Shipping.commit(exec, worktree: wt, repos: repos, branch: "chat",
                                                  readOnly: ["libs/other lib"], message: "Ship")
        #expect(committed == [""])
        #expect(try await f.git(other, ["status", "--porcelain"]).contains("p.txt"), "its work stays uncommitted")
        let parent = try await f.git(wt, ["show", "--name-only", "--format=", "HEAD"])
        #expect(parent.contains("top.txt"))
        #expect(!parent.contains("libs/other lib"), "its pointer stays where app had it")
    }

    // MARK: Pushing

    @Test func aSubmodulesCommitsArePushedOntoTheChatsBranch() async throws {
        let f = try await SubmoduleFixture.make()
        defer { f.remove() }
        let wt = f.worktree, core = wt + "/libs/core"
        // Committed on a detached HEAD, as a chat made before branches were given did.
        try f.write(core + "/c.txt", "c\n")
        try await f.commitAll(core, "Chat work")
        let repos = await Submodules.list(exec, worktree: wt)
        #expect(await Shipping.unpushedWork(exec, worktree: wt, repos: repos).map { "\($0.repo.path) \($0.commits)" } == ["libs/core 1"],
                "only in this worktree's clone of libs/core")

        let pushed = try await Shipping.pushSubmodules(exec, worktree: wt, repos: repos, branch: "chat")
        #expect(pushed == ["libs/core"], "the others have nothing no remote has")
        let there = GitText.trimmed(try await f.git(f.repo("core"), ["rev-parse", "chat"]))
        #expect(there == GitText.trimmed(try await f.git(core, ["rev-parse", "HEAD"])))
        #expect(try await Git.currentBranch(exec, root: core) == "chat")
        #expect(await Shipping.unpushedWork(exec, worktree: wt, repos: repos).isEmpty)
        #expect(try await Shipping.pushSubmodules(exec, worktree: wt, repos: repos, branch: "chat") == [])
    }

    @Test func aFailedPushNamesTheSubmoduleAndGoesNoFurther() async throws {
        let f = try await SubmoduleFixture.make()
        defer { f.remove() }
        let wt = f.worktree
        for sub in ["libs/core", "libs/other lib"] {
            try f.write(wt + "/" + sub + "/c.txt", "c\n")
            try await f.commitAll(wt + "/" + sub, "Chat work")
        }
        try await f.git(wt + "/libs/core", ["remote", "set-url", "origin", f.dir + "/missing"])
        let repos = await Submodules.list(exec, worktree: wt)
        do {
            try await Shipping.pushSubmodules(exec, worktree: wt, repos: repos, branch: "chat")
            Issue.record("the push should have failed")
        } catch {
            #expect(error.localizedDescription.contains("libs/core"))
        }
        let later = try await exec.run("git", ["rev-parse", "--verify", "-q", "chat"], cwd: f.repo("other"))
        #expect(!later.ok, "nothing after it was pushed")
    }

    @Test func aDetachedSubmoduleWhoseBranchIsElsewhereIsntPushed() async throws {
        let f = try await SubmoduleFixture.make()
        defer { f.remove() }
        let wt = f.worktree, core = wt + "/libs/core"
        // A branch "chat" at the current commit, then move HEAD past it while detached.
        try await f.git(core, ["branch", "chat"])
        try f.write(core + "/c.txt", "c\n")
        try await f.commitAll(core, "Chat work")
        let repos = await Submodules.list(exec, worktree: wt)
        do {
            try await Shipping.pushSubmodules(exec, worktree: wt, repos: repos, branch: "chat")
            Issue.record("the push should have failed")
        } catch {
            #expect(error.localizedDescription.contains("libs/core"))
        }
        let out = try await exec.run("git", ["rev-parse", "--verify", "-q", "chat"], cwd: f.repo("core"))
        #expect(!out.ok, "the remote never got the branch")
    }

    @Test func aReadOnlySubmoduleIsntPushed() async throws {
        let f = try await SubmoduleFixture.make()
        defer { f.remove() }
        let other = f.worktree + "/libs/other lib"
        try f.write(other + "/o.txt", "o\n")
        try await f.commitAll(other, "Agent's own")
        let repos = await Submodules.list(exec, worktree: f.worktree)
        #expect(try await Shipping.pushSubmodules(exec, worktree: f.worktree, repos: repos, branch: "chat", readOnly: ["libs/other lib"]) == [])
        #expect(await Shipping.unpushedWork(exec, worktree: f.worktree, repos: repos).map(\.repo.path) == ["libs/other lib"],
                "still only in the worktree, so deleting it would lose it")
    }

    @Test func withoutSubmodulesThereIsNothingToPushFirst() async throws {
        let f = try await SubmoduleFixture.make()
        defer { f.remove() }
        let plain = f.repo("deep")
        let repos = await Submodules.list(exec, worktree: plain)
        #expect(try await Shipping.pushSubmodules(exec, worktree: plain, repos: repos, branch: "chat") == [])
        #expect(await Shipping.unpushedWork(exec, worktree: plain, repos: repos).isEmpty, "a repository's own branch is kept on delete")
    }

    // MARK: The guard

    /// libs/core gets a commit of its own and app's branch records it, unpushed.
    private func moveCore(_ f: SubmoduleFixture) async throws {
        let core = f.worktree + "/libs/core"
        try f.write(core + "/c.txt", "c\n")
        try await f.commitAll(core, "Chat work")
        try await f.git(f.worktree, ["add", "libs/core"])
        try await f.git(f.worktree, ["commit", "-qm", "Move core"])
    }

    @Test func aPointerToAnUnpushedCommitHoldsTheParentBack() async throws {
        let f = try await SubmoduleFixture.make()
        defer { f.remove() }
        try await f.addOrigin()
        try await moveCore(f)
        let repos = await Submodules.list(exec, worktree: f.worktree)

        let blocked = await Shipping.unpublishedPointers(exec, worktree: f.worktree, repos: repos)
        #expect(blocked.map(\.repo.path) == ["libs/core"])
        #expect(blocked.first?.reason == .notOnOrigin)
        #expect(blocked.first?.sha == GitText.trimmed(try await f.git(f.worktree + "/libs/core", ["rev-parse", "HEAD"])))

        try await Shipping.pushSubmodules(exec, worktree: f.worktree, repos: repos, branch: "chat")
        #expect(await Shipping.unpublishedPointers(exec, worktree: f.worktree, repos: repos).isEmpty, "pushed: the parent can go")
    }

    @Test func onlyPointersTheBranchMovesAreChecked() async throws {
        let f = try await SubmoduleFixture.make()
        defer { f.remove() }
        try await f.addOrigin()
        // Its origin can't be reached, but the branch never moved its pointer.
        try await f.git(f.worktree + "/libs/other lib", ["remote", "set-url", "origin", f.dir + "/missing"])
        try f.write(f.worktree + "/top.txt", "top\n")
        try await f.git(f.worktree, ["add", "top.txt"])
        try await f.git(f.worktree, ["commit", "-qm", "Top"])
        let repos = await Submodules.list(exec, worktree: f.worktree)
        #expect(await Shipping.unpublishedPointers(exec, worktree: f.worktree, repos: repos).isEmpty)
    }

    @Test func anOriginThatCantBeAskedBlocks() async throws {
        let f = try await SubmoduleFixture.make()
        defer { f.remove() }
        try await f.addOrigin()
        try await moveCore(f)
        try await f.git(f.worktree + "/libs/core", ["remote", "set-url", "origin", f.dir + "/missing"])
        let repos = await Submodules.list(exec, worktree: f.worktree)
        let blocked = await Shipping.unpublishedPointers(exec, worktree: f.worktree, repos: repos)
        #expect(blocked.map(\.repo.path) == ["libs/core"])
        guard case .unreachable = blocked.first?.reason else {
            Issue.record("expected unreachable, got \(String(describing: blocked.first?.reason))")
            return
        }
    }

    @Test func aSubmoduleNotCheckedOutIsntAsked() async throws {
        let f = try await SubmoduleFixture.make()
        defer { f.remove() }
        try await f.addOrigin()
        // The branch moves libs/unused's pointer without it being checked out.
        try f.write(f.repo("unused") + "/n.txt", "n\n")
        try await f.commitAll(f.repo("unused"), "New")
        let sha = GitText.trimmed(try await f.git(f.repo("unused"), ["rev-parse", "HEAD"]))
        try await f.git(f.worktree, ["update-index", "--cacheinfo", "160000,\(sha),libs/unused"])
        try await f.git(f.worktree, ["commit", "-qm", "Move unused"])
        let repos = await Submodules.list(exec, worktree: f.worktree)
        #expect(await Shipping.unpublishedPointers(exec, worktree: f.worktree, repos: repos).isEmpty,
                "not checked out here, so it can't hold commits of its own")
    }

    @Test func withoutSubmodulesNothingIsAsked() async throws {
        let f = try await SubmoduleFixture.make()
        defer { f.remove() }
        let plain = f.repo("deep")
        let repos = await Submodules.list(exec, worktree: plain)
        let recording = RecordingExecutor()
        #expect(await Shipping.unpublishedPointers(recording, worktree: plain, repos: repos).isEmpty)
        #expect(!recording.calls(in: plain).contains { $0.first == "fetch" }, "no network for a project without submodules")
    }
}
