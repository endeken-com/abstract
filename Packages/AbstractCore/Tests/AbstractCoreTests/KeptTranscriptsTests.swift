import XCTest
@testable import AbstractCore

final class KeptTranscriptsTests: XCTestCase {
    private final class Transcript {
        let chat: String
        init(_ chat: String) { self.chat = chat }
    }

    private func show(_ kept: inout KeptTranscripts<Transcript>, _ chat: String) -> (Transcript, [String]) {
        let result = kept.show(chat) { Transcript(chat) }
        return (result.transcript, result.released.map(\.chat))
    }

    func testMostRecentlyShownFirst() {
        var kept = KeptTranscripts<Transcript>(limit: 3)
        _ = show(&kept, "a")
        _ = show(&kept, "b")
        _ = show(&kept, "c")
        XCTAssertEqual(kept.order, ["c", "b", "a"])
        _ = show(&kept, "a")
        XCTAssertEqual(kept.order, ["a", "c", "b"])
    }

    func testShowingAgainHandsBackTheSameTranscript() {
        var kept = KeptTranscripts<Transcript>(limit: 3)
        let (first, _) = show(&kept, "a")
        _ = show(&kept, "b")
        let (again, released) = show(&kept, "a")
        XCTAssertTrue(first === again)
        XCTAssertEqual(released, [])
        XCTAssertTrue(kept.transcript("a") === first)
    }

    func testBoundedTheOldestFallsOff() {
        var kept = KeptTranscripts<Transcript>(limit: 2)
        _ = show(&kept, "a")
        _ = show(&kept, "b")
        let (_, released) = show(&kept, "c")
        XCTAssertEqual(released, ["a"])
        XCTAssertEqual(kept.order, ["c", "b"])
        XCTAssertNil(kept.transcript("a"))
        // Shown again after falling off: a new one.
        let (fresh, dropped) = show(&kept, "a")
        XCTAssertEqual(fresh.chat, "a")
        XCTAssertEqual(dropped, ["b"])
        XCTAssertEqual(kept.count, 2)
    }

    func testNeverMoreThanTheLimit() {
        var kept = KeptTranscripts<Transcript>(limit: 4)
        for i in 0..<50 { _ = show(&kept, "chat-\(i % 9)") }
        XCTAssertEqual(kept.count, 4)
        XCTAssertEqual(kept.order.count, Set(kept.order).count)
    }

    func testDeletedOrArchivedChatLeaves() {
        var kept = KeptTranscripts<Transcript>(limit: 4)
        _ = show(&kept, "a")
        _ = show(&kept, "b")
        _ = show(&kept, "c")
        XCTAssertEqual(kept.release("b")?.chat, "b")
        XCTAssertEqual(kept.order, ["c", "a"])
        XCTAssertNil(kept.transcript("b"))
        XCTAssertNil(kept.release("b"))
        // Chats no longer listed (a project removed, a chat archived elsewhere).
        let archived: Set = ["a"]
        let released = kept.release { !archived.contains($0) }
        XCTAssertEqual(released.map(\.chat), ["a"])
        XCTAssertEqual(kept.order, ["c"])
    }
}
