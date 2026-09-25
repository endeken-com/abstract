import Foundation
import Testing
@testable import AbstractCore

@Suite("Submodules")
struct SubmoduleTests {
    let exec = LocalExecutor.shared

    @Test func listsTheWorktreeAndEveryCheckedOutSubmodule() async throws {
        let f = try await SubmoduleFixture.make()
        defer { f.remove() }
        try await f.git(f.worktree + "/libs/core", ["remote", "set-url", "origin", "git@github.com:acme/core.git"])

        let repos = await Submodules.list(exec, worktree: f.worktree)
        #expect(repos.map(\.path) == ["", "libs/core", "libs/core/vendor/deep", "libs/other lib"],
                "libs/unused isn't checked out, so it isn't listed")
        #expect(repos.map(\.depth) == [0, 1, 2, 1])
        #expect(repos.map(\.parentPath) == [nil, "", "libs/core", ""])
        #expect(repos[0].branch == "chat")
        #expect(repos[1].branch == nil, "submodule update leaves HEAD detached")
        #expect(repos[1].github == "acme/core")
        #expect(repos[2].github == nil, "a local path isn't GitHub")
        #expect(repos[1].directory(in: f.worktree) == f.worktree + "/libs/core")
        #expect(repos[0].directory(in: f.worktree) == f.worktree)
    }

    @Test func aRepositoryWithoutSubmodulesIsJustItself() async throws {
        let f = try await SubmoduleFixture.make()
        defer { f.remove() }
        let repos = await Submodules.list(exec, worktree: f.repo("deep"))
        #expect(repos.map(\.path) == [""])
        #expect(repos.first?.branch == "main")
    }

    @Test func registeredPathsIncludeOnesNotCheckedOut() async throws {
        let f = try await SubmoduleFixture.make()
        defer { f.remove() }
        #expect(await Submodules.registered(exec, root: f.worktree) == ["libs/core", "libs/other lib", "libs/unused"])
        #expect(await Submodules.registered(exec, root: f.repo("deep")) == [])
    }

    @Test func aSubmoduleNotCheckedOutIsJustAFolder() async throws {
        let f = try await SubmoduleFixture.make()
        defer { f.remove() }
        #expect(await Submodules.isCheckedOut(exec, directory: f.worktree + "/libs/core"))
        #expect(await !Submodules.isCheckedOut(exec, directory: f.worktree + "/libs/unused"))
        #expect(await !Submodules.isCheckedOut(exec, directory: f.worktree + "/libs/missing"))
    }

    @Test func parsingFindsEachSubmodulesParent() {
        let repos = Submodules.parse("libs/a\tmain\tgit@github.com:x/a.git\nlibs/a/x\t\t\nlibs/ab\t\thttps://github.com/x/ab\n")
        #expect(repos.map(\.path) == ["libs/a", "libs/a/x", "libs/ab"])
        #expect(repos.map(\.parentPath) == ["", "libs/a", ""], "libs/ab is beside libs/a, not inside it")
        #expect(repos.map(\.depth) == [1, 2, 1])
        #expect(repos.map(\.branch) == ["main", nil, nil])
        #expect(repos.map(\.github) == ["x/a", nil, "x/ab"])
    }

    @Test func aRepositorySeesPathsInsideIt() {
        let core = ChatRepo(path: "libs/core", depth: 1, parentPath: "")
        #expect(core.inside("libs/core/vendor/deep") == "vendor/deep")
        #expect(core.inside("libs/corex/file") == nil)
        #expect(core.inside("libs/core") == nil)
        #expect(ChatRepo(path: "").inside("libs/core") == "libs/core")
    }

    @Test func githubSlugs() {
        #expect(GitRemote.githubSlug("git@github.com:acme/core.git") == "acme/core")
        #expect(GitRemote.githubSlug("https://github.com/acme/core") == "acme/core")
        #expect(GitRemote.githubSlug("ssh://git@github.com/acme/core.git") == "acme/core")
        #expect(GitRemote.githubSlug("https://gitlab.com/acme/core.git") == nil)
        #expect(GitRemote.githubSlug("/tmp/core") == nil)
        #expect(GitRemote.githubSlug("") == nil)
    }
}
