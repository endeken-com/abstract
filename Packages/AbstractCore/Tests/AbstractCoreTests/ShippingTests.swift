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
}
