import Testing
@testable import AbstractCore

@Suite("Timeline assembly")
struct TimelineTests {
    @Test func concatenatesStreamingChunksThatShareABlock() {
        var t = Timeline()
        t.append(.text(role: .assistant, text: "Hello", blockId: "m:0", partial: true))
        t.append(.text(role: .assistant, text: " there", blockId: "m:0", partial: true))
        t.append(.text(role: .assistant, text: ", world", blockId: "m:0", partial: true))
        #expect(t.entries.count == 1)
        #expect(t.entries[0].event == .text(role: .assistant, text: "Hello there, world", blockId: "m:0", partial: true))
    }

    @Test func finalBlockReplacesStreamedTextInsteadOfDoublingIt() {
        var t = Timeline()
        t.append(.text(role: .assistant, text: "par", blockId: "m:0", partial: true))
        t.append(.text(role: .assistant, text: "tial", blockId: "m:0", partial: true))
        t.append(.text(role: .assistant, text: "partial", blockId: "m:0", partial: false))
        #expect(t.entries.count == 1)
        #expect(t.entries[0].event == .text(role: .assistant, text: "partial", blockId: "m:0", partial: false))
    }

    @Test func keepsSeparateBlocksAndKindsApart() {
        var t = Timeline()
        t.append(.text(role: .assistant, text: "A", blockId: "m:0", partial: true))
        t.append(.thinking(text: "hmm", blockId: "m:0", partial: true))
        t.append(.text(role: .assistant, text: "B", blockId: "m:1", partial: true))
        #expect(t.entries.count == 3)
    }

    @Test func entriesGetDistinctStableIds() {
        var t = Timeline()
        for _ in 0..<3 { t.append(.raw(line: "x", stream: .stdout)) }
        #expect(Set(t.entries.map(\.id)).count == 3)
    }

    @Test func blocksPairToolResultsWithTheirCallsAndGroupConsecutiveCalls() {
        var t = Timeline()
        t.append(.toolUse(id: "a", name: "Read", input: .object(["file_path": .string("/x/y.swift")]), edit: nil))
        t.append(.toolResult(toolUseId: "a", output: "42 lines", isError: false, edit: nil))
        t.append(.toolUse(id: "b", name: "Bash", input: .object(["command": .string("ls")]), edit: nil))
        t.append(.toolResult(toolUseId: "b", output: "boom", isError: true, edit: nil))
        let blocks = t.blocks
        #expect(blocks.count == 1)
        guard case let .tools(_, calls) = blocks[0] else { Issue.record("expected a tool group"); return }
        #expect(calls.map(\.id) == ["a", "b"])
        #expect(calls[0].result == ToolResult(output: "42 lines", isError: false))
        #expect(calls[1].result?.isError == true)
    }

    @Test func usageFoldsIntoThePrecedingTurnSummary() {
        var t = Timeline()
        t.append(.text(role: .assistant, text: "Done.", blockId: nil, partial: false))
        t.append(.turnEnd(durationMs: nil, costUsd: nil, usage: nil, summary: "Did the thing"))
        t.append(.usage(UsageTotals(inputTokens: 5, outputTokens: 50), costUsd: 0.2, durationMs: 1200, turns: 2))
        let blocks = t.blocks
        #expect(blocks.count == 2)
        guard case let .turn(_, summary, duration, usage, cost) = blocks[1] else { Issue.record("expected a turn"); return }
        #expect(summary == "Did the thing")
        #expect(duration == 1200)
        #expect(usage?.outputTokens == 50)
        #expect(cost == 0.2)
    }

    @Test func assistantHeaderOnlyOpensATurn() {
        var t = Timeline()
        t.append(.text(role: .user, text: "hi", blockId: nil, partial: false))
        t.append(.text(role: .assistant, text: "one", blockId: "a", partial: false))
        t.append(.toolUse(id: "t", name: "Read", input: .null, edit: nil))
        t.append(.text(role: .assistant, text: "two", blockId: "b", partial: false))
        let opens = t.blocks.compactMap { b -> Bool? in if case let .assistant(_, _, _, o) = b { return o }; return nil }
        #expect(opens == [true, false])
    }

    @Test func claudeFixtureAssemblesIntoReadableBlocks() throws {
        let url = try #require(Bundle.module.url(forResource: "claude-stream", withExtension: "jsonl", subdirectory: "Fixtures"))
        let text = try String(contentsOf: url, encoding: .utf8)
        let parser = ClaudeProvider().makeParser()
        var t = Timeline()
        for line in text.split(separator: "\n") { t.append(contentsOf: parser.feed(String(line), stream: .stdout)) }
        let blocks = t.blocks
        #expect(!blocks.contains { if case .raw = $0 { return true }; return false }, "every fixture line is understood")
        #expect(blocks.contains { if case let .tools(_, calls) = $0 { return calls.contains { $0.name == "Write" && $0.result != nil } }; return false })
        #expect(blocks.contains { if case let .assistant(_, text, _, _) = $0 { return text.contains("hi.txt made.") }; return false })
    }
}

import Foundation
