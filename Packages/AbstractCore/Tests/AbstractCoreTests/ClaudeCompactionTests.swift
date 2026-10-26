import Foundation
import Testing
@testable import AbstractCore

@Suite("Claude compaction")
struct ClaudeCompactionTests {
    static func events() throws -> [AgentEvent] {
        let url = try #require(Bundle.module.url(forResource: "claude-compact", withExtension: "jsonl", subdirectory: "Fixtures"))
        let parser = ClaudeProvider().makeParser()
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").flatMap { parser.feed(String($0), stream: .stdout) }
    }

    static func compactionEvents(_ events: [AgentEvent]) -> [CompactionEvent] {
        events.compactMap { if case let .compaction(e) = $0 { e } else { nil } }
    }

    @Test func statusCompactingStartsIt() throws {
        #expect(Self.compactionEvents(try Self.events()).first == .started(nil))
    }

    @Test func theBoundaryAndSummaryFinishIt() throws {
        let finished = Self.compactionEvents(try Self.events()).last
        #expect(finished == .finished(CompactionResult(tokensBefore: 23126, tokensAfter: 3819,
                                                       summary: "1. Primary Request and Intent:\n   The user asked for a one-word reply."),
                                      trigger: .manual, durationMs: 18056))
    }

    @Test func finishesOnceAndShowsNoMessageOfYours() throws {
        let events = try Self.events()
        #expect(Self.compactionEvents(events).count == 2)
        #expect(!events.contains { if case .text(.user, _, _, _) = $0 { true } else { false } }, "summary and the Compacted echo aren't yours")
        #expect(!events.contains { if case .raw = $0 { true } else { false } })
    }

    @Test func aResultWithoutASummaryStillFinishesIt() {
        let parser = ClaudeProvider().makeParser()
        _ = parser.feed(#"{"type":"system","subtype":"compact_boundary","compact_metadata":{"trigger":"auto","pre_tokens":100,"post_tokens":10}}"#, stream: .stdout)
        let events = parser.feed(#"{"type":"result","subtype":"success","is_error":false,"result":"","usage":{}}"#, stream: .stdout)
        #expect(events.first == .compaction(.finished(CompactionResult(tokensBefore: 100, tokensAfter: 10), trigger: .auto, durationMs: nil)))
    }

    @Test func anExitWithoutASummaryStillFinishesIt() {
        let parser = ClaudeProvider().makeParser()
        _ = parser.feed(#"{"type":"system","subtype":"compact_boundary","compact_metadata":{"trigger":"manual","pre_tokens":100}}"#, stream: .stdout)
        #expect(parser.onExit(code: 0).first == .compaction(.finished(CompactionResult(tokensBefore: 100), trigger: .manual, durationMs: nil)))
    }

    @Test func otherStatusesSayNothing() {
        let parser = ClaudeProvider().makeParser()
        #expect(parser.feed(#"{"type":"system","subtype":"status","status":"requesting"}"#, stream: .stdout) == [])
    }

    @Test func theSummaryPreambleIsDropped() {
        #expect(ClaudeParser.compactSummary("This session is being continued from a previous conversation.\n\nSummary:\nDid X.\n") == "Did X.")
        #expect(ClaudeParser.compactSummary("Just a note.") == "Just a note.")
        #expect(ClaudeParser.compactSummary("  ") == nil)
    }

    @Test func claudeCompactsInStream() {
        guard case let .inStream(prompt)? = ClaudeProvider().compaction else { Issue.record("not in-stream"); return }
        #expect(prompt == "/compact")
    }
}
