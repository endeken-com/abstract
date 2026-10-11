import Foundation
import Testing
@testable import AbstractCore

@Suite("Finding in a transcript")
struct TranscriptSearchTests {
    /// The recorded Claude stream (a Write of hi.txt, then "hi.txt made."),
    /// after a message of yours and some thinking.
    private func recorded() throws -> Timeline {
        let url = try #require(Bundle.module.url(forResource: "claude-stream", withExtension: "jsonl", subdirectory: "Fixtures"))
        let parser = ClaudeProvider().makeParser()
        var t = Timeline()
        t.append(.text(role: .user, text: "Please make HI.TXT", blockId: nil, partial: false))
        t.append(.thinking(text: "I'll write hi.txt with one line.", blockId: "th", partial: false))
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            t.append(contentsOf: parser.feed(String(line), stream: .stdout))
        }
        return t
    }

    @Test func findsInEveryKindOfTextInReadingOrder() throws {
        let blocks = try recorded().blocks
        let fields = TranscriptSearch().matches(of: "hi.txt", in: blocks).map(\.field)
        let callId = try #require(fields.compactMap { if case let .toolTitle(id) = $0 { id } else { nil } }.first)
        #expect(fields == [.user, .thinking, .toolTitle(callId: callId), .toolOutput(callId: callId), .reply])
    }

    @Test func thinkingIsSkippedWhenItIsNotShown() throws {
        let blocks = try recorded().blocks
        let fields = TranscriptSearch(includesThinking: false).matches(of: "hi.txt", in: blocks).map(\.field)
        #expect(!fields.contains(.thinking))
        #expect(fields.first == .user)
    }

    @Test func ignoresCaseAndAccentsAndCountsEachAppearance() {
        let blocks: [TimelineBlock] = [.assistant(id: 1, text: "Café, cafe and CAFE.", streaming: false, opensTurn: true)]
        let matches = TranscriptSearch().matches(of: "cafe", in: blocks)
        #expect(matches.map(\.occurrence) == [0, 1, 2])
        #expect(matches.map(\.location) == [0, 6, 15])
    }

    @Test func attachmentsUnderAMessageAreNotSearched() {
        let text = "look here\n\n<attachment kind=\"file\" label=\"report.txt\" target=\"/tmp/a/report.txt\">\nAttached file: report.txt\n</attachment>"
        let blocks: [TimelineBlock] = [.user(id: 1, text: text)]
        #expect(TranscriptSearch().matches(of: "report", in: blocks).isEmpty)
        #expect(TranscriptSearch().matches(of: "look", in: blocks).count == 1)
    }

    @Test func aFreshSearchStartsAtTheTopOfWhatIsOnScreen() {
        let blocks: [TimelineBlock] = [
            .assistant(id: 1, text: "word", streaming: false, opensTurn: true),
            .assistant(id: 5, text: "word", streaming: false, opensTurn: false),
        ]
        var find = TranscriptFind()
        find.search("word", in: blocks, using: TranscriptSearch(), from: 3)
        #expect(find.label == "2 of 2")
        find.search("word", in: blocks, using: TranscriptSearch(), from: 9)
        #expect(find.label == "1 of 2")
        find.search("nowhere", in: blocks, using: TranscriptSearch())
        #expect(find.label == "No results")
        find.search("", in: blocks, using: TranscriptSearch())
        #expect(find.label == "")
    }

    @Test func nextShowsTheFirstMatchBeforeMovingOn() throws {
        var find = TranscriptFind()
        find.search("hi.txt", in: try recorded().blocks, using: TranscriptSearch())
        #expect(find.label == "1 of 5")
        #expect(!find.shown)
        #expect(find.next()?.field == .user)
        #expect(find.shown)
        #expect(find.next()?.field == .thinking)
        #expect(find.previous()?.field == .user)
        #expect(find.previous()?.field == .reply)
        #expect(find.label == "5 of 5")
        #expect(find.next()?.field == .user)
    }

    @Test func matchesStreamingInJoinWithoutMovingTheCurrentOne() throws {
        var timeline = try recorded()
        let search = TranscriptSearch()
        var find = TranscriptFind()
        find.search("hi.txt", in: timeline.blocks, using: search)
        find.next()
        find.next()
        #expect(find.label == "2 of 5")
        let before = find.currentMatch

        // The agent replies again, a chunk at a time.
        timeline.append(.text(role: .assistant, text: "Checking hi", blockId: "m:9", partial: true))
        find.refresh(timeline.blocks, using: search)
        #expect(find.label == "2 of 5")
        timeline.append(.text(role: .assistant, text: ".txt again: hi.txt is there.", blockId: "m:9", partial: true))
        find.refresh(timeline.blocks, using: search)
        #expect(find.label == "2 of 7")
        #expect(find.currentMatch == before)
        #expect(find.shown)
        #expect(find.matches.suffix(2).map(\.occurrence) == [0, 1])
    }

    @Test func whenTheCurrentMatchGoesTheNearestTakesItsPlace() {
        let search = TranscriptSearch()
        var find = TranscriptFind()
        find.search("x", in: [.assistant(id: 1, text: "x x x", streaming: true, opensTurn: true)], using: search)
        find.next(); find.next(); find.next()
        #expect(find.label == "3 of 3")
        // Markdown resolving can shrink a streaming reply.
        find.refresh([.assistant(id: 1, text: "x x", streaming: true, opensTurn: true)], using: search)
        #expect(find.label == "2 of 2")
        #expect(!find.shown)
        find.refresh([], using: search)
        #expect(find.label == "No results")
        #expect(find.next() == nil)
    }

    @Test func toolCallsAreFoundByTheirCommandAndOutput() {
        let call = ToolCall(id: "c", name: "Bash", input: .object(["command": .string("swift test")]),
                            result: ToolResult(output: "Test run passed", isError: false))
        let matches = TranscriptSearch().matches(of: "test", in: [.tools(id: 2, calls: [call])])
        #expect(matches.map(\.field) == [.toolTitle(callId: "c"), .toolOutput(callId: "c")])
        #expect(matches.allSatisfy { $0.block == 2 })
    }
}
