import Foundation
import Synchronization
import Testing
@testable import AbstractCore

/// A pull request knows its repository from its link, and a submodule's is
/// never the project's own with the same number (ABS-207).
@Suite struct PullRequestLinkTests {
    typealias H = GitHubPluginHarness

    // MARK: Links

    @Test func pagesOfEachCodeHost() throws {
        let github = try #require(PullRequestLink.page(URL(string: "https://github.com/CialDNB/dunsguide-backend/pull/3345")!))
        #expect(github == .init(host: "github.com", repository: "CialDNB/dunsguide-backend", number: 3345))
        #expect(github.repositoryURL == "https://github.com/CialDNB/dunsguide-backend")
        #expect(PullRequestLink.page(URL(string: "https://bitbucket.org/acme/app/pull-requests/12")!)
                == .init(host: "bitbucket.org", repository: "acme/app", number: 12))
        #expect(PullRequestLink.page(URL(string: "https://git.example.com/projects/KEY/repos/app/pull-requests/7")!)
                == .init(host: "git.example.com", repository: "KEY/app", number: 7))
        #expect(PullRequestLink.page(URL(string: "https://gitlab.com/group/sub/app/-/merge_requests/5")!)
                == .init(host: "gitlab.com", repository: "group/sub/app", number: 5))
        #expect(PullRequestLink.page(URL(string: "https://github.com/acme/app/issues/3")!) == nil)
        #expect(PullRequestLink.page(URL(string: "https://github.com/pull/3")!) == nil)
        #expect(PullRequestLink.page(URL(string: "file:///tmp/app/pull/3")!) == nil)
    }

    private let dunsguide = [
        ProjectRepo(path: "", remote: "git@github.com:CialDNB/dunsguide.git"),
        ProjectRepo(path: "dunsguide-backend", remote: "git@github.com:CialDNB/dunsguide-backend.git",
                    registered: "git@github.com:CialDNB/dunsguide-backend.git"),
        ProjectRepo(path: "tools/nested", remote: "https://github.com/CialDNB/nested-tool.git"),
    ]

    private func place(_ link: String, _ repos: [ProjectRepo]) -> PullRequestLink.Place? {
        PullRequestLink.place(URL(string: link)!, in: repos)
    }

    @Test func linksMapToTheMainRepositoryASubmoduleOrANestedOne() {
        #expect(place("https://github.com/CialDNB/dunsguide/pull/3345", dunsguide) == .init(repoPath: "", repoName: "dunsguide"))
        #expect(place("https://github.com/CialDNB/dunsguide-backend/pull/3345", dunsguide)
                == .init(repoPath: "dunsguide-backend", repoName: "dunsguide-backend"))
        #expect(place("https://github.com/cialdnb/Nested-Tool/pull/2", dunsguide)?.repoPath == "tools/nested", "case doesn't matter")
    }

    @Test func aSubmoduleClonedFromALocalPathIsFoundByItsRegisteredURL() {
        let repos = [ProjectRepo(path: "", remote: "git@github.com:acme/app.git"),
                     ProjectRepo(path: "libs/core", remote: "/path/to/app/.git/modules/libs/core",
                                 registered: "git@github.com:acme/core.git")]
        #expect(place("https://github.com/acme/core/pull/9", repos)?.repoPath == "libs/core")
    }

    @Test func anSSHAliasForTheHostStillMatchesByPath() {
        let repos = [ProjectRepo(path: "", remote: "git@github-work:acme/app.git"),
                     ProjectRepo(path: "libs/core", remote: "git@github-work:acme/core.git")]
        #expect(place("https://github.com/acme/core/pull/9", repos)?.repoPath == "libs/core")
        #expect(place("https://github.com/acme/app/pull/9", repos)?.repoPath == "")
    }

    @Test func bitbucketRepositoriesMatchTheirLinks() {
        let cloud = [ProjectRepo(path: "", remote: "git@bitbucket.org:acme/app.git"),
                     ProjectRepo(path: "core", remote: "https://bitbucket.org/acme/core.git")]
        #expect(place("https://bitbucket.org/acme/core/pull-requests/4", cloud)?.repoPath == "core")
        let server = [ProjectRepo(path: "", remote: "https://git.example.com/scm/key/app.git"),
                      ProjectRepo(path: "core", remote: "ssh://git@git.example.com:7999/key/core.git")]
        #expect(place("https://git.example.com/projects/KEY/repos/core/pull-requests/4", server)?.repoPath == "core")
        #expect(place("https://git.example.com/projects/KEY/repos/app/pull-requests/4", server)?.repoPath == "")
    }

    @Test func aLinkToNoRepositoryOfTheProjectIsOutsideItNeverTheMainOne() {
        let outside = place("https://github.com/someone/else/pull/3345", dunsguide)
        #expect(outside == .init(repoPath: "https://github.com/someone/else", repoName: "someone/else"))
        #expect(PullRequestLink.isExternal(outside?.repoPath ?? ""))
        #expect(PullRequest.id(repoPath: outside?.repoPath ?? "", number: 3345) != "#3345")
        // Its code host is that repository's.
        #expect(ProjectRepos.repo(forPullRequest: "https://github.com/someone/else", in: dunsguide)?.remote
                == "https://github.com/someone/else")
        #expect(ProjectRepos.repo(forPullRequest: "dunsguide-backend", in: dunsguide)?.remote
                == "git@github.com:CialDNB/dunsguide-backend.git")
        #expect(ProjectRepos.repo(forPullRequest: "gone", in: dunsguide)?.isMain == true)
    }

    @Test func aProjectWithoutSubmodulesKeepsNumberOnlyIds() {
        let single = [ProjectRepo(path: "", remote: "https://github.com/acme/app.git")]
        let found = place("https://github.com/acme/app/pull/12", single)
        #expect(found?.repoPath == "")
        #expect(PullRequest.id(repoPath: found?.repoPath ?? "x", number: 12) == "#12")
    }

    // MARK: The agent's pull request (the DGDEV-1381 chat)

    struct Recorded {
        let json: JSONValue
        var branch: String { json["project"]?["branch"]?.string ?? "" }

        static func load() throws -> Recorded {
            let url = try #require(Bundle.module.url(forResource: "dgdev-1381-submodule-pr", withExtension: "json", subdirectory: "Fixtures"))
            return Recorded(json: JSONValue(any: try JSONSerialization.jsonObject(with: Data(contentsOf: url))))
        }

        /// What `gh pr view` said for `key` (`owner/name#n`), through the GitHub plugin.
        func pullRequest(_ key: String) throws -> PullRequest {
            let raw = try #require(json["gh"]?[key])
            let text = String(decoding: try JSONSerialization.data(withJSONObject: raw.anyObject), as: UTF8.self)
            return try H.decode(Data(text.utf8))
        }

        /// The project's repositories as its main checkout lists them.
        var repos: [ProjectRepo] {
            let project = json["project"]
            let submodules = (project?["submodules"]?.array ?? []).map {
                ProjectRepo(path: $0["path"]?.string ?? "", remote: $0["mainCheckoutOrigin"]?.string,
                            registered: $0["gitmodulesURL"]?.string)
            }
            return [ProjectRepo(path: "", remote: project?["origin"]?.string)] + submodules
        }
    }

    /// A code host that answers for one repository only, from `prs`, and notes what it was asked.
    final class FakeHost: Sendable {
        let prs: [PullRequest]
        let asked = Mutex<[String]>([])
        init(_ prs: [PullRequest]) { self.prs = prs }

        var host: CodeHost {
            CodeHost(pluginId: "fake", declaration: CodeHostDeclaration(title: "Fake", hosts: ["github.com"],
                                                                        operations: [.access, .listPullRequests, .pullRequest])) { op, input in
                let found: PullRequest?
                if let number = input["number"]?.int {
                    self.asked.withLock { $0.append("#\(number)") }
                    found = self.prs.first { $0.number == number }
                } else {
                    let branch = input["branch"]?.string ?? ""
                    self.asked.withLock { $0.append(branch) }
                    found = self.prs.first { $0.head == branch }
                }
                return .object(["pullRequest": found?.contractJSON() ?? .null])
            }
        }
    }

    @Test func theAgentsSubmodulePullRequestIsPinnedWithItsRepositoryAndReadFromIt() async throws {
        let recorded = try Recorded.load()
        let backendPR = try recorded.pullRequest("CialDNB/dunsguide-backend#3345")
        let parentPR = try recorded.pullRequest("CialDNB/dunsguide#3345")
        let hosts = ["": FakeHost([parentPR]), "dunsguide-backend": FakeHost([backendPR])]

        // The agent's own report, as Claude recorded it.
        let event = try #require(recorded.json["agentEvent"])
        let operations = GitOperation.claude(event["tool_use_result"]?["gitOperation"])
        let operation = try #require(operations.first)
        guard case let .pullRequest(number, url, action) = operation else { Issue.record("not a PR: \(operation)"); return }
        #expect(number == 3345 && action == "created")

        let repos = recorded.repos
        let place = await AgentPullRequest.place(number: number, url: url, branch: recorded.branch, repos: repos, ahead: []) {
            hosts[$0.path]?.host
        }
        let pinned = AgentPullRequest.placeholder(number: number, url: url, head: recorded.branch, base: "dev", place: place)
        #expect(pinned.id == "dunsguide-backend#3345")
        #expect(pinned.repoName == "dunsguide-backend")
        #expect(hosts.values.allSatisfy { $0.asked.withLock(\.isEmpty) }, "the link says where; no host is asked")

        // Refreshing reads it from its own repository's host, never the parent's.
        let repo = try #require(ProjectRepos.repo(forPullRequest: pinned.repoPath, in: repos))
        let read = try #require(try await hosts[repo.path]?.host.pullRequest(number: pinned.number))
        #expect(hosts[""]?.asked.withLock(\.isEmpty) == true)
        #expect(read.title == "DGDEV-1381 · Search filter extraction runs on AI SDK v6, clearing its security findings")
        #expect(read.state == .open)
        #expect(read.head == recorded.branch)
        #expect(read.checksSummary.failed == 0 && read.checksSummary.passed > 0)
        #expect(parentPR.title == "Staging into master [4.9.3]" && parentPR.state == .merged, "the wrong one, same number")

        // The chat is named after the right one.
        #expect(ChatNaming.pullRequestName(read.title, ticketFrom: ["DGDEV-1381 · Staging into master [4.9.3]"])
                == "DGDEV-1381 · Search filter extraction runs on AI SDK v6, clearing its security findings")
    }

    @Test func withNoLinkTheBranchIsAskedOfReposWithCommitsAheadFirst() async throws {
        let recorded = try Recorded.load()
        let backendPR = try recorded.pullRequest("CialDNB/dunsguide-backend#3345")
        let hosts = ["": FakeHost([]), "dunsguide-backend": FakeHost([backendPR])]
        let place = await AgentPullRequest.place(number: 3345, url: nil, branch: recorded.branch, repos: recorded.repos,
                                                 ahead: ["dunsguide-backend"]) { hosts[$0.path]?.host }
        #expect(place.repoPath == "dunsguide-backend")
        #expect(hosts[""]?.asked.withLock(\.isEmpty) == true, "the submodule with commits ahead answered first")

        #expect(AgentPullRequest.order(recorded.repos, ahead: []).map(\.path) == ["", "dunsguide-backend"])
        #expect(AgentPullRequest.order(recorded.repos, ahead: ["dunsguide-backend"]).map(\.path) == ["dunsguide-backend", ""])
    }

    @Test func withNoLinkAndNoAnswerItStaysTheProjectsOwn() async {
        let repos = [ProjectRepo(path: "", remote: "https://github.com/acme/app")]
        let place = await AgentPullRequest.place(number: 4, url: nil, branch: "chat", repos: repos, ahead: []) { _ in nil }
        #expect(place == .init(repoPath: "", repoName: "app"))
    }

    // MARK: Repair

    @Test func anOldNumberOnlyPinWhoseLinkNamesTheSubmoduleIsMoved() throws {
        let recorded = try Recorded.load()
        // What Abstract held before ABS-207: the agent's PR as the parent's "#3345".
        var old = try recorded.pullRequest("CialDNB/dunsguide-backend#3345")
        old.repoPath = ""
        #expect(old.id == "#3345")
        let moved = try #require(PullRequestLink.misplaced(old, in: recorded.repos))
        #expect(PullRequest.id(repoPath: moved.repoPath, number: old.number) == "dunsguide-backend#3345")
        #expect(moved.repoName == "dunsguide-backend")
    }

    @Test func aPullRequestWhereItsLinkSaysStays() throws {
        let recorded = try Recorded.load()
        var backend = try recorded.pullRequest("CialDNB/dunsguide-backend#3345")
        backend.repoPath = "dunsguide-backend"
        #expect(PullRequestLink.misplaced(backend, in: recorded.repos) == nil)
        #expect(PullRequestLink.misplaced(try recorded.pullRequest("CialDNB/dunsguide#3345"), in: recorded.repos) == nil)
        #expect(PullRequestLink.misplaced(backend, in: []) == nil, "nothing is moved before the repositories are read")
        var linkless = backend
        linkless.url = nil
        linkless.repoPath = ""
        #expect(PullRequestLink.misplaced(linkless, in: recorded.repos) == nil)
    }

    // MARK: Labels

    @Test func theSidebarNamesThePullRequestsRepository() {
        let pr = SidebarChats.PullRequestFacts(number: 3345, state: .open, repo: "dunsguide-backend")
        #expect(pr.label == "dunsguide-backend #3345")
        #expect(SidebarChats.Line(pullRequest: pr).text == "dunsguide-backend #3345")
        #expect(SidebarChats.PullRequestFacts(number: 12, state: .open).label == "#12")
    }
}
