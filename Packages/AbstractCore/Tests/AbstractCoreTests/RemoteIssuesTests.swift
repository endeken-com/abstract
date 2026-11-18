import Foundation
import Testing
@testable import AbstractCore

/// ABS-211: a paired phone finds and attaches Linear and Jira issues by
/// asking the Mac, whose tracker plugins answer as in its own composer.
/// Every key, title and link here is made up.
@Suite struct RemoteIssuesTests {
    func tracker(_ id: String, title: String, icon: String? = "icon.svg", example: String = "ABC-1") -> ResolvedIssueTracker {
        ResolvedIssueTracker(pluginId: id, declaration: PluginIssueTrackerDeclaration(
            title: title, icon: icon, keyExample: example, keyPattern: "[A-Za-z][A-Za-z0-9]*-[0-9]+"))
    }

    func installed(_ tracker: ResolvedIssueTracker, version: String = "1.1.0", folder: URL) -> InstalledPlugin {
        let manifest = PluginManifest(id: tracker.pluginId, name: tracker.title, version: version, capabilities: [])
        let record = PluginRecord(id: tracker.pluginId, name: tracker.title, version: version, source: .user,
                                  enabled: true, grantedBackground: true, packageHash: "h")
        return InstalledPlugin(record: record, manifest: manifest, problem: nil, packageURL: folder)
    }

    func folder(icon: String, name: String = "icon.svg") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("remote-issues-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(icon.utf8).write(to: url.appendingPathComponent(name))
        return url
    }

    func roundTrip<T: Codable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    static let jira = "sh.example.jira", linear = "sh.example.linear"
    static let coloured = ##"<svg viewBox="0 0 16 16"><defs><linearGradient id="g"><stop stop-color="#0052CC"/></linearGradient></defs><path d="M0 0h16v16H0z" fill="url(#g)"/></svg>"##
    static let plain = #"<svg viewBox="0 0 16 16"><path d="M0 0h16v16H0z" fill="currentColor"/></svg>"#

    // MARK: The protocol

    @Test func newRequestsRoundTrip() throws {
        let issue = PromptAttachment(kind: .trackerIssue, title: "Checkout retries twice", reference: "SHOP-42",
                                     url: "https://example.atlassian.net/browse/SHOP-42", tracker: Self.jira, trackerName: "Jira")
        let requests: [RemoteRequest] = [
            .issueSources(projectId: "p1", chatId: "c1", iconVersions: [Self.jira: "1.1.0"]),
            .searchIssues(projectId: "p1", chatId: nil, trackerId: Self.jira, query: "SHOP-42", searchAll: false),
            .completeIssue(issue),
            .searchCodeHost(projectId: nil, chatId: "c1", query: "retry", pullRequests: true),
        ]
        for request in requests {
            let decoded = try roundTrip(RemoteMessage.request(id: 7, request))
            guard case .request(7, let back) = decoded else { Issue.record("not a request"); continue }
            let sorted = JSONEncoder()
            sorted.outputFormatting = .sortedKeys
            #expect(try sorted.encode(back) == sorted.encode(request))
        }
        guard case .searchIssues(let project, let chat, let trackerId, let query, let all) = try roundTrip(requests[1]) else {
            Issue.record("searchIssues didn't decode"); return
        }
        #expect(project == "p1" && chat == nil && trackerId == Self.jira && query == "SHOP-42" && !all)
        guard case .completeIssue(let back) = try roundTrip(requests[2]) else { Issue.record("completeIssue didn't decode"); return }
        #expect(back == issue)
    }

    @Test func newResponsesRoundTrip() throws {
        let sources = RemoteIssueSources(trackers: [RemoteIssueTracker(id: Self.jira, title: "Jira", keyExample: "SHOP-1", version: "1.1.0",
                                                                         link: "Shop", linkKey: "SHOP", icon: Data(Self.coloured.utf8),
                                                                         iconFormat: "svg", iconIsTemplate: false)],
                                         linked: true, codeHost: "Bitbucket", githubIssues: false, pullRequests: true)
        guard case .issueSources(let back) = try roundTrip(RemoteResponse.issueSources(sources)) else { Issue.record("no sources"); return }
        #expect(back == sources)
        let group = RemoteIssueGroup(sourceId: Self.jira, title: "Jira", results: [], problem: "Jira isn't signed in on Studio.")
        guard case .issueGroups(let groups) = try roundTrip(RemoteResponse.issueGroups([group])) else { Issue.record("no groups"); return }
        #expect(groups == [group])
    }

    /// The phone only sends the new requests to a Mac that says it takes
    /// them: an older Mac would drop the connection on a request it can't read.
    @Test func snapshotSaysWhetherTheMacSearchesIssues() throws {
        let snapshot = RemoteSnapshot(projects: [], sessions: [], providers: [], alive: [], issueSearch: true)
        #expect(try roundTrip(snapshot).issueSearch == true)
        let old = try JSONDecoder().decode(RemoteSnapshot.self, from: Data(#"{"projects":[],"sessions":[],"providers":[],"alive":[]}"#.utf8))
        #expect(old.issueSearch == nil)
        // An older Mac can't read the new requests at all.
        let request = try JSONEncoder().encode(RemoteMessage.request(id: 1, .issueSources(projectId: nil, chatId: nil, iconVersions: [:])))
        #expect(String(decoding: request, as: UTF8.self).contains("issueSources"))
    }

    // MARK: Searching through the Mac

    @Test func resultsComeGroupedByTrackerWithEachProblemInASentence() async {
        let jira = tracker(Self.jira, title: "Jira"), linear = tracker(Self.linear, title: "Linear")
        let found = TrackerIssue(key: "SHOP-42", title: "Checkout retries twice", state: "In Progress",
                                 url: "https://example.atlassian.net/browse/SHOP-42", excerpt: "Twice, not once.")
        let groups = await PluginIssueTrackers.search("SHOP-42", trackers: [jira, linear]) { tracker, request in
            switch (tracker.pluginId, request) {
            case (Self.linear, .access): .access(TrackerAccess(ready: false, problem: "Enter your Linear API key in Linear's settings."))
            case (_, .access): .access(TrackerAccess(ready: true))
            case (_, .issue("SHOP-42")): .issue(found)
            default: .failed("unexpected")
            }
        }.map { RemoteIssueGroup($0, macName: "Studio") }

        #expect(groups.map(\.title) == ["Jira", "Linear"])
        #expect(groups[0].problem == nil)
        #expect(groups[0].results.map(\.reference) == ["SHOP-42"])
        #expect(groups[0].results[0].state == "In Progress")
        let attachment = groups[0].results[0].attachment
        #expect(attachment.kind == .trackerIssue && attachment.tracker == Self.jira && attachment.trackerName == "Jira")
        #expect(attachment.body == "Twice, not once.")
        #expect(groups[1].results.isEmpty)
        #expect(groups[1].problem == "Linear isn't signed in on Studio. Enter your Linear API key in Linear's settings.")
    }

    @Test func aTrackerThatFailsSaysWhyWithoutFailingTheOthers() async {
        let jira = tracker(Self.jira, title: "Jira"), linear = tracker(Self.linear, title: "Linear")
        let groups = await PluginIssueTrackers.search("retry", trackers: [jira, linear]) { tracker, request in
            if case .access = request { return .access(TrackerAccess(ready: true)) }
            return tracker.pluginId == Self.jira ? .failed("Jira didn't answer within 20 seconds.")
                : .issues([TrackerIssue(key: "ENG-7", title: "Retry the sync", url: "https://linear.app/example/issue/ENG-7")])
        }.map { RemoteIssueGroup($0, macName: "Studio") }
        #expect(groups[0].problem == "Jira didn't answer within 20 seconds.")
        #expect(groups[1].results.map(\.title) == ["Retry the sync"])
        // A signed-out tracker with nothing to add still says where.
        let silent = await PluginIssueTrackers.search("x", trackers: [jira]) { _, _ in .access(TrackerAccess(ready: false)) }
        #expect(RemoteIssueGroup(silent[0], macName: "Studio").problem == "Jira isn't signed in on Studio.")
    }

    @Test func codeHostResultsAttachAsTheMacsComposerWould() {
        let items = [ForgeItem(number: 12, title: "Derive status", url: "https://bitbucket.org/example/app/pull-requests/12",
                               state: "OPEN", body: nil, isPullRequest: true, isDraft: false, baseRefName: "main", headRefName: "status"),
                     ForgeItem(number: 13, title: "Wip", url: "https://bitbucket.org/example/app/pull-requests/13",
                               state: "OPEN", body: nil, isPullRequest: true, isDraft: true, baseRefName: nil, headRefName: nil)]
        let group = RemoteIssueGroup(codeHost: "sh.abstract.bitbucket", title: "Bitbucket", items: items)
        #expect(group.results.map(\.reference) == ["#12", "#13"])
        #expect(group.results.map(\.state) == ["Open", "Draft"])
        #expect(group.results[0].attachment.kind == .pullRequest)
        #expect(group.results[0].attachment.trackerName == "Bitbucket")
        #expect(group.results[0].attachment.details == ["Base: main", "Head: status"])
    }

    // MARK: What the composer offers

    @Test func aProjectWithNoLinkedTrackerOffersEveryTracker() throws {
        let jira = tracker(Self.jira, title: "Jira"), linear = tracker(Self.linear, title: "Linear", example: "ENG-1")
        let dir = try folder(icon: Self.plain)
        let project = ProjectIssueTrackers(available: [jira, linear], links: [:])
        let sources = RemoteIssueSources(project, installed: [installed(jira, folder: dir), installed(linear, folder: dir)])
        #expect(!sources.linked)
        #expect(sources.trackers.map(\.title) == ["Jira", "Linear"])
        #expect(sources.trackers.allSatisfy { $0.link == nil })
        #expect(sources.trackers[1].keyExample == "ENG-1")
        #expect(sources.trackers.allSatisfy { $0.iconFormat == "svg" && $0.iconIsTemplate == true })
    }

    @Test func aLinkedProjectOffersOnlyItsTrackersWithTheirLink() throws {
        let jira = tracker(Self.jira, title: "Jira"), linear = tracker(Self.linear, title: "Linear")
        let dir = try folder(icon: Self.coloured)
        let link = TrackerProjectLink(project: .init(id: "project:SHOP", name: "Shop", key: "SHOP"))
        let project = ProjectIssueTrackers(available: [jira, linear], links: [Self.jira: link])
        let sources = RemoteIssueSources(project, installed: [installed(jira, folder: dir), installed(linear, folder: dir)],
                                         codeHost: "GitHub", githubIssues: true, pullRequests: true)
        #expect(sources.linked)
        #expect(sources.trackers.map { $0.id } == [Self.jira])
        #expect(sources.trackers[0].link == "Shop")
        #expect(sources.trackers[0].linkKey == "SHOP")
        // Jira's mark keeps its colours.
        #expect(sources.trackers[0].iconIsTemplate == false)
        #expect(sources.codeHost == "GitHub" && sources.githubIssues && sources.pullRequests)
    }

    @Test func anIconTheAskerHasIsNotSentAgain() throws {
        let jira = tracker(Self.jira, title: "Jira")
        let dir = try folder(icon: Self.coloured)
        let project = ProjectIssueTrackers(available: [jira], links: [:])
        let fresh = RemoteIssueSources(project, installed: [installed(jira, folder: dir)], known: [Self.jira: "1.1.0"])
        #expect(fresh.trackers[0].icon == nil)
        #expect(fresh.trackers[0].version == "1.1.0")
        let updated = RemoteIssueSources(project, installed: [installed(jira, version: "1.2.0", folder: dir)], known: [Self.jira: "1.1.0"])
        #expect(updated.trackers[0].icon == Data(Self.coloured.utf8))
    }

    @Test func iconsThatCouldLoadSomethingAreNotSent() {
        let svg = { (body: String) in RemoteIssueTracker.safeIcon(Data(body.utf8), path: "icon.svg") }
        #expect(svg(Self.coloured) != nil)
        #expect(svg(Self.plain) != nil)
        #expect(svg(#"<svg><image href="https://example.com/x.png"/></svg>"#) == nil)
        #expect(svg(#"<svg><path fill="url(https://example.com/x)"/></svg>"#) == nil)
        #expect(svg(#"<svg><use href="https://example.com/x#a"/></svg>"#) == nil)
        #expect(svg(##"<svg><use href="#a"/></svg>"##) != nil)
        #expect(svg(#"<svg><script>alert(1)</script></svg>"#) == nil)
        #expect(svg("<svg>" + String(repeating: " ", count: RemoteIssueTracker.maxIconBytes) + "</svg>") == nil)
        #expect(RemoteIssueTracker.safeIcon(Data([0x89, 0x50, 0x4E, 0x47, 0]), path: "icon.png")?.format == "png")
        #expect(RemoteIssueTracker.safeIcon(Data("not a png".utf8), path: "icon.png") == nil)
    }
}
