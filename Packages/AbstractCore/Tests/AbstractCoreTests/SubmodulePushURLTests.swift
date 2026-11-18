import Foundation
import Testing
@testable import AbstractCore

extension GitHeavy {
    /// A chat's worktree whose submodule was cloned from a local path (a
    /// main checkout's `submodule.<name>.url` override does that) pushes to
    /// what `.gitmodules` registers, and still fetches locally (ABS-207).
    @Suite("Submodule push URLs", .serialized)
    struct SubmodulePushURLTests {
        let exec = LocalExecutor.shared
        static let registered = "https://github.com/acme/backend.git"

        /// The dunsguide layout, on temporary repositories:
        ///
        ///     backend/        the submodule's repository, cloned from locally
        ///     hosted.git      a bare stand-in for its GitHub repository
        ///     app/            the main checkout: `.gitmodules` registers the
        ///                     GitHub URL, its config overrides it with backend/
        ///     wt/             a chat's worktree of app, made as Abstract makes one
        private func make() async throws -> SubmoduleFixture {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("abstract-pushurl-\(UUID().uuidString)").path
            let f = SubmoduleFixture(dir: dir)
            for name in ["backend", "app"] {
                try FileManager.default.createDirectory(atPath: f.repo(name), withIntermediateDirectories: true)
                try await f.git(f.repo(name), ["init", "-q", "-b", "main"])
                try f.write(f.repo(name) + "/a.txt", "\(name)\n")
                try await f.commitAll(f.repo(name), "init")
            }
            try await f.git(dir, ["clone", "-q", "--bare", f.repo("backend"), "hosted.git"])
            try await f.git(f.app, ["submodule", "add", "-q", f.repo("backend"), "backend"])
            try await f.git(f.app, ["config", "-f", ".gitmodules", "submodule.backend.url", Self.registered])
            try await f.commitAll(f.app, "Add backend")
            try await f.git(f.app, ["config", "submodule.backend.url", f.repo("backend")])
            try await f.git(f.app, ["config", "protocol.file.allow", "always"])
            try await f.git(f.app, ["remote", "add", "origin", "git@github.com:acme/app.git"])
            try await Git.addWorktree(exec, root: f.app, path: f.worktree, branch: "chat", baseRef: "main")
            // A local clone needs the file transport allowed on the command line, where it reaches git's inner clone.
            try await f.git(f.worktree, ["submodule", "update", "-q", "--init"])
            try await f.identify(f.worktree + "/backend")
            return f
        }

        private func url(_ f: SubmoduleFixture, _ dir: String, push: Bool) async throws -> String {
            GitText.trimmed(try await f.git(dir, ["remote", "get-url"] + (push ? ["--push"] : []) + ["origin"]))
        }

        @Test func aSubmoduleClonedFromALocalPathPushesToItsRegisteredURL() async throws {
            let f = try await make()
            defer { f.remove() }
            let backend = f.worktree + "/backend"
            #expect(try await url(f, backend, push: false) == f.repo("backend"), "set up as dunsguide's worktrees are")

            let changed = await Submodules.pushToRegisteredURLs(exec, worktree: f.worktree)
            #expect(changed.map(\.path) == ["backend"])
            #expect(changed.map(\.url) == [Self.registered])
            #expect(try await url(f, backend, push: true) == Self.registered)
            #expect(try await url(f, backend, push: false) == f.repo("backend"), "fetches still come from the local copy")

            // Fetching still works, from the local copy.
            try f.write(f.repo("backend") + "/b.txt", "new\n")
            try await f.commitAll(f.repo("backend"), "More")
            try await f.git(backend, ["fetch", "-q", "origin"])
            #expect(GitText.trimmed(try await f.git(backend, ["rev-parse", "origin/main"]))
                    == GitText.trimmed(try await f.git(f.repo("backend"), ["rev-parse", "main"])))

            // A push goes to the registered URL (here rewritten to the stand-in), not the local copy.
            try await f.git(backend, ["config", "url.\(f.repo("hosted.git")).insteadOf", Self.registered])
            try f.write(backend + "/c.txt", "chat\n")
            try await f.commitAll(backend, "Chat work")
            try await f.commitAll(f.worktree, "Move the backend pointer")
            let repos = await Submodules.list(exec, worktree: f.worktree)
            #expect(await Shipping.unpublishedPointers(exec, worktree: f.worktree, repos: repos, base: "main").map(\.repo.path)
                    == ["backend"], "not on its code host yet: the parent waits")
            try await Git.push(exec, worktree: backend, branch: "chat")
            #expect(try await f.git(f.repo("hosted.git"), ["branch", "--list", "chat"]).contains("chat"))
            #expect(try await !f.git(f.repo("backend"), ["branch", "--list", "chat"]).contains("chat"))
            #expect(await Shipping.unpublishedPointers(exec, worktree: f.worktree, repos: repos, base: "main").isEmpty,
                    "on its code host now, though the local copy it fetches from hasn't got it: the parent can go")
            #expect(await Git.separatePushURL(exec, root: backend) == Self.registered)
            #expect(await Git.separatePushURL(exec, root: f.app + "/backend") == nil)

            // Only the worktree's submodule changed: never the main checkout's config.
            #expect(try await f.git(f.app, ["config", "--get", "submodule.backend.url"]).contains(f.repo("backend")))
            let mainPush = try await exec.run("git", ["config", "--get", "remote.origin.pushurl"], cwd: f.app + "/backend")
            #expect(!mainPush.ok, "the main checkout's own submodule is left alone")

            // Once: a second look changes nothing, so says nothing.
            #expect(await Submodules.pushToRegisteredURLs(exec, worktree: f.worktree).isEmpty)
        }

        @Test func aPushURLAlreadySetIsLeftAlone() async throws {
            let f = try await make()
            defer { f.remove() }
            let backend = f.worktree + "/backend"
            try await f.git(backend, ["remote", "set-url", "--push", "origin", "git@example.com:mine/backend.git"])
            #expect(await Submodules.pushToRegisteredURLs(exec, worktree: f.worktree).isEmpty)
            #expect(try await url(f, backend, push: true) == "git@example.com:mine/backend.git")
        }

        @Test func aSubmoduleCloneOfItsHostAndARepositoryWithoutSubmodulesAreLeftAlone() async throws {
            let f = try await make()
            defer { f.remove() }
            let backend = f.worktree + "/backend"
            try await f.git(backend, ["remote", "set-url", "origin", "git@github.com:acme/backend.git"])
            #expect(await Submodules.pushToRegisteredURLs(exec, worktree: f.worktree).isEmpty)
            #expect(try await url(f, backend, push: true) == "git@github.com:acme/backend.git")
            #expect(await Submodules.pushToRegisteredURLs(exec, worktree: f.repo("backend")).isEmpty)
        }

        @Test func theProjectListsTheSubmoduleWithItsRegisteredURL() async throws {
            let f = try await make()
            defer { f.remove() }
            // The main checkout's own submodule, cloned from the local path too.
            let repos = await ProjectRepos.list(exec, project: Project(name: "app", rootPath: f.app))
            let backend = try #require(repos.first { $0.path == "backend" })
            #expect(backend.remote == Self.registered)
            #expect(backend.registered == Self.registered)
            #expect(PullRequestLink.place(URL(string: "https://github.com/acme/backend/pull/3")!, in: repos)?.repoPath == "backend")
            #expect(PullRequestLink.place(URL(string: "https://github.com/acme/app/pull/3")!, in: repos)?.repoPath == "")
        }
    }
}
