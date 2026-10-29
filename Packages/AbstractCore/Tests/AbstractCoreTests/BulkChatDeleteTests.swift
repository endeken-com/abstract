import Foundation
import Testing
import AbstractCore

@Suite struct ChatSelectionTests {
    let order = ["a", "b", "c", "d", "e"]

    @Test func clickPicksOnlyThatChat() {
        let s = ChatSelection(ids: ["a", "b"], anchor: "a").clicking("d", .single, in: order)
        #expect(s.ids == ["d"])
        #expect(s.anchor == "d")
    }

    @Test func commandClickAddsAndDrops() {
        var s = ChatSelection().clicking("d", .single, in: order)
        s = s.clicking("b", .toggle, in: order)
        #expect(s.ids == ["b", "d"])
        s = s.clicking("d", .toggle, in: order)
        #expect(s.ids == ["b"])
        s = s.clicking("b", .toggle, in: order)
        #expect(s.isEmpty)
    }

    @Test func shiftClickPicksTheRunFromTheAnchor() {
        let s = ChatSelection().clicking("b", .single, in: order).clicking("d", .extend, in: order)
        #expect(s.ids == ["b", "c", "d"])
        #expect(s.anchor == "b")
        // Upward from the same anchor replaces the run.
        #expect(s.clicking("a", .extend, in: order).ids == ["a", "b"])
    }

    @Test func shiftClickWithoutAnAnchorPicksOne() {
        let s = ChatSelection().clicking("c", .extend, in: order)
        #expect(s.ids == ["c"])
        #expect(s.anchor == "c")
    }

    @Test func commandClickMovesTheAnchor() {
        let s = ChatSelection().clicking("a", .single, in: order).clicking("d", .toggle, in: order).clicking("e", .extend, in: order)
        #expect(s.ids == ["d", "e"])
    }

    @Test func selectAllPicksEveryChatInOrder() {
        let s = ChatSelection.all(order)
        #expect(s.ids == order)
        #expect(s.count == 5)
    }

    @Test func clickingAChatNotShownChangesNothing() {
        let s = ChatSelection(ids: ["a"], anchor: "a")
        #expect(s.clicking("zz", .single, in: order) == s)
    }

    @Test func keepingDropsChatsNoLongerShown() {
        let s = ChatSelection(ids: ["a", "c", "e"], anchor: "a").keeping(["b", "c", "d", "e"])
        #expect(s.ids == ["c", "e"])
        #expect(s.anchor == "c")
    }
}

@Suite struct BulkChatDeleteTests {
    /// Stands in for the app's single delete, recording what it was asked.
    actor Deleter {
        var calls: [String] = []
        let outcomes: [String: BulkChatDelete.Outcome]
        init(_ outcomes: [String: BulkChatDelete.Outcome] = [:]) { self.outcomes = outcomes }
        func delete(_ id: String) -> BulkChatDelete.Outcome {
            calls.append(id)
            return outcomes[id] ?? .deleted
        }
    }

    @Test func deletesEachChatOnceInOrderThroughTheSingleDelete() async {
        let deleter = Deleter()
        let report = await BulkChatDelete.run(["a", "b", "a", "c"]) { await deleter.delete($0) }
        #expect(await deleter.calls == ["a", "b", "c"])
        #expect(report.deleted == ["a", "b", "c"])
        #expect(report.requested == 3)
        #expect(report.isClean)
        #expect(report.summary == "Deleted 3 chats.")
    }

    @Test func oneChatReadsInTheSingular() async {
        let report = await BulkChatDelete.run(["a"]) { _ in .deleted }
        #expect(report.summary == "Deleted 1 chat.")
    }

    @Test func aFailureDoesNotStopTheRest() async {
        let deleter = Deleter(["b": .failed("Chat not found.")])
        let report = await BulkChatDelete.run(["a", "b", "c"]) { await deleter.delete($0) }
        #expect(await deleter.calls == ["a", "b", "c"])
        #expect(report.deleted == ["a", "c"])
        #expect(report.failed == ["b": "Chat not found."])
        #expect(!report.isClean)
        #expect(report.summary == "Deleted 2 of 3 chats; 1 couldn't be deleted. Chat not found.")
    }

    @Test func filesLeftBehindStillCountAsDeleted() async {
        let report = await BulkChatDelete.run(["a", "b", "c"]) { id in
            id == "a" ? .deleted : .leftFiles("Worktree not removed: busy")
        }
        #expect(report.removed == 3)
        #expect(report.leftFiles.count == 2)
        #expect(report.summary == "Deleted 3 chats. 2 worktrees or folders weren't removed. Worktree not removed: busy")
    }

    @Test func failuresAndLeftFilesTogether() async {
        let report = await BulkChatDelete.run(["a", "b", "c"]) { id in
            switch id {
            case "a": .leftFiles("Folder not removed: denied")
            case "b": .failed("That Mac is offline.")
            default: .deleted
            }
        }
        #expect(report.summary == "Deleted 2 of 3 chats; 1 couldn't be deleted. 1 worktree or folder wasn't removed. That Mac is offline.")
    }

    @Test func confirmationStatesTheCountAndThatItCannotBeUndone() {
        let many = BulkChatDelete.confirmation(count: 4)
        #expect(many.title == "Delete 4 chats?")
        #expect(many.message.contains("This can't be undone."))
        #expect(BulkChatDelete.confirmation(count: 1).title == "Delete 1 chat?")
        #expect(!many.message.contains("submodule"))
        #expect(BulkChatDelete.confirmation(count: 4, losingSubmoduleWork: 2).message.contains("2 of them have submodule commits"))
    }
}
