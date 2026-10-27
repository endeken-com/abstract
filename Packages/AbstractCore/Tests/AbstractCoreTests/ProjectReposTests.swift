import Foundation
import Testing
@testable import AbstractCore

@Suite struct ProjectReposTests {
    private func pr(_ number: Int, repo: String = "", head: String = "chat", title: String? = nil) -> PullRequest {
        var pr = PullRequest(number: number, title: title ?? "PR \(number)", state: .open, isDraft: false, url: nil,
                             head: head, base: "main", author: nil, reviewDecision: nil, mergeable: nil, mergeState: nil,
                             additions: nil, deletions: nil, changedFiles: nil, createdAt: nil, updatedAt: nil, body: nil,
                             mergeCommit: nil, checks: [], reviews: [], comments: [])
        pr.repoPath = repo
        return pr
    }

    // MARK: Which repositories a project has

    @Test func aRepoThatIsNestedAndASubmoduleIsListedOnce() {
        let paths = ProjectRepos.paths(nested: ["libs/core", "tools/helper"],
                                       submodules: ["libs/core", "libs/other", "./libs/other/"])
        #expect(paths == ["", "libs/core", "tools/helper", "libs/other"])
    }

    @Test func pathsAreNormalizedAndBlanksSkipped() {
        #expect(ProjectRepos.paths(nested: [" ./a/ ", "", ".", "/"], submodules: []) == ["", "a"])
        #expect(ProjectRepos.paths(nested: [], submodules: []) == [""])
    }

    @Test func theSameRemoteUnderTwoSpellingsIsOneRepo() {
        let repos = ProjectRepos.dedupeByRemote([
            (path: "", remote: "git@github.com:acme/app.git"),
            (path: "copy", remote: "https://github.com/acme/app"),
            (path: "libs/core", remote: "https://github.com/acme/core.git"),
        ])
        #expect(repos.map(\.path) == ["", "libs/core"])
    }

    @Test func aRepoIsNamedFromItsRemoteElseItsFolder() {
        #expect(ProjectRepos.name(path: "libs/core", remote: "git@github.com:acme/core.git") == "core")
        #expect(ProjectRepos.name(path: "libs/core", remote: nil) == "core")
        #expect(ProjectRepos.name(path: "", remote: "https://github.com/acme/app.git") == "app")
        #expect(ProjectRepos.name(path: "", remote: nil) == nil)
    }

    @Test func aRelativeSubmoduleURLResolvesAgainstItsParentsRemote() {
        #expect(GitRemote.resolveRelative("../core.git", against: "https://github.com/acme/app.git")
            == "https://github.com/acme/core.git")
        #expect(GitRemote.resolveRelative("../../libs/core", against: "git@github.com:acme/group/app.git")
            == "git@github.com:acme/libs/core")
        #expect(GitRemote.resolveRelative("https://example.com/x/y.git", against: "https://github.com/acme/app.git")
            == "https://example.com/x/y.git")
        #expect(GitRemote.resolveRelative("../core.git", against: "/local/app.git") == "../core.git")
    }

    // MARK: Showing and matching pull requests

    @Test func nestedAndSubmodulePRsReadBeforeTheMainRepos() {
        let main = pr(3), core = pr(1, repo: "libs/core"), deep = pr(2, repo: "libs/core/vendor/deep")
        let mainOlder = pr(4)
        #expect(ProjectRepos.ordered([main, core, mainOlder, deep]).map(\.number) == [2, 1, 3, 4])
        // One repository: the host's order stands.
        #expect(ProjectRepos.ordered([main, mainOlder]).map(\.number) == [3, 4])
    }

    @Test func theSameBranchNameInTwoReposMatchesInEach() {
        let list = [pr(7), pr(7, repo: "libs/core"), pr(8, repo: "libs/core", head: "other")]
        let matches = ProjectRepos.matching(branch: "chat", in: list)
        #expect(matches.map(\.repoPath) == ["libs/core", ""])
        #expect(Set(matches.map(\.id)).count == 2)
    }

    @Test func theSameNumberInTwoReposIsTwoPullRequests() {
        let a = pr(7), b = pr(7, repo: "libs/core")
        #expect(a.id != b.id)
        #expect(!a.isSame(as: b) && a.isSame(as: pr(7)))
        #expect(ProjectRepos.deduped([a, b, pr(7), pr(7, repo: "libs/core")]).count == 2)
        // A summary never refreshes another repository's pull request.
        #expect(a.refreshingSummary(with: b).repoPath == "libs/core")
    }

    // MARK: Real git

    @Test func discoveryFindsTheMainNestedAndSubmoduleReposOnceEach() async throws {
        let f = try await SubmoduleFixture.make()
        defer { f.remove() }
        // Remotes as a hosted project has them (config only; nothing is fetched).
        try await f.git(f.app, ["submodule", "update", "-q", "--init", "--recursive", "--", "libs/core"])
        try await f.git(f.app, ["remote", "add", "origin", "https://github.com/acme/app.git"])
        try await f.git(f.app + "/libs/core", ["remote", "set-url", "origin", "https://github.com/acme/core.git"])
        try await f.git(f.app + "/libs/core/vendor/deep", ["remote", "set-url", "origin", "git@github.com:acme/deep.git"])
        try await f.git(f.app + "/libs/other lib", ["remote", "set-url", "origin", "https://github.com/acme/other.git"])
        // A declared nested repo git knows nothing about.
        try FileManager.default.createDirectory(atPath: f.app + "/tools/helper", withIntermediateDirectories: true)
        try await f.git(f.app + "/tools/helper", ["init", "-q", "-b", "main"])
        try await f.git(f.app + "/tools/helper", ["remote", "add", "origin", "https://github.com/acme/helper.git"])

        let project = Project(name: "app", rootPath: f.app, nestedRepos: ["libs/core", "tools/helper"])
        let repos = await ProjectRepos.list(f.exec, project: project)
        #expect(repos.map(\.path) == ["", "libs/core", "tools/helper", "libs/core/vendor/deep", "libs/other lib", "libs/unused"])
        #expect(repos.first { $0.path == "libs/core" }?.remote == "https://github.com/acme/core.git")
        #expect(repos.first { $0.path == "tools/helper" }?.name == "helper")
        #expect(repos.first { $0.path == "" }?.name == "app")
    }
}
