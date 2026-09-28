import Foundation
import Testing
@testable import AbstractCore

// One at a time: each test builds a project with submodules from dozens of
// git processes, and running them all at once starves the timing-sensitive
// process tests on a small CI machine.
@Suite("Submodules", .serialized)
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

    // MARK: One repository at a time

    private func repo(_ repos: [ChatRepo], _ path: String) throws -> ChatRepo {
        try #require(repos.first { $0.path == path })
    }

    @Test func eachRepositoryListsOnlyItsOwnUncommittedFiles() async throws {
        let f = try await SubmoduleFixture.make()
        defer { f.remove() }
        try f.write(f.worktree + "/top.txt", "top\n")
        try f.write(f.worktree + "/libs/core/a.txt", "core\nchanged\n")
        try f.write(f.worktree + "/libs/core/new.txt", "new\n")
        try f.write(f.worktree + "/libs/other lib/b.txt", "b\n")
        let repos = await Submodules.list(exec, worktree: f.worktree)

        let top = try await RepoReview.changes(exec, worktree: f.worktree, repo: repo(repos, ""), repos: repos, compare: .uncommitted)
        #expect(top.files.map(\.path) == ["top.txt"], "the submodules' files are theirs")
        #expect(top.pointers.isEmpty, "work inside a submodule doesn't move its pointer")

        let core = try await RepoReview.changes(exec, worktree: f.worktree, repo: repo(repos, "libs/core"), repos: repos, compare: .uncommitted)
        let files = core.files.sorted { $0.path < $1.path }
        #expect(files.map(\.path) == ["libs/core/a.txt", "libs/core/new.txt"], "new files in a submodule show too")
        #expect(files.map(\.repoPath) == ["a.txt", "new.txt"])
        #expect(files.allSatisfy { $0.repo == "libs/core" })

        let flat = try await Diff.collectUncommitted(exec, worktree: f.worktree)
        #expect(flat.map(\.path).sorted() == ["libs/core/a.txt", "libs/core/new.txt", "libs/other lib/b.txt", "top.txt"],
                "the chat's summary counts every repository's")
    }

    @Test func aSubmodulesCommittedChangesAreMeasuredFromItsOwnBase() async throws {
        let f = try await SubmoduleFixture.make()
        defer { f.remove() }
        // The submodule's main moves on after the chat's branch started…
        try f.write(f.repo("core") + "/upstream.txt", "upstream\n")
        try await f.commitAll(f.repo("core"), "Upstream work")
        let dir = f.worktree + "/libs/core"
        try await f.git(dir, ["fetch", "-q", "origin"])
        // …and the chat commits its own change there.
        try f.write(dir + "/chat.txt", "chat\n")
        try await f.commitAll(dir, "Chat work")
        let repos = await Submodules.list(exec, worktree: f.worktree)
        let core = try repo(repos, "libs/core")

        let state = await RepoReview.state(exec, worktree: f.worktree, repo: core, preferredBase: nil)
        #expect(state.base == "origin/main", "its own remote's default branch")
        #expect(state.commits.map(\.subject) == ["Chat work"])
        #expect(state.commits.allSatisfy { $0.repo == "libs/core" }, "so picking one shows it from its own repository")
        let committed = try await RepoReview.changes(exec, worktree: f.worktree, repo: core, repos: repos,
                                                     compare: .committed(base: try #require(state.base)))
        #expect(committed.files.map(\.path) == ["libs/core/chat.txt"], "upstream.txt is its main's work, not the chat's")

        let one = try await RepoReview.changes(exec, worktree: f.worktree, repo: core, repos: repos,
                                               compare: .commit(sha: try #require(state.commits.first).sha, repo: core.path))
        #expect(one.files.map(\.path) == ["libs/core/chat.txt"])
    }

    @Test func aSubmoduleFileIsAcceptedAndDiscardedInItsOwnRepository() async throws {
        let f = try await SubmoduleFixture.make()
        defer { f.remove() }
        let dir = f.worktree + "/libs/core"
        try f.write(dir + "/a.txt", "core\nchanged\n")
        let repos = await Submodules.list(exec, worktree: f.worktree)
        let changes = try await RepoReview.changes(exec, worktree: f.worktree, repo: repo(repos, "libs/core"), repos: repos, compare: .uncommitted)
        let file = try #require(changes.files.first { $0.path == "libs/core/a.txt" })

        // The patch stays relative to the submodule, so it applies there as is.
        try await Diff.accept(exec, root: f.app + "/libs/core", patch: Diff.buildPatch(file, hunks: []))
        #expect(try f.read(f.app + "/libs/core/a.txt") == "core\nchanged\n")

        try await Diff.discard(exec, worktree: dir, paths: [file.repoPath])
        #expect(try f.read(dir + "/a.txt") == "core\n")
    }

    @Test func withoutSubmodulesItIsTheSingleRepositoryReview() async throws {
        let f = try await SubmoduleFixture.make()
        defer { f.remove() }
        let plain = f.repo("deep")
        try f.write(plain + "/a.txt", "deep\nchanged\n")
        try f.write(plain + "/b.txt", "b\n")
        let repos = await Submodules.list(exec, worktree: plain)
        let changes = try await RepoReview.changes(exec, worktree: plain, repo: repo(repos, ""), repos: repos, compare: .uncommitted)
        let single = try await Diff.collect(exec, worktree: plain)
        #expect(changes.files == single)
        #expect(changes.pointers.isEmpty)
        #expect(try await Diff.collectUncommitted(exec, worktree: plain) == single)
    }

    @Test func aSubmoduleThatCantBeReadDoesNotHideTheRest() async throws {
        let f = try await SubmoduleFixture.make()
        defer { f.remove() }
        try f.write(f.worktree + "/top.txt", "top\n")
        let repos = await Submodules.list(exec, worktree: f.worktree)
        // Gone between listing and reading: the worktree's status still names it.
        try FileManager.default.removeItem(atPath: f.worktree + "/libs/other lib")
        let files = try await Diff.collectUncommitted(exec, worktree: f.worktree, repos: repos, exclude: [])
        #expect(files.map(\.path) == ["top.txt"])
    }

    // MARK: Pointers

    @Test func aSubmoduleCommitIsItsParentsPointerChange() async throws {
        let f = try await SubmoduleFixture.make()
        defer { f.remove() }
        let dir = f.worktree + "/libs/core"
        try f.write(dir + "/chat.txt", "chat\n")
        try await f.commitAll(dir, "Chat work")
        let repos = await Submodules.list(exec, worktree: f.worktree)
        let top = try repo(repos, ""), core = try repo(repos, "libs/core")

        let before = try await RepoReview.changes(exec, worktree: f.worktree, repo: top, repos: repos, compare: .uncommitted)
        #expect(before.files.isEmpty, "the parent's only change is the pointer")
        #expect(before.pointers.map(\.repo.path) == ["libs/core"])
        let pointer = try #require(before.pointers.first)
        #expect(pointer.ahead == 1 && pointer.behind == 0 && !pointer.isCommitted)
        #expect(pointer.to == GitText.trimmed(try await f.git(dir, ["rev-parse", "HEAD"])))
        #expect(await RepoReview.state(exec, worktree: f.worktree, repo: top, preferredBase: "main").dirty, "a moved pointer is uncommitted work")
        #expect(try await RepoReview.changes(exec, worktree: f.worktree, repo: core, repos: repos, compare: .uncommitted).files.isEmpty,
                "chat.txt is committed in libs/core")

        // Work on top inside the submodule doesn't move the pointer further.
        try f.write(dir + "/wip.txt", "wip\n")
        #expect(try await RepoReview.changes(exec, worktree: f.worktree, repo: top, repos: repos, compare: .uncommitted).pointers.map(\.ahead) == [1])

        // Once app commits it, the pointer is the branch's committed change.
        try await f.git(f.worktree, ["add", "libs/core"])
        try await f.git(f.worktree, ["commit", "-qm", "Move core"])
        #expect(try await RepoReview.changes(exec, worktree: f.worktree, repo: top, repos: repos, compare: .uncommitted).pointers.isEmpty)
        let committed = try await RepoReview.changes(exec, worktree: f.worktree, repo: top, repos: repos, compare: .committed(base: "main"))
        #expect(committed.files.isEmpty, "a pointer isn't a file, and applying one would write a gitlink")
        #expect(committed.pointers.map(\.repo.path) == ["libs/core"])
        #expect(committed.pointers.first?.isCommitted == true)
        #expect(committed.pointers.first?.ahead == 1)
        let move = GitText.trimmed(try await f.git(f.worktree, ["rev-parse", "HEAD"]))
        let one = try await RepoReview.changes(exec, worktree: f.worktree, repo: top, repos: repos, compare: .commit(sha: move))
        #expect(one.files.isEmpty)
        #expect(one.pointers.map(\.ahead) == [1])

        // A nested submodule's pointer is its own parent's.
        try f.write(dir + "/vendor/deep/chat.txt", "chat\n")
        try await f.commitAll(dir + "/vendor/deep", "Deep work")
        #expect(try await RepoReview.changes(exec, worktree: f.worktree, repo: core, repos: repos, compare: .uncommitted)
            .pointers.map(\.repo.path) == ["libs/core/vendor/deep"])
        #expect(try await RepoReview.changes(exec, worktree: f.worktree, repo: top, repos: repos, compare: .uncommitted).pointers.isEmpty,
                "libs/core's own pointer hasn't moved")
    }

    @Test func aPointerMovedBackIsBehind() async throws {
        let f = try await SubmoduleFixture.make()
        defer { f.remove() }
        // app records libs/core at "Add deep"; the chat goes back to the commit before it.
        try await f.git(f.worktree + "/libs/core", ["checkout", "-q", "HEAD~1"])
        let repos = await Submodules.list(exec, worktree: f.worktree)
        let pointers = try await RepoReview.changes(exec, worktree: f.worktree, repo: repo(repos, ""), repos: repos, compare: .uncommitted).pointers
        #expect(pointers.map(\.repo.path) == ["libs/core"])
        #expect(pointers.first?.ahead == 0)
        #expect(pointers.first?.behind == 1)
    }

    @Test func aSubmoduleAddedOnTheBranchIsANewPointer() async throws {
        let f = try await SubmoduleFixture.make()
        defer { f.remove() }
        try await f.git(f.worktree, ["submodule", "add", "-q", f.repo("deep"), "libs/fresh"])
        try await f.git(f.worktree, ["commit", "-qm", "Add fresh"])
        let repos = await Submodules.list(exec, worktree: f.worktree)
        let committed = try await RepoReview.changes(exec, worktree: f.worktree, repo: repo(repos, ""), repos: repos,
                                                     compare: .committed(base: "main"))
        let fresh = try #require(committed.pointers.first { $0.repo.path == "libs/fresh" })
        #expect(fresh.from == nil)
        #expect(fresh.to != nil)
        #expect(committed.files.map(\.path) == [".gitmodules"], "its files are its own")
    }

    // MARK: Paths

    @Test func aChangeInANestedSubmoduleIsThatSubmodules() async throws {
        let f = try await SubmoduleFixture.make()
        defer { f.remove() }
        try f.write(f.worktree + "/libs/core/vendor/deep/a.txt", "deep\nchanged\n")
        let repos = await Submodules.list(exec, worktree: f.worktree)
        let deep = try await RepoReview.changes(exec, worktree: f.worktree, repo: repo(repos, "libs/core/vendor/deep"), repos: repos,
                                                compare: .uncommitted)
        #expect(deep.files.map(\.path) == ["libs/core/vendor/deep/a.txt"])
        #expect(deep.files.map(\.repoPath) == ["a.txt"])
        #expect(try await RepoReview.changes(exec, worktree: f.worktree, repo: repo(repos, "libs/core"), repos: repos, compare: .uncommitted)
            .files.isEmpty, "not libs/core's, not even as a gitlink")
        #expect(try await Diff.collectUncommitted(exec, worktree: f.worktree).map(\.path) == ["libs/core/vendor/deep/a.txt"])
    }

    @Test func aRenameInASubmoduleNamesBothPathsBothWays() async throws {
        let f = try await SubmoduleFixture.make()
        defer { f.remove() }
        try await f.git(f.worktree + "/libs/core", ["mv", "a.txt", "b.txt"])
        let repos = await Submodules.list(exec, worktree: f.worktree)
        let file = try #require(try await RepoReview.changes(exec, worktree: f.worktree, repo: repo(repos, "libs/core"), repos: repos,
                                                             compare: .uncommitted).files.first)
        #expect(file.status == .renamed)
        #expect(file.path == "libs/core/b.txt")
        #expect(file.oldPath == "libs/core/a.txt")
        #expect(file.repoPath == "b.txt")
        #expect(file.repoOldPath == "a.txt")
    }

    // MARK: Reading only what changed

    @Test func theWorktreesStatusNamesTheSubmodulesWithChanges() async throws {
        let f = try await SubmoduleFixture.make()
        defer { f.remove() }
        let other = f.worktree + "/libs/other lib"
        // Even where the submodule's own settings hide new files from its status.
        try await f.git(other, ["config", "status.showUntrackedFiles", "no"])
        try f.write(other + "/new.txt", "new\n")
        let changed = try #require(await Submodules.changedPaths(exec, worktree: f.worktree))
        #expect(changed.contains("libs/other lib"))
        #expect(!changed.contains("libs/core"))

        try f.write(f.worktree + "/libs/core/vendor/deep/a.txt", "deep\nchanged\n")
        #expect(await Submodules.changedPaths(exec, worktree: f.worktree)?.contains("libs/core") == true,
                "a change in a nested submodule marks the one holding it")
        #expect(await Submodules.changedPaths(exec, worktree: f.dir) == nil, "not a repository")
    }

    @Test func aCleanSubmoduleIsntReadForTheChatsSummary() async throws {
        let f = try await SubmoduleFixture.make()
        defer { f.remove() }
        try f.write(f.worktree + "/libs/other lib/b.txt", "b\n")
        let repos = await Submodules.list(exec, worktree: f.worktree)
        let recording = RecordingExecutor()
        let files = try await Diff.collectUncommitted(recording, worktree: f.worktree, repos: repos, exclude: [])
        #expect(files.map(\.path) == ["libs/other lib/b.txt"])
        #expect(!recording.folders.contains { $0.hasPrefix(f.worktree + "/libs/core") },
                "libs/core and the submodule inside it are clean, so no git runs there")
    }

    @Test func commitsInDifferentRepositoriesNeverShareAnID() {
        let top = CommitSummary(sha: "a1b2c3", shortSha: "a1b2c3", author: "", date: nil, subject: "")
        let sub = CommitSummary(sha: "a1b2c3", shortSha: "a1b2c3", author: "", date: nil, subject: "", repo: "libs/core")
        #expect(top.id != sub.id, "two submodules cloned from one upstream share their commits")
    }

    // MARK: Files pane

    @Test func theFilesPaneListsWhatsInsideSubmodules() async throws {
        let f = try await SubmoduleFixture.make()
        defer { f.remove() }
        try f.write(f.worktree + "/libs/core/new.txt", "new\n")
        try f.write(f.worktree + "/libs/core/a.txt", "core\nchanged\n")

        let listing = try #require(await Submodules.files(exec, worktree: f.worktree))
        let paths = Set(listing.paths)
        #expect(paths.isSuperset(of: ["a.txt", ".gitmodules", "libs/core/a.txt", "libs/core/new.txt",
                                      "libs/core/vendor/deep/a.txt", "libs/other lib/a.txt"]))
        #expect(paths.isSuperset(of: ["libs/core/", "libs/core/vendor/deep/", "libs/other lib/", "libs/unused/"]),
                "each submodule is a folder, even one that isn't checked out")
        #expect(paths.isDisjoint(with: ["libs/core", "libs/unused", "libs/core/vendor/deep"]), "never a file")
        #expect(listing.submodules == ["libs/core", "libs/core/vendor/deep", "libs/other lib", "libs/unused"])
        #expect(listing.statuses["libs/core"]?.contains("new.txt") == true, "badges come from the submodule's own status")
        #expect(listing.statuses["libs/core"]?.contains("a.txt") == true)
        #expect(listing.statuses[""] != nil)
    }

    @Test func aRepositoryWithoutSubmodulesListsAsBefore() async throws {
        let f = try await SubmoduleFixture.make()
        defer { f.remove() }
        let plain = f.repo("deep")
        try f.write(plain + "/b.txt", "b\n")
        let listing = try #require(await Submodules.files(exec, worktree: plain))
        #expect(listing.paths.sorted() == ["a.txt", "b.txt"])
        #expect(listing.submodules.isEmpty)
        #expect(await Submodules.files(exec, worktree: f.dir) == nil, "not a repository")
    }
}
