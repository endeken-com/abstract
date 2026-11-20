import Foundation
import Testing
import AbstractCore

/// Collapsing a chat's sub-tasks in the rail (ABS-213).
extension SidebarChatsTests {
    /// An unrelated chat, then parent ─ a ─ a1 (two levels deep) and parent ─ b, most recent first.
    var family: [SidebarChats.Chat] {
        [
            chat("other", .finished, ago: 10, changes: true),
            chat("parent", .finished, ago: 50, changes: true),
            chat("a", .finished, ago: 40, changes: true, parent: "parent"),
            chat("a1", .finished, ago: 30, changes: true, parent: "a"),
            chat("b", .finished, ago: 20, changes: true, parent: "parent"),
        ]
    }

    func order(_ chats: [SidebarChats.Chat], _ arrangement: SidebarChats.Arrangement, collapsed: Set<String>,
               narrowed: Bool = false) -> [String] {
        let hidden = SidebarChats.folding(chats, collapsed: collapsed, narrowed: narrowed).hidden
        return SidebarChats.shownOrder(chats, arrangement: arrangement, projects: ["p-abstract"], hidden: hidden)
    }

    @Test func collapsedChatsHideTheirWholeSubtreeInBothLayouts() {
        for arrangement in SidebarChats.Arrangement.allCases {
            #expect(order(family, arrangement, collapsed: []) == ["other", "parent", "b", "a", "a1"], "starts expanded")
            #expect(order(family, arrangement, collapsed: ["parent"]) == ["other", "parent"])
            #expect(order(family, arrangement, collapsed: ["a"]) == ["other", "parent", "b", "a"], "second level")
            #expect(order(family, arrangement, collapsed: ["parent", "a"]) == ["other", "parent"])
            #expect(order(family, arrangement, collapsed: ["other", "a1", "gone"]) == ["other", "parent", "b", "a", "a1"],
                    "chats without sub-tasks, and ids no longer here, hide nothing")
        }
    }

    @Test func onlyChatsWithSubtasksGetAFold() {
        let folding = SidebarChats.folding(family, collapsed: ["parent"])
        #expect(Set(folding.folds.keys) == ["parent", "a"])
        #expect(folding.folds["parent"] == SidebarChats.Fold(collapsed: true, hidden: 3))
        #expect(folding.folds["a"] == SidebarChats.Fold(collapsed: false))
        #expect(folding.hidden == ["a", "a1", "b"])
    }

    @Test func searchAndFiltersRevealHiddenSubtasksWithoutForgettingTheFold() {
        // Searching for a second-level sub-task brings its ancestors along (ABS-191).
        let found = SidebarChats.visible(family, filter: .init(), query: "a1", showArchived: false, now: now)
        #expect(found.map(\.id) == ["parent", "a", "a1"])
        let folding = SidebarChats.folding(found, collapsed: ["parent", "a"], narrowed: true)
        #expect(folding.hidden.isEmpty)
        #expect(folding.folds["parent"]?.collapsed == true, "the chevron still reads collapsed")
        #expect(order(found, .status, collapsed: ["parent", "a"], narrowed: true) == ["parent", "a", "a1"])
        #expect(order(found, .project, collapsed: ["parent", "a"], narrowed: true) == ["parent", "a", "a1"])

        // A filter that matches a hidden sub-task does the same.
        var chats = family
        chats[4] = chat("b", .finished, ago: 20, changes: true, provider: "codex", parent: "parent")
        let filtered = SidebarChats.visible(chats, filter: .init(agents: ["codex"]), query: "", showArchived: false, now: now)
        #expect(order(filtered, .status, collapsed: ["parent"], narrowed: true) == ["parent", "b"])

        // Clearing the search folds them away again.
        #expect(order(family, .status, collapsed: ["parent", "a"]) == ["other", "parent"])
    }

    @Test func aCollapsedChatSaysWhatItHides() {
        var stalled = chat("b", .running, ago: 20, parent: "parent")
        stalled.stalled = true
        let chats = [
            chat("parent", .finished, ago: 50, changes: true),
            chat("a", .finished, ago: 40, parent: "parent"),
            chat("a1", .waitingInput, ago: 30, parent: "a"),
            stalled,
            chat("c", .errored, ago: 15, parent: "parent"),
            chat("d", .idle, ago: 12, tasks: 1, parent: "parent"),
        ]
        let fold = SidebarChats.folding(chats, collapsed: ["parent"]).folds["parent"]
        #expect(fold?.needYou == 3)
        #expect(fold?.summary == "3 sub-tasks need you")
        #expect(fold?.working == true)

        let asking = SidebarChats.folding(Array(chats.prefix(3)), collapsed: ["parent"]).folds["parent"]
        #expect(asking?.summary == "1 sub-task needs you")
        #expect(asking?.working == false)

        // Expanded, or shown by a search, it says nothing: the sub-tasks speak for themselves.
        #expect(SidebarChats.folding(chats, collapsed: []).folds["parent"]?.summary == nil)
        #expect(SidebarChats.folding(chats, collapsed: ["parent"], narrowed: true).folds["parent"]?.summary == nil)
        #expect(SidebarChats.folding(Array(chats.prefix(2)), collapsed: ["parent"]).folds["parent"]?.summary == nil)
    }

    @Test func collapsingNeverMovesAChainOutOfNeedsYou() {
        let chats = [chat("parent", .finished, ago: 50, changes: true), chat("child", .waitingInput, ago: 40, parent: "parent")]
        let hidden = SidebarChats.folding(chats, collapsed: ["parent"]).hidden
        let needsYou = SidebarChats.sections(chats, now: now).first { $0.group == .needsYou }
        #expect(needsYou?.chats.map(\.id).filter { !hidden.contains($0) } == ["parent"])
    }

    @Test func openingAHiddenSubtaskUnfoldsEveryChatAboveIt() {
        let parents = ["a1": "a", "a": "parent", "b": "parent"]
        let parent = { (id: String) in parents[id] }
        #expect(SidebarChats.revealing("a1", in: ["parent", "a", "other"], parent: parent) == ["other"])
        #expect(SidebarChats.revealing("b", in: ["parent", "a"], parent: parent) == ["a"])
        #expect(SidebarChats.revealing("parent", in: ["parent"], parent: parent) == ["parent"], "its own fold stays")
        let loop = ["x": "y", "y": "x"]
        #expect(SidebarChats.revealing("x", in: ["x", "y"], parent: { loop[$0] }) == ["x"], "a looping link ends")
    }

    @Test func deletedChatsAreDroppedFromTheRememberedFolds() {
        #expect(SidebarChats.pruned(["parent", "deleted", "a"], existing: ["parent", "a", "b"]) == ["parent", "a"])
        #expect(SidebarChats.pruned([], existing: ["parent"]).isEmpty)
    }
}
