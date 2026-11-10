import Foundation
import Testing
@testable import AbstractCore

@Suite("Remote normalized transcript")
struct RemoteNormalizedTranscriptTests {
    @Test func lineCarriesPluginEventsWithoutDuplicatingRawOutput() throws {
        let source = OutputLine(stream: .stdout, line: #"{"provider":"orbit"}"#)
        let events: [AgentEvent] = [
            .raw(line: source.line, stream: .stdout),
            .text(role: .assistant, text: "Hello", blockId: "answer", partial: false),
            .toolUse(id: "orbit:1", name: "read_file", input: .object(["path": .string("README.md")]), edit: nil),
            .toolResult(toolUseId: "orbit:1", output: "Done", isError: false, edit: nil),
        ]
        let line = RemoteLine(seq: 8, line: source, events: events)
        let decoded = try JSONDecoder().decode(RemoteLine.self, from: JSONEncoder().encode(line))
        #expect(decoded.seq == 8 && decoded.line == source)
        #expect(decoded.events?.compactMap(AgentEventJSON.decode) == Array(events.dropFirst()))
    }

    @Test func rawOnlyLinesStaySequencedForSendReceipts() throws {
        let source = OutputLine(stream: .user, line: "Follow up")
        let line = RemoteLine(seq: 9, line: source, events: [.text(role: .user, text: "Follow up", blockId: nil, partial: false)])
        #expect(line.line == source)
        #expect(line.events?.first?["type"]?.string == "text")
    }

    @Test func batchesCountNormalizedEvents() {
        let source = OutputLine(stream: .stdout, line: "short")
        let event = AgentEvent.text(role: .assistant, text: String(repeating: "x", count: 800), blockId: nil, partial: false)
        let lines = (1...2).map { RemoteLine(seq: $0, line: source, events: [event]) }
        #expect(RemoteLine.batches(lines, bytes: 1_000).count == 2)
    }
}
