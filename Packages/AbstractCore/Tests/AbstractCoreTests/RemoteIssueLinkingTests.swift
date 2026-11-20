import Foundation
import Testing
@testable import AbstractCore

/// ABS-215: a chat (or a new chat's project) on another Mac links Jira and
/// Linear issues through that Mac: its trackers, its links, its code host.
/// Nothing is asked of this Mac's plugins. Every key, title and link here
/// is made up.
@Suite struct RemoteIssueLinkingTests {
    static let jira = "sh.example.jira", linear = "sh.example.linear"

    /// A paired Mac that answers from a script, and remembers what it was asked.
    final class FakeHost: @unchecked Sendable {
        private let lock = NSLock()
        private var _asked: [RemoteRequest] = []
        var answer: @Sendable (RemoteRequest) -> RemoteResponse

        init(answer: @escaping @Sendable (RemoteRequest) -> RemoteResponse) { self.answer = answer }

        var asked: [RemoteRequest] { lock.withLock { _asked } }

        func linking(projectId: String? = "host-project", chatId: String? = "host-chat") -> RemoteIssueLinking {
            RemoteIssueLinking(macName: "Studio", projectId: projectId, chatId: chatId) { [self] request in
                lock.withLock { _asked.append(request) }
                return answer(request)
            }
        }
    }

    static func tracker(_ id: String, _ title: String, example: String, link: String? = nil, key: String? = nil) -> RemoteIssueTracker {
        RemoteIssueTracker(id: id, title: title, keyExample: example, version: "1.0.0", link: link, linkKey: key)
    }

    static let linkedToJira = RemoteIssueSources(
        trackers: [tracker(jira, "Jira", example: "SHOP-1", link: "Shop", key: "SHOP")], linked: true,
        codeHost: "GitHub", githubIssues: true, pullRequests: true,
        others: [tracker(linear, "Linear", example: "ENG-1")])

    static let unlinked = RemoteIssueSources(
        trackers: [tracker(jira, "Jira", example: "SHOP-1"), tracker(linear, "Linear", example: "ENG-1")], linked: false,
        codeHost: "GitHub", githubIssues: true, pullRequests: true)

    // MARK: Where a chat's issues come from

    @Test func aChatFromAnotherMacLinksThroughThatMac() {
        // Even when this Mac has a project with the same id.
        let place = IssueLinkPlace.of(chat: (device: "mac-b", session: "host-chat"), chatProjectId: "p1", projectId: nil,
                                      isLocalProject: { _ in true }, deviceOfProject: { _ in nil })
        #expect(place == .mac(device: "mac-b", projectId: "p1", chatId: "host-chat"))
    }

    @Test func aNewChatOnAnotherMacsProjectLinksThroughThatMac() {
        let place = IssueLinkPlace.of(chat: nil, chatProjectId: nil, projectId: "p2",
                                      isLocalProject: { _ in false }, deviceOfProject: { $0 == "p2" ? "mac-b" : nil })
        #expect(place == .mac(device: "mac-b", projectId: "p2", chatId: nil))
    }

    @Test func thisMacsOwnChatsAndProjectsStayHere() {
        let local = IssueLinkPlace.of(chat: nil, chatProjectId: "p1", projectId: "p1",
                                      isLocalProject: { _ in true }, deviceOfProject: { _ in "mac-b" })
        #expect(local == .here)
        let standalone = IssueLinkPlace.of(chat: nil, chatProjectId: nil, projectId: nil,
                                           isLocalProject: { _ in false }, deviceOfProject: { _ in nil })
        #expect(standalone == .here)
    }

    // MARK: Asking the other Mac

    @Test func theButtonsAndScopeComeFromTheHostsSources() async throws {
        let host = FakeHost { _ in .issueSources(Self.linkedToJira) }
        let sources = try await host.linking().sources(iconVersions: [Self.jira: "1.0.0"])
        guard case .issueSources(let projectId, let chatId, let versions)? = host.asked.first else {
            Issue.record("asked \(host.asked)"); return
        }
        #expect(projectId == "host-project" && chatId == "host-chat" && versions == [Self.jira: "1.0.0"])

        let trackers = ProjectIssueTrackers(sources)
        // Only Jira, within the host's link.
        #expect(trackers.shown().map(\.title) == ["Jira"])
        #expect(trackers.linked.map(\.link.title) == ["Shop"])
        #expect(trackers.linked.first?.link.project?.key == "SHOP")
        #expect(trackers.canSearchAll)
        // Search all names every tracker that's on there.
        #expect(trackers.shown(searchAll: true).map(\.title) == ["Jira", "Linear"])
        #expect(trackers.shown()[0].declaration.keyExample == "SHOP-1")
    }

    @Test func anUnlinkedProjectOffersEveryTrackerOnThatMac() {
        let trackers = ProjectIssueTrackers(Self.unlinked)
        #expect(trackers.linked.isEmpty && !trackers.canSearchAll)
        #expect(trackers.shown().map(\.title) == ["Jira", "Linear"])
    }

    @Test func searchesGoThroughTheLink() async throws {
        let issue = PromptAttachment(kind: .trackerIssue, title: "Checkout retries twice", reference: "SHOP-42",
                                     url: "https://example.atlassian.net/browse/SHOP-42", tracker: Self.jira, trackerName: "Jira")
        let group = RemoteIssueGroup(sourceId: Self.jira, title: "Jira", results: [
            RemoteIssueResult(reference: "SHOP-42", title: "Checkout retries twice", state: "To Do", attachment: issue),
        ])
        let host = FakeHost { _ in .issueGroups([group]) }
        let groups = try await host.linking().search("retries", searchAll: true)
        #expect(groups == [group])
        guard case .searchIssues(let projectId, let chatId, let trackerId, let query, let all)? = host.asked.first else {
            Issue.record("asked \(host.asked)"); return
        }
        #expect(projectId == "host-project" && chatId == "host-chat" && trackerId == nil && query == "retries" && all)
    }

    @Test func aSearchTheHostRefusesSaysWhy() async {
        let host = FakeHost { _ in .failed("Studio has no issue tracker turned on.") }
        await #expect(throws: AbstractError.message("Studio has no issue tracker turned on.")) {
            try await host.linking().search("x", searchAll: false)
        }
    }

    @Test func thePickedIssueIsCompletedByTheHost() async {
        let listed = PromptAttachment(kind: .trackerIssue, title: "Checkout retries twice", reference: "SHOP-42",
                                      url: "https://example.atlassian.net/browse/SHOP-42", tracker: Self.jira, trackerName: "Jira")
        var completed = listed
        completed.body = "Paying twice charges twice."
        let whole = completed
        let host = FakeHost { _ in .attachment(whole) }
        #expect(await host.linking().complete(listed) == whole)
        guard case .completeIssue(let asked)? = host.asked.first else { Issue.record("asked \(host.asked)"); return }
        #expect(asked == listed)

        // If it can't, the issue goes as it was listed, as on the Mac.
        let failing = FakeHost { _ in .failed("Jira isn't signed in on Studio.") }
        #expect(await failing.linking().complete(listed) == listed)
    }

    @Test func pullRequestsComeFromTheHostsCodeHost() async throws {
        let pr = ForgeItem(number: 7, title: "Retry once", url: "https://github.com/example/shop/pull/7", state: "OPEN",
                           body: nil, isPullRequest: true, isDraft: false, baseRefName: "main", headRefName: "retry-once")
        let group = RemoteIssueGroup(codeHost: "sh.abstract.github", title: "GitHub", items: [pr])
        let host = FakeHost { _ in .issueGroups([group]) }
        let found = try await host.linking().searchCodeHost("retry", pullRequests: true)
        #expect(found.results.map(\.reference) == ["#7"])
        guard case .searchCodeHost(let projectId, let chatId, let query, let pullRequests)? = host.asked.first else {
            Issue.record("asked \(host.asked)"); return
        }
        #expect(projectId == "host-project" && chatId == "host-chat" && query == "retry" && pullRequests)
    }

    // MARK: An older Mac

    @Test func anOlderMacIsAskedNothingAndSaysToUpdate() throws {
        let old = try JSONDecoder().decode(RemoteSnapshot.self, from: Data(#"{"projects":[],"sessions":[],"providers":[],"alive":[]}"#.utf8))
        #expect(!RemoteIssueLinking.answers(old))
        #expect(!RemoteIssueLinking.answers(nil))
        #expect(RemoteIssueLinking.answers(RemoteSnapshot(projects: [], sessions: [], providers: [], alive: [], issueSearch: true)))
        #expect(RemoteIssueLinking.updateSentence(macName: "Studio") == "Update Abstract on Studio to link issues from here.")
    }

    @Test func sourcesFromAnABS211MacStillDecode() throws {
        let json = #"{"trackers":[{"id":"sh.example.jira","title":"Jira","keyExample":"SHOP-1","version":"1.0.0","link":"Shop"}],"linked":true,"githubIssues":false,"pullRequests":true}"#
        let sources = try JSONDecoder().decode(RemoteIssueSources.self, from: Data(json.utf8))
        #expect(sources.others == nil)
        // Search all can only name the linked tracker then.
        #expect(ProjectIssueTrackers(sources).shown(searchAll: true).map(\.title) == ["Jira"])
    }

    @Test func theHostNamesItsOtherTrackersForSearchAll() {
        let jira = ResolvedIssueTracker(pluginId: Self.jira, declaration: .init(title: "Jira", keyExample: "SHOP-1"))
        let linear = ResolvedIssueTracker(pluginId: Self.linear, declaration: .init(title: "Linear", keyExample: "ENG-1"))
        let link = TrackerProjectLink(project: .init(id: "project:SHOP", name: "Shop", key: "SHOP"))
        let linked = RemoteIssueSources(ProjectIssueTrackers(available: [jira, linear], links: [Self.jira: link]), installed: [])
        #expect(linked.trackers.map(\.id) == [Self.jira])
        #expect(linked.others?.map(\.id) == [Self.linear])
        let unlinked = RemoteIssueSources(ProjectIssueTrackers(available: [jira, linear], links: [:]), installed: [])
        #expect(unlinked.others == nil)
    }

    // MARK: Cached briefly

    @Test func sourcesAreKeptUntilTheHostsTrackerLinksChange() {
        var cache = RemoteIssueSourceCache()
        let key = RemoteIssueSourceCache.key(projectId: "host-project", chatId: "host-chat")
        let now = Date()
        #expect(!cache.isFresh(key, revision: 3, now: now))
        cache.store(Self.linkedToJira, for: key, revision: 3, at: now)
        #expect(cache.isFresh(key, revision: 3, now: now.addingTimeInterval(3600)))
        #expect(cache.sources(key) == Self.linkedToJira)
        // The host's snapshot says a link changed: ask again, showing the old answer meanwhile.
        #expect(!cache.isFresh(key, revision: 4, now: now))
        #expect(cache.sources(key) == Self.linkedToJira)
        // Another chat is its own entry.
        #expect(!cache.isFresh(RemoteIssueSourceCache.key(projectId: "host-project", chatId: "other"), revision: 3, now: now))
    }

    @Test func aHostWithoutARevisionIsAskedAgainAfterAMinute() {
        var cache = RemoteIssueSourceCache()
        let key = RemoteIssueSourceCache.key(projectId: "host-project", chatId: nil)
        let now = Date()
        cache.store(Self.unlinked, for: key, revision: nil, at: now)
        #expect(cache.isFresh(key, revision: nil, now: now.addingTimeInterval(30)))
        #expect(!cache.isFresh(key, revision: nil, now: now.addingTimeInterval(RemoteIssueSourceCache.unversionedLifetime + 1)))
    }

    @Test func iconsReceivedAreNotAskedForAgain() {
        var cache = RemoteIssueSourceCache()
        var sources = Self.linkedToJira
        sources.trackers[0].icon = Data("<svg/>".utf8)
        cache.store(sources, for: "k", revision: 1, at: Date())
        #expect(cache.iconVersions == [Self.jira: "1.0.0"])
        // A later answer without the icon keeps what was received.
        cache.store(Self.linkedToJira, for: "k", revision: 2, at: Date())
        #expect(cache.iconVersions == [Self.jira: "1.0.0"])
    }

    @Test func theSnapshotCarriesTheTrackerLinkRevision() throws {
        let snapshot = RemoteSnapshot(projects: [], sessions: [], providers: [], alive: [], issueSearch: true, issueSourcesRevision: 42)
        let back = try JSONDecoder().decode(RemoteSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(back.issueSourcesRevision == 42)
    }
}
