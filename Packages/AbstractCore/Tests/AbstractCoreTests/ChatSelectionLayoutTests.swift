import Foundation
import Testing
import AbstractCore

/// Picking any chats in either layout (ABS-206): the order the rail shows,
/// and clicks over it.
@Suite struct ChatSelectionLayoutTests {
    let now = Date()

    func chat(_ id: String, _ status: SessionStatus = .idle, ago: TimeInterval = 60, project: String? = "a",
              pinned: Bool = false, archived: Bool = false, remote: Bool = false, pr: PullRequest.State? = nil) -> SidebarChats.Chat {
        var s = Session(id: id, projectId: project, name: id, providerId: "claude", status: status,
                        createdAt: now.addingTimeInterval(-ago - 10), lastEventAt: now.addingTimeInterval(-ago))
        s.pinnedAt = pinned ? now.addingTimeInterval(-ago) : nil
        s.archivedAt = archived ? now : nil
        return SidebarChats.Chat(session: s, pullRequest: pr.map { .init(number: 1, state: $0) }, hasChanges: false,
                                 isRemote: remote)
    }

    /// Two projects, a standalone chat, active and archived ones.
    var chats: [SidebarChats.Chat] {
        [chat("a1", .running, ago: 10), chat("a2", ago: 20), chat("b1", .waitingInput, ago: 30, project: "b"),
         chat("b2", ago: 40, project: "b", archived: true), chat("s1", ago: 50, project: nil), chat("a3", ago: 60, archived: true)]
    }

    @Test func byProjectTheOrderFollowsProjectsThenStandaloneThenPairedMacs() {
        let order = SidebarChats.shownOrder(chats, arrangement: .project, projects: ["b", "a"], remote: ["mirror-1"])
        #expect(order == ["b1", "b2", "a1", "a2", "a3", "s1", "mirror-1"])
    }

    @Test func byProjectAFoldedProjectsChatsArentShown() {
        let order = SidebarChats.shownOrder(chats, arrangement: .project, projects: ["a", "b"], collapsed: ["a"])
        #expect(order == ["b1", "b2", "s1"])
    }

    @Test func byStatusTheOrderFollowsTheGroups() {
        let order = SidebarChats.shownOrder(chats, arrangement: .status)
        // Needs you, Working, Done, then Archived.
        #expect(order == ["b1", "a1", "a2", "s1", "b2", "a3"])
    }

    @Test func commandClickPicksActiveChatsInTwoProjects() {
        let order = SidebarChats.shownOrder(chats, arrangement: .project, projects: ["a", "b"])
        let picked = ChatSelection().clicking("a1", .toggle, in: order).clicking("a2", .toggle, in: order).clicking("b1", .toggle, in: order)
        #expect(picked.ids == ["a1", "a2", "b1"])
    }

    @Test func shiftClickExtendsWithinAGroup() {
        let order = SidebarChats.shownOrder(chats, arrangement: .project, projects: ["a", "b"])
        let picked = ChatSelection().clicking("a1", .single, in: order).clicking("a3", .extend, in: order)
        #expect(picked.ids == ["a1", "a2", "a3"], "active and archived alike")
    }

    @Test func shiftClickRunsAcrossGroupsInShownOrder() {
        let order = SidebarChats.shownOrder(chats, arrangement: .project, projects: ["a", "b"])
        let picked = ChatSelection().clicking("a3", .single, in: order).clicking("b1", .extend, in: order)
        #expect(picked.ids == ["a3", "b1"])
    }

    @Test func selectAllPicksEveryChatShown() {
        let order = SidebarChats.shownOrder(chats, arrangement: .project, projects: ["a", "b"], collapsed: ["b"])
        #expect(ChatSelection.all(order).ids == ["a1", "a2", "a3", "s1"])
    }

    @Test func switchingLayoutKeepsPicksStillShown() {
        let project = SidebarChats.shownOrder(chats, arrangement: .project, projects: ["a", "b"])
        let picked = ChatSelection.all(project)
        let status = SidebarChats.shownOrder(chats.filter { $0.session.archivedAt == nil }, arrangement: .status)
        #expect(picked.keeping(status).ids == ["b1", "a1", "a2", "s1"])
    }
}

@Suite struct BulkChatActionTests {
    let items = [
        BulkChatAction.Item(id: "a", archived: false, pinned: false, working: true),
        BulkChatAction.Item(id: "b", archived: false, pinned: true),
        BulkChatAction.Item(id: "c", archived: true, pinned: false),
        BulkChatAction.Item(id: "d", archived: false, pinned: false, remote: true),
        BulkChatAction.Item(id: "e", archived: false, pinned: false),
    ]

    @Test func archiveFitsOnlyActiveChats() {
        #expect(BulkChatAction.archive.targets(items) == ["a", "b", "d", "e"])
        #expect(BulkChatAction.archive.title(for: items) == "Archive 4 of 5")
        #expect(BulkChatAction.unarchive.title(for: items) == "Unarchive 1 of 5")
    }

    @Test func pinsAreThisMacsOnly() {
        #expect(BulkChatAction.pin.targets(items) == ["a", "c", "e"])
        #expect(BulkChatAction.unpin.targets(items) == ["b"])
    }

    @Test func deleteFitsEveryChat() {
        #expect(BulkChatAction.delete.targets(items) == ["a", "b", "c", "d", "e"])
        #expect(BulkChatAction.delete.title(for: items) == "Delete 5 Chats…")
    }

    @Test func titlesForOneAndForAll() {
        #expect(BulkChatAction.archive.title(fitting: 1, of: 1) == "Archive")
        #expect(BulkChatAction.archive.title(fitting: 3, of: 3) == "Archive 3 Chats")
        #expect(BulkChatAction.archive.title(fitting: 3, of: 5) == "Archive 3 of 5")
    }

    @Test func offeredActionsFitAtLeastOneChat() {
        let active = [BulkChatAction.Item(id: "a", archived: false, pinned: false), .init(id: "b", archived: false, pinned: false)]
        #expect(BulkChatAction.offered(active) == [.archive, .pin, .delete])
        #expect(BulkChatAction.offered(items) == BulkChatAction.allCases)
    }

    @Test func archiveAsksOnceAndSaysWhoStops() {
        let text = BulkChatAction.archiveConfirmation(count: 3, working: 2)
        #expect(text.title == "Archive 3 chats?")
        #expect(text.message.contains("2 of them are working; their agents will be stopped."))
        #expect(!BulkChatAction.archiveConfirmation(count: 3, working: 0).message.contains("working"))
    }

    @Test func workingMeansRunningNotJustAlive() {
        let idle = Session(id: "x", projectId: nil, name: "x", providerId: "claude", status: .idle)
        let running = Session(id: "y", projectId: nil, name: "y", providerId: "claude", status: .running)
        #expect(!BulkChatAction.Item(idle).working)
        #expect(BulkChatAction.Item(running).working)
    }
}

@Suite struct ChatCleanupTests {
    let now = Date()

    func facts(_ id: String, days: Double, _ status: SessionStatus = .finished, pinned: Bool = false, tasks: Int = 0,
               pr: PullRequest.State? = nil, commits: Int? = 0, files: Int? = 0, archived: Bool = false) -> ChatCleanup.Facts {
        var s = Session(id: id, projectId: "p", name: id, providerId: "claude", status: status,
                        createdAt: now.addingTimeInterval(-days * 86_400 - 60), lastEventAt: now.addingTimeInterval(-days * 86_400))
        s.pinnedAt = pinned ? now : nil
        s.archivedAt = archived ? now : nil
        return ChatCleanup.Facts(session: s, backgroundTasks: tasks, pullRequest: pr, pullRequestNumber: pr == nil ? nil : 42,
                                 unpushedCommits: commits, uncommittedFiles: files)
    }

    @Test func onlyChatsOlderThanTheCutoffAreListedOldestFirst() {
        let list = ChatCleanup.candidates([facts("new", days: 3), facts("old", days: 20), facts("older", days: 40),
                                           facts("edge", days: 13.9)], olderThan: .twoWeeks, now: now)
        #expect(list.map(\.id) == ["older", "old"])
        #expect(ChatCleanup.candidates([facts("a", days: 8)], olderThan: .oneWeek, now: now).count == 1)
        #expect(ChatCleanup.candidates([facts("a", days: 40)], olderThan: .threeMonths, now: now).isEmpty)
    }

    @Test func archivedChatsAreIncluded() {
        let list = ChatCleanup.candidates([facts("a", days: 20, archived: true)], olderThan: .twoWeeks, now: now)
        #expect(list.map(\.id) == ["a"])
        #expect(list[0].reason == nil)
    }

    @Test func eachExclusionHasItsReason() {
        let list = ChatCleanup.candidates([
            facts("pinned", days: 30, pinned: true),
            facts("working", days: 30, .running),
            facts("tasks", days: 30, tasks: 1),
            facts("waiting", days: 30, .waitingInput),
            facts("pr", days: 30, pr: .open),
            facts("merged", days: 30, pr: .merged),
            facts("unpushed", days: 30, commits: 2),
            facts("dirty", days: 30, files: 1),
            facts("plain", days: 30),
        ], olderThan: .twoWeeks, now: now)
        let reasons = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0.reason?.text) })
        #expect(reasons["pinned"] == "Pinned")
        #expect(reasons["working"] == "Working")
        #expect(reasons["tasks"] == "Working")
        #expect(reasons["waiting"] == "Waiting on you")
        #expect(reasons["pr"] == "Pull request #42 is open")
        #expect(reasons["merged"] == .some(nil))
        #expect(reasons["unpushed"] == "2 commits never pushed")
        #expect(reasons["dirty"] == "1 uncommitted change")
        #expect(reasons["plain"] == .some(nil))
        #expect(ChatCleanup.toDelete(list).sorted() == ["merged", "plain"])
    }

    @Test func keptChatsGoWhenTicked() {
        let list = ChatCleanup.candidates([facts("pinned", days: 30, pinned: true), facts("plain", days: 30)], olderThan: .twoWeeks, now: now)
        #expect(ChatCleanup.toDelete(list) == ["plain"])
        #expect(ChatCleanup.toDelete(list, including: ["pinned"]) == ["pinned", "plain"])
    }

    @Test func summarySaysHowMuchWasFreed() {
        #expect(ChatCleanup.summary(deleted: 1, freed: 0) == "Deleted 1 chat.")
        let text = ChatCleanup.summary(deleted: 14, freed: 21_000_000_000)
        #expect(text.hasPrefix("Deleted 14 chats, freed 21"))
        #expect(text.hasSuffix("GB."))
    }
}
