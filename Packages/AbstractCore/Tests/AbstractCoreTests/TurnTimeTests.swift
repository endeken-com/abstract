import Foundation
import Testing
@testable import AbstractCore

/// How long each turn took, read from a log with times, for every agent.
@Suite("Turn times")
struct TurnTimeTests {
    static let start = Date(timeIntervalSince1970: 1_790_000_000)

    static func fixture(_ name: String) throws -> [String] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    /// Your message, then the agent's lines a second apart, as the log keeps them.
    static func log(_ message: String, _ lines: [String], from: Date = start) -> [OutputLine] {
        [OutputLine(stream: .user, line: message, at: from)]
            + lines.enumerated().map { OutputLine(stream: .stdout, line: $1, at: from.addingTimeInterval(Double($0 + 1))) }
    }

    static func turns(_ blocks: [TimelineBlock]) -> [TurnInfo] {
        blocks.compactMap { if case let .turn(_, info) = $0 { info } else { nil } }
    }

    @Test func aClaudeTurnRunsFromYourMessageToItsResult() throws {
        let lines = try Self.fixture("claude-stream")
        let blocks = ChatStream.timeline(Self.log("make hi.txt", lines), currentProvider: "claude").blocks
        let turns = Self.turns(blocks)
        #expect(turns.count == 1)
        let turn = try #require(turns.first)
        // The result is the second-to-last line; the task summary after it isn't the turn.
        #expect(turn.measuredMs == (lines.count - 1) * 1000)
        #expect(turn.durationMs == turn.measuredMs)
        #expect(turn.reportedMs == 4762)
        #expect(turn.summary == "hi.txt created")
        #expect(turn.ending == .done)
    }

    @Test func aCodexTurnGetsItsLengthToo() throws {
        let lines = try Self.fixture("codex-stream")
        let blocks = ChatStream.timeline(Self.log("list files", lines), currentProvider: "codex").blocks
        let turns = Self.turns(blocks)
        #expect(turns.count == 1)
        #expect(turns.first?.durationMs == lines.count * 1000)
        #expect(turns.first?.usage != nil)
        guard case .turn? = blocks.last else { Issue.record("the turn's line comes last: \(blocks)"); return }
    }

    static func openCodeTurn(_ n: Int) -> [String] { [
        #"{"type":"step_start","sessionID":"ses_a","part":{"type":"step-start"}}"#,
        #"{"type":"text","sessionID":"ses_a","part":{"id":"a\#(n)","type":"text","text":"Looking."}}"#,
        #"{"type":"step_finish","sessionID":"ses_a","part":{"type":"step-finish","tokens":{"input":10,"output":2,"cache":{"read":3,"write":0}},"cost":0.01}}"#,
        #"{"type":"step_start","sessionID":"ses_a","part":{"type":"step-start"}}"#,
        #"{"type":"text","sessionID":"ses_a","part":{"id":"b\#(n)","type":"text","text":"Done."}}"#,
        #"{"type":"step_finish","sessionID":"ses_a","part":{"type":"step-finish","tokens":{"input":20,"output":4,"cache":{"read":0,"write":0}},"cost":0.02}}"#,
    ] }

    @Test func openCodeStepsMakeOneLinePerTurn() throws {
        let log = Self.log("look", Self.openCodeTurn(1))
            + Self.log("again", Self.openCodeTurn(2), from: Self.start.addingTimeInterval(60))
        let blocks = ChatStream.timeline(log, currentProvider: "opencode").blocks
        let turns = Self.turns(blocks)
        #expect(turns.count == 2)
        #expect(turns.map(\.durationMs) == [6000, 6000])
        #expect(turns.first?.usage == UsageTotals(inputTokens: 30, outputTokens: 6, cacheRead: 3))
        #expect(abs((turns.first?.costUsd ?? 0) - 0.03) < 1e-9)
        // Each line sits after its turn's replies, before your next message.
        let kinds = blocks.map { block -> String in
            switch block {
            case .user: "user"
            case .assistant: "reply"
            case .turn: "turn"
            default: "other"
            }
        }
        #expect(kinds == ["user", "reply", "reply", "turn", "user", "reply", "reply", "turn"])
    }

    @Test func aStoppedTurnSaysHowLongItRan() {
        var t = Timeline()
        t.append(.text(role: .user, text: "go", blockId: nil, partial: false), at: Self.start)
        t.append(.toolUse(id: "a", name: "Bash", input: .null, edit: nil), at: Self.start.addingTimeInterval(2))
        t.append(contentsOf: TurnStop.events, at: Self.start.addingTimeInterval(72))
        let turn = Self.turns(t.blocks).first
        #expect(turn?.ending == .stopped)
        #expect(turn?.durationMs == 72_000)
    }

    @Test func aFailedTurnSaysHowLongItRan() {
        let parser = CodexProvider().makeParser()
        var t = Timeline()
        t.append(.text(role: .user, text: "go", blockId: nil, partial: false), at: Self.start)
        t.append(.text(role: .assistant, text: "On it.", blockId: "m", partial: false), at: Self.start.addingTimeInterval(1))
        t.append(contentsOf: parser.onExit(code: 1), at: Self.start.addingTimeInterval(40))
        let blocks = t.blocks
        guard case let .turn(_, turn)? = blocks.last else { Issue.record("expected a closing line: \(blocks)"); return }
        #expect(turn.ending == .failed)
        #expect(turn.durationMs == 40_000)
        #expect(blocks.contains { if case .error = $0 { true } else { false } })
    }

    @Test func aTurnCutOffByARelaunchStillShowsItsLength() {
        // Codex was ended before it finished; nothing logged its end.
        var t = Timeline()
        t.append(.text(role: .user, text: "go", blockId: nil, partial: false), at: Self.start)
        t.append(.toolUse(id: "a", name: "Bash", input: .null, edit: nil), at: Self.start.addingTimeInterval(1))
        t.append(.toolResult(toolUseId: "a", output: "", isError: false, edit: nil), at: Self.start.addingTimeInterval(9))
        t.append(.text(role: .user, text: "again", blockId: nil, partial: false), at: Self.start.addingTimeInterval(100))
        let turns = Self.turns(t.blocks)
        #expect(turns.map(\.durationMs) == [9000])
        // The second turn is under way: its start is the timer's.
        #expect(t.turnStartedAt == Self.start.addingTimeInterval(100))
    }

    @Test func anErrorBetweenTurnsIsNotATurn() {
        var t = Timeline()
        t.append(.text(role: .user, text: "go", blockId: nil, partial: false), at: Self.start)
        t.append(.usage(.zero, costUsd: nil, durationMs: nil, turns: 1), at: Self.start.addingTimeInterval(3))
        t.append(.status(.idle, detail: nil), at: Self.start.addingTimeInterval(3))
        t.append(.error("The agent refused the request."), at: Self.start.addingTimeInterval(20))
        t.append(.text(role: .user, text: "next", blockId: nil, partial: false), at: Self.start.addingTimeInterval(30))
        #expect(Self.turns(t.blocks).map(\.durationMs) == [3000])
    }

    @Test func aLogWithoutTimesFallsBackToClaudesOwnDuration() throws {
        let log = try [OutputLine(stream: .user, line: "make hi.txt")]
            + Self.fixture("claude-stream").map { OutputLine(stream: .stdout, line: $0) }
        let turns = Self.turns(ChatStream.timeline(log, currentProvider: "claude").blocks)
        #expect(turns.count == 1)
        #expect(turns.first?.measuredMs == nil)
        #expect(turns.first?.durationMs == 4762)
    }

    @Test func aLogWithoutTimesShowsNothingItCantKnow() throws {
        let log = try [OutputLine(stream: .user, line: "list files")]
            + Self.fixture("codex-stream").map { OutputLine(stream: .stdout, line: $0) }
        let turns = Self.turns(ChatStream.timeline(log, currentProvider: "codex").blocks)
        #expect(turns.count == 1)
        #expect(turns.first?.durationMs == nil)
    }

    @Test func totalWorkingTimeLeavesOutTheTimeBetweenTurns() throws {
        let lines = try Self.fixture("codex-stream")
        // An hour waiting for you between the two turns.
        let log = Self.log("one", lines) + Self.log("two", lines, from: Self.start.addingTimeInterval(3600))
        let time = ChatTime(ChatStream.timeline(log, currentProvider: "codex").blocks)
        #expect(time.turns == 2)
        #expect(time.workingMs == 2 * lines.count * 1000)
    }

    @Test func aTurnTheAgentTakesOnItsOwnStartsAtItsFirstStep() throws {
        // Claude takes another turn as a background task ends, with no message of yours.
        var t = Timeline()
        t.append(.text(role: .user, text: "go", blockId: nil, partial: false), at: Self.start)
        t.append(.usage(.zero, costUsd: nil, durationMs: 3000, turns: 1), at: Self.start.addingTimeInterval(3))
        t.append(.status(.idle, detail: nil), at: Self.start.addingTimeInterval(3))
        t.append(.task(.finished(taskId: "b", status: .completed, summary: nil, outputFile: nil, usage: nil)), at: Self.start.addingTimeInterval(50))
        t.append(.text(role: .assistant, text: "The tests passed.", blockId: "m2", partial: false), at: Self.start.addingTimeInterval(52))
        t.append(.usage(.zero, costUsd: nil, durationMs: 2500, turns: 1), at: Self.start.addingTimeInterval(55))
        t.append(.status(.idle, detail: nil), at: Self.start.addingTimeInterval(55))
        #expect(Self.turns(t.blocks).map(\.durationMs) == [3000, 3000])
        #expect(t.turnStartedAt == nil)
    }

    @Test func theTurnUnderWayIsFoundFromTheLogAfterARelaunch() throws {
        let lines = Array(try Self.fixture("claude-stream").prefix(20))
        // Read back from the log, as after a relaunch: no result yet.
        let timeline = ChatStream.timeline(Self.log("make hi.txt", lines), currentProvider: "claude")
        #expect(timeline.turnStartedAt == Self.start)
        #expect(Self.turns(timeline.blocks).isEmpty)
    }

    @Test func oldLogLinesWithoutTimesStillDecode() throws {
        let old = try JSONDecoder().decode(OutputLine.self, from: Data(#"{"stream":"stdout","line":"hi"}"#.utf8))
        #expect(old == OutputLine(stream: .stdout, line: "hi"))
        #expect(old.at == nil)
        let stamped = OutputLine(stream: .user, line: "go", at: Self.start)
        let back = try JSONDecoder().decode(OutputLine.self, from: JSONEncoder().encode(stamped))
        #expect(back.at == Self.start)
    }

    @Test func theEngineStampsEveryLineItLogs() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = SessionEngine(executor: LocalExecutor(), logDirectory: dir)
        let before = Date()
        engine.recordInput(sessionId: "s", text: "go")
        let at = try #require(engine.replay(sessionId: "s").first?.line.at)
        #expect(at >= before.addingTimeInterval(-1) && at <= Date().addingTimeInterval(1))
    }
}
