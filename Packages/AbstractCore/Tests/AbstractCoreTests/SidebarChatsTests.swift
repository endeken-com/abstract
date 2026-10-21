import Foundation
import Testing
import AbstractCore

@Suite struct SidebarChatsTests {
    let now = Date(timeIntervalSince1970: 1_000_000_000)

    func chat(_ id: String, _ status: SessionStatus = .idle, ago: TimeInterval = 60, pr: SidebarChats.PullRequestFacts? = nil,
              changes: Bool? = false, tasks: Int = 0, project: String? = "abstract", branch: String? = nil,
              provider: String = "claude", mac: String = "Studio", remote: Bool = false,
              pinnedAt: TimeInterval? = nil, archived: Bool = false) -> SidebarChats.Chat {
        var s = Session(id: id, projectId: project.map { "p-\($0)" }, name: id, providerId: provider, branch: branch,
                        status: status, createdAt: now.addingTimeInterval(-ago - 10), lastEventAt: now.addingTimeInterval(-ago))
        s.pinnedAt = pinnedAt.map { Date(timeIntervalSince1970: $0) }
        s.archivedAt = archived ? now : nil
        return SidebarChats.Chat(session: s, pullRequest: pr, hasChanges: changes, backgroundTasks: tasks,
                                 projectName: project, mac: mac, isRemote: remote)
    }

    func groups(_ chats: [SidebarChats.Chat]) -> [SidebarChats.Group: [String]] {
        Dictionary(uniqueKeysWithValues: SidebarChats.sections(chats, now: now).map { ($0.group, $0.chats.map(\.id)) })
    }

    // MARK: Grouping

    @Test func eachStateFindsItsGroup() {
        let g = groups([
            chat("asking", .waitingInput), chat("failed", .errored),
            chat("running", .running), chat("starting", .provisioning),
            chat("dirty", .idle, changes: true), chat("clean", .finished, changes: false),
        ])
        #expect(g[.needsYou]?.sorted() == ["asking", "failed"])
        #expect(g[.working]?.sorted() == ["running", "starting"])
        #expect(g[.readyToReview] == ["dirty"])
        #expect(g[.done] == ["clean"])
    }

    @Test func pullRequestsDecideIdleChats() {
        let g = groups([
            chat("merged", pr: .init(number: 1, state: .merged), changes: true),
            chat("closed", pr: .init(number: 2, state: .closed)),
            chat("failing", pr: .init(number: 3, state: .open, checks: .failing)),
            chat("draft", pr: .init(number: 4, state: .open, isDraft: true)),
        ])
        #expect(g[.done]?.sorted() == ["closed", "merged"], "merged wins over leftovers from a squash merge")
        #expect(g[.readyToReview]?.sorted() == ["draft", "failing"])
    }

    @Test func aRunningAgentOrBackgroundTasksOutrankItsPullRequest() {
        let g = groups([
            chat("working", .running, pr: .init(number: 5, state: .open)),
            chat("tasks", .idle, pr: .init(number: 6, state: .merged), tasks: 2),
            chat("asking", .waitingInput, pr: .init(number: 7, state: .open)),
        ])
        #expect(g[.working]?.sorted() == ["tasks", "working"])
        #expect(g[.needsYou] == ["asking"])
    }

    @Test func uncommittedOrUnknownWorkIsReadyToReview() {
        let g = groups([chat("dirty", changes: true), chat("unread", changes: nil), chat("clean", changes: false)])
        #expect(g[.readyToReview]?.sorted() == ["dirty", "unread"])
        #expect(g[.done] == ["clean"])
    }

    @Test func pinnedComeFirstInPinOrderAndArchivedLast() {
        let sections = SidebarChats.sections([
            chat("later-pin", .waitingInput, pinnedAt: 20), chat("first-pin", pinnedAt: 10),
            chat("gone", .waitingInput, pinnedAt: 5, archived: true), chat("asking", .waitingInput),
        ], now: now)
        #expect(sections.map(\.group) == [.pinned, .needsYou, .archived])
        #expect(sections[0].chats.map(\.id) == ["first-pin", "later-pin"])
        #expect(sections[2].chats.map(\.id) == ["gone"])
    }

    @Test func mostRecentlyActiveFirstAndEmptyGroupsLeftOut() {
        let sections = SidebarChats.sections([chat("old", .running, ago: 3600), chat("new", .running, ago: 5)], now: now)
        #expect(sections.map(\.group) == [.working])
        #expect(sections[0].chats.map(\.id) == ["new", "old"])
    }

    @Test func doneFoldsChatsQuietForAWeek() {
        let sections = SidebarChats.sections([
            chat("yesterday", ago: 86_400), chat("last-month", ago: 30 * 86_400), chat("six-days", ago: 6 * 86_400),
        ], now: now)
        #expect(sections.count == 1)
        #expect(sections[0].chats.map(\.id) == ["yesterday", "six-days"])
        #expect(sections[0].older.map(\.id) == ["last-month"])
    }

    @Test func chatsOnAPairedMacJoinTheSameGroups() {
        let g = groups([
            chat("here", .running),
            chat("there", .running, mac: "Mac mini", remote: true),
            chat("there-pr", pr: .init(number: 9, state: .open), changes: nil, mac: "Mac mini", remote: true),
        ])
        #expect(g[.working]?.sorted() == ["here", "there"])
        #expect(g[.readyToReview] == ["there-pr"])
    }

    // MARK: Pull request facts

    @Test func checksReadFailingThenRunningThenPassed() throws {
        func pr(_ rollup: String, decision: String = "null") throws -> SidebarChats.PullRequestFacts {
            let json = #"{"number": 3981, "title": "t", "state": "OPEN", "isDraft": false, "headRefName": "b", "baseRefName": "main", "reviewDecision": \#(decision), "statusCheckRollup": [\#(rollup)]}"#
            return SidebarChats.PullRequestFacts(try GitHubPluginHarness.decode(Data(json.utf8)))
        }
        let pass = #"{"name": "a", "status": "COMPLETED", "conclusion": "SUCCESS"}"#
        let fail = #"{"name": "b", "status": "COMPLETED", "conclusion": "FAILURE"}"#
        let run = #"{"name": "c", "status": "IN_PROGRESS", "conclusion": ""}"#
        #expect(try pr(pass).checks == .passed)
        #expect(try pr([pass, run].joined(separator: ",")).checks == .running)
        #expect(try pr([pass, run, fail].joined(separator: ",")).checks == .failing)
        #expect(try pr("").checks == nil)
        #expect(try pr(pass, decision: #""CHANGES_REQUESTED""#).changesRequested)
        #expect(try pr(pass, decision: #""APPROVED""#).changesRequested == false)
    }

    @Test func aPairedMacsPullRequestReadsTheSame() {
        let remote = RemotePullRequest(number: 12, title: "t", state: "MERGED", isDraft: false, url: nil,
                                       reviewDecision: "CHANGES_REQUESTED",
                                       checks: [RemotePullRequestCheck(name: "a", workflow: nil, outcome: "passed", url: nil),
                                                RemotePullRequestCheck(name: "b", workflow: nil, outcome: "pending", url: nil)])
        let facts = SidebarChats.PullRequestFacts(remote)
        #expect(facts == .init(number: 12, state: .merged, checks: .running, changesRequested: true))
    }

    // MARK: The second line

    @Test func secondLineShowsWhatApplies() {
        let full = chat("x", pr: .init(number: 3981, state: .open, checks: .passed, changesRequested: true), mac: "Mac mini", remote: true)
        #expect(SidebarChats.line(for: full, showProject: true).text == "abstract · #3981 · passed · changes requested · Mac mini")
        #expect(SidebarChats.line(for: full, showProject: false).text == "#3981 · passed · changes requested · Mac mini")
        #expect(SidebarChats.line(for: full, showProject: false).accessibilityText == "Pull request 3981, checks passed, changes requested, Mac mini")

        let merged = chat("m", pr: .init(number: 12, state: .merged, checks: .failing, changesRequested: true))
        #expect(SidebarChats.line(for: merged, showProject: false).text == "#12", "checks and reviews only while open")

        let fresh = chat("f")
        #expect(SidebarChats.line(for: fresh, showProject: false).isEmpty, "a fresh chat here has one line")
        #expect(SidebarChats.line(for: fresh, showProject: true).text == "abstract")
        #expect(SidebarChats.line(for: chat("s", project: nil), showProject: true).isEmpty)
    }

    @Test func openPullRequestRowsShowOnlyKnownChecksOnEitherMac() {
        for (outcome, expected) in [("passed", "passed"), ("failed", "failing"), ("pending", "running")] {
            let local = chat("local", pr: .init(number: 42, state: .open, checks: SidebarChats.PullRequestFacts.Checks(rawValue: expected)))
            let remotePR = RemotePullRequest(number: 42, title: "t", state: "OPEN", isDraft: false, url: nil,
                                             reviewDecision: nil,
                                             checks: [RemotePullRequestCheck(name: "check", workflow: nil, outcome: outcome, url: nil)])
            let remote = chat("remote", pr: .init(remotePR), mac: "Mac mini", remote: true)
            let localLine = SidebarChats.line(for: local, showProject: false)
            let remoteLine = SidebarChats.line(for: remote, showProject: false)
            #expect(localLine.checks?.rawValue == expected)
            #expect(remoteLine.checks == localLine.checks)
            #expect(localLine.accessibilityText == "Pull request 42, checks \(expected)")
            #expect(remoteLine.accessibilityText == "Pull request 42, checks \(expected), Mac mini")
        }

        let noChecks = chat("none", pr: .init(number: 42, state: .open))
        let closed = chat("closed", pr: .init(number: 42, state: .closed, checks: .passed))
        let merged = chat("merged", pr: .init(number: 42, state: .merged, checks: .failing))
        for row in [noChecks, closed, merged] {
            let line = SidebarChats.line(for: row, showProject: false)
            #expect(line.checks == nil)
            #expect(line.accessibilityText == "Pull request 42")
        }
    }

    @Test func ageReadsInTheFewestCharacters() {
        #expect(RelativeAge.short(now.addingTimeInterval(-10), now: now) == "now")
        #expect(RelativeAge.short(now.addingTimeInterval(-12 * 60), now: now) == "12m")
        #expect(RelativeAge.short(now.addingTimeInterval(-3 * 3600 - 59), now: now) == "3h")
        #expect(RelativeAge.short(now.addingTimeInterval(-2 * 86_400), now: now) == "2d")
        #expect(RelativeAge.short(now.addingTimeInterval(-15 * 86_400), now: now) == "2w")
        #expect(RelativeAge.short(now.addingTimeInterval(2 * 3600), now: now) == "in 2h")
    }

    // MARK: Search and filters

    @Test func searchMatchesTitleBranchAndPullRequestNumber() {
        let target = chat("Fix login", pr: .init(number: 3981, state: .open), branch: "abstract/oauth-callback")
        let other = chat("Tidy 3981 notes", pr: .init(number: 39812, state: .open))
        #expect(SidebarChats.matches(target, query: "3981"))
        #expect(SidebarChats.matches(target, query: "#3981"))
        #expect(SidebarChats.matches(other, query: "#3981") == false, "a number means that pull request, not a longer one")
        #expect(SidebarChats.matches(target, query: "login"))
        #expect(SidebarChats.matches(target, query: "OAUTH"))
        #expect(SidebarChats.matches(target, query: "  "))
        #expect(SidebarChats.matches(target, query: "payments") == false)
    }

    @Test func filtersNarrowByProjectAgentAndMac() {
        let here = chat("a", project: "abstract", provider: "claude", mac: "Studio")
        let there = chat("b", project: "payments-api", provider: "codex", mac: "Mac mini", remote: true)
        let loose = chat("c", project: nil, provider: "opencode")
        #expect(SidebarChats.Filter().isEmpty)
        #expect(SidebarChats.Filter().matches(here))

        let byProject = SidebarChats.Filter(projects: ["payments-api", SidebarChats.standalone])
        #expect([here, there, loose].filter(byProject.matches).map(\.id) == ["b", "c"])
        #expect([here, there, loose].filter(SidebarChats.Filter(agents: ["claude"]).matches).map(\.id) == ["a"])
        #expect([here, there, loose].filter(SidebarChats.Filter(macs: ["Mac mini"]).matches).map(\.id) == ["b"])
        #expect(SidebarChats.Filter(projects: ["abstract"], agents: ["codex"]).matches(here) == false, "every filter must pass")
    }

    @Test func filterChoicesSurviveARoundTrip() throws {
        let filter = SidebarChats.Filter(projects: ["abstract"], agents: ["codex"], macs: ["Studio"])
        #expect(try JSONDecoder().decode(SidebarChats.Filter.self, from: JSONEncoder().encode(filter)) == filter)
    }

    // MARK: Unmerged work

    @Test func unmergedWorkIsUncommittedUnpushedOrAheadOfItsBase() {
        var s = BranchState()
        #expect(s.hasUnmergedWork == false)
        s.dirty = true
        #expect(s.hasUnmergedWork)
        s = BranchState(); s.ahead = 2
        #expect(s.hasUnmergedWork, "commits origin doesn't have")
        s = BranchState(); s.aheadOfBase = 3
        #expect(s.hasUnmergedWork, "pushed, but not merged")
        s.upstreamGone = true
        #expect(s.hasUnmergedWork == false, "origin deleted the branch: its pull request merged")
    }

    // MARK: Project icons

    @Test func iconResolutionFollowsProjectSettings() {
        let uploaded = Project(name: "Alpha", rootPath: "/tmp/a", iconSymbol: "cube", iconColor: "sage", iconImagePath: "/icons/a.png")
        // This Mac: an uploaded image that is still there wins over the symbol.
        let local = SidebarChats.icon(project: uploaded, isRemote: false, remoteImage: nil, fileExists: { _ in true })
        #expect(local == .project(.init(name: "Alpha", symbol: "cube", color: "sage", imageFile: "/icons/a.png")))
        // This Mac: a missing or removed upload falls back to the symbol tile.
        let missing = SidebarChats.icon(project: uploaded, isRemote: false, remoteImage: nil, fileExists: { _ in false })
        #expect(missing == .project(.init(name: "Alpha", symbol: "cube", color: "sage")))
        // A paired Mac: the image's bytes travel in its snapshot; its file path is never read here.
        let bytes = Data([0x89, 0x50])
        let paired = SidebarChats.icon(project: uploaded, isRemote: true, remoteImage: bytes, fileExists: { _ in true })
        #expect(paired == .project(.init(name: "Alpha", symbol: "cube", color: "sage", imageData: bytes)))
        // An older paired Mac sends no bytes: the symbol tile, not a local file that happens to match.
        let older = SidebarChats.icon(project: uploaded, isRemote: true, remoteImage: nil, fileExists: { _ in true })
        #expect(older == .project(.init(name: "Alpha", symbol: "cube", color: "sage")))

        // Symbol and colour alone, and no custom choice at all (the default tile).
        let symbol = Project(name: "Beta", rootPath: "/tmp/b", iconSymbol: "bolt", iconColor: "rose")
        #expect(SidebarChats.icon(project: symbol, isRemote: false, remoteImage: nil, fileExists: { _ in false })
                == .project(.init(name: "Beta", symbol: "bolt", color: "rose")))
        let plain = Project(name: "Gamma", rootPath: "/tmp/g")
        #expect(SidebarChats.icon(project: plain, isRemote: false, remoteImage: nil, fileExists: { _ in false })
                == .project(.init(name: "Gamma")))
        // Two projects sharing an agent still resolve to their own icons.
        #expect(local != SidebarChats.icon(project: symbol, isRemote: false, remoteImage: nil, fileExists: { _ in false }))
        // A standalone chat keeps its agent's logo.
        #expect(SidebarChats.icon(project: nil, isRemote: false, remoteImage: nil, fileExists: { _ in true }) == .agentLogo)
    }

    @Test func olderPairedMacsSendNoProjectIcons() throws {
        let old = try JSONDecoder().decode(RemoteSnapshot.self, from: Data(#"{"projects":[],"sessions":[],"providers":[],"alive":[]}"#.utf8))
        #expect(old.projectIcons == nil)
        let snapshot = RemoteSnapshot(projects: [], sessions: [], providers: [], alive: [], projectIcons: ["p": Data([1, 2])])
        #expect(try JSONDecoder().decode(RemoteSnapshot.self, from: JSONEncoder().encode(snapshot)).projectIcons == ["p": Data([1, 2])])
    }

    @Test func olderPairedMacsSendNoUnmergedWork() throws {
        let old = try JSONDecoder().decode(RemoteSnapshot.self, from: Data(#"{"projects":[],"sessions":[],"providers":[],"alive":[]}"#.utf8))
        #expect(old.unmergedWork == nil)
        let snapshot = RemoteSnapshot(projects: [], sessions: [], providers: [], alive: [], unmergedWork: ["a": true, "b": false])
        #expect(try JSONDecoder().decode(RemoteSnapshot.self, from: JSONEncoder().encode(snapshot)).unmergedWork == ["a": true, "b": false])
    }
}
