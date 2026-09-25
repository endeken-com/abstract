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

    // MARK: Collecting

    @Test func uncommittedChangesInSubmodulesCarryTheirPaths() async throws {
        let f = try await SubmoduleFixture.make()
        defer { f.remove() }
        try f.write(f.worktree + "/top.txt", "top\n")
        try f.write(f.worktree + "/libs/core/a.txt", "core\nchanged\n")
        try f.write(f.worktree + "/libs/core/new.txt", "new\n")
        try f.write(f.worktree + "/libs/other lib/b.txt", "b\n")

        let repos = await Submodules.list(exec, worktree: f.worktree)
        let diffs = try await Diff.collectAll(exec, worktree: f.worktree, repos: repos, compare: .uncommitted)
        #expect(diffs.map(\.repo.path) == ["", "libs/core", "libs/core/vendor/deep", "libs/other lib"])
        #expect(diffs[0].files.map(\.path) == ["top.txt"], "no gitlink entries for the submodules")
        let core = diffs[1].files.sorted { $0.path < $1.path }
        #expect(core.map(\.path) == ["libs/core/a.txt", "libs/core/new.txt"], "new files in a submodule show too")
        #expect(core.map(\.repoPath) == ["a.txt", "new.txt"])
        #expect(core.allSatisfy { $0.repo == "libs/core" })
        #expect(diffs[3].files.map(\.path) == ["libs/other lib/b.txt"])

        let flat = try await Diff.collectUncommitted(exec, worktree: f.worktree)
        #expect(flat.map(\.path).sorted() == ["libs/core/a.txt", "libs/core/new.txt", "libs/other lib/b.txt", "top.txt"])
    }

    @Test func committedMeasuresASubmoduleFromWhatItsParentRecorded() async throws {
        let f = try await SubmoduleFixture.make()
        defer { f.remove() }
        // The submodule's own main moves on after app recorded it…
        try f.write(f.repo("core") + "/upstream.txt", "upstream\n")
        try await f.commitAll(f.repo("core"), "Upstream work")
        let core = f.worktree + "/libs/core"
        try await f.git(core, ["fetch", "-q", "origin"])
        // …and the chat commits its own change in the submodule.
        try f.write(core + "/chat.txt", "chat\n")
        try await f.commitAll(core, "Chat work")

        let repos = await Submodules.list(exec, worktree: f.worktree)
        let baselines = await Submodules.baselines(exec, worktree: f.worktree, repos: repos, base: "main")
        let recorded = try await f.git(f.app, ["rev-parse", "HEAD:libs/core"]).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(baselines["libs/core"] == recorded)
        #expect(baselines["libs/core/vendor/deep"] != nil, "a nested submodule has one too")
        #expect(baselines["libs/unused"] == nil, "not checked out, so not asked")

        let diffs = try await Diff.collectAll(exec, worktree: f.worktree, repos: repos, compare: .committed(base: "main"), baselines: baselines)
        let coreDiff = try #require(diffs.first { $0.repo.path == "libs/core" })
        #expect(coreDiff.files.map(\.path) == ["libs/core/chat.txt"], "upstream.txt is the submodule's main, not the chat's work")
        #expect(coreDiff.ahead == 1)
        #expect(!coreDiff.isNew)
        #expect(diffs.first?.files.isEmpty == true, "the moved pointer isn't shown as a file")
    }

    @Test func aSubmoduleAddedOnTheBranchIsNew() async throws {
        let f = try await SubmoduleFixture.make()
        defer { f.remove() }
        try await f.git(f.worktree, ["submodule", "add", "-q", f.repo("deep"), "libs/fresh"])
        try await f.git(f.worktree, ["commit", "-qm", "Add fresh"])

        let repos = await Submodules.list(exec, worktree: f.worktree)
        let baselines = await Submodules.baselines(exec, worktree: f.worktree, repos: repos, base: "main")
        #expect(baselines["libs/fresh"] == nil)
        let diffs = try await Diff.collectAll(exec, worktree: f.worktree, repos: repos, compare: .committed(base: "main"), baselines: baselines)
        let fresh = try #require(diffs.first { $0.repo.path == "libs/fresh" })
        #expect(fresh.isNew)
        #expect(fresh.files.isEmpty)
    }

    @Test func aCommitIsShownFromItsOwnRepository() async throws {
        let f = try await SubmoduleFixture.make()
        defer { f.remove() }
        let core = f.worktree + "/libs/core"
        try f.write(core + "/chat.txt", "chat\n")
        try await f.commitAll(core, "Chat work")
        try f.write(f.worktree + "/top.txt", "top\n")
        try await f.git(f.worktree, ["add", "top.txt"])
        try await f.git(f.worktree, ["commit", "-qm", "Parent work"])

        let repos = await Submodules.list(exec, worktree: f.worktree)
        let baselines = await Submodules.baselines(exec, worktree: f.worktree, repos: repos, base: "main")
        let commits = await Diff.commitsAll(exec, worktree: f.worktree, repos: repos, base: "main", baselines: baselines)
        #expect(Set(commits.map(\.subject)) == ["Chat work", "Parent work"])
        let chat = try #require(commits.first { $0.subject == "Chat work" })
        #expect(chat.repo == "libs/core")
        #expect(commits.first { $0.subject == "Parent work" }?.repo == "")

        let diffs = try await Diff.collectAll(exec, worktree: f.worktree, repos: repos,
                                              compare: .commit(sha: chat.sha, repo: chat.repo), baselines: baselines)
        #expect(diffs.flatMap(\.files).map(\.path) == ["libs/core/chat.txt"])
    }

    @Test func aSubmoduleFileIsAcceptedAndDiscardedInItsOwnRepository() async throws {
        let f = try await SubmoduleFixture.make()
        defer { f.remove() }
        let core = f.worktree + "/libs/core"
        try f.write(core + "/a.txt", "core\nchanged\n")
        let repos = await Submodules.list(exec, worktree: f.worktree)
        let diffs = try await Diff.collectAll(exec, worktree: f.worktree, repos: repos, compare: .uncommitted)
        let file = try #require(diffs.flatMap(\.files).first { $0.path == "libs/core/a.txt" })

        // The patch stays relative to the submodule, so it applies there as is.
        try await Diff.accept(exec, root: f.app + "/libs/core", patch: Diff.buildPatch(file, hunks: []))
        #expect(try f.read(f.app + "/libs/core/a.txt") == "core\nchanged\n")

        try await Diff.discard(exec, worktree: core, paths: [file.repoPath])
        #expect(try f.read(core + "/a.txt") == "core\n")
    }

    @Test func withoutSubmodulesItIsTheSingleRepositoryCollect() async throws {
        let f = try await SubmoduleFixture.make()
        defer { f.remove() }
        let plain = f.repo("deep")
        try f.write(plain + "/a.txt", "deep\nchanged\n")
        try f.write(plain + "/b.txt", "b\n")
        let repos = await Submodules.list(exec, worktree: plain)
        let all = try await Diff.collectAll(exec, worktree: plain, repos: repos, compare: .uncommitted)
        let single = try await Diff.collect(exec, worktree: plain)
        #expect(all.flatMap(\.files) == single)
        #expect(try await Diff.collectUncommitted(exec, worktree: plain) == single)
    }

    @Test func aSubmoduleThatCantBeReadDoesNotHideTheRest() async throws {
        let f = try await SubmoduleFixture.make()
        defer { f.remove() }
        try f.write(f.worktree + "/top.txt", "top\n")
        let repos = await Submodules.list(exec, worktree: f.worktree) + [ChatRepo(path: "libs/gone", depth: 1, parentPath: "")]
        let diffs = try await Diff.collectAll(exec, worktree: f.worktree, repos: repos, compare: .uncommitted)
        #expect(diffs.first?.files.map(\.path) == ["top.txt"])
        #expect(diffs.last?.repo.path == "libs/gone")
        #expect(diffs.last?.error != nil)
    }
}
