import Foundation
import Testing
@testable import AbstractCore

@Suite("Turn times")
struct TurnTimeTests {
    static let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    /// A fixture's lines as a chat logged them: your message at `t0`, then
    /// each line `step` seconds after the one before.
    static func log(_ fixture: String, prompt: String = "Do it", from start: Date = t0, step: Double = 1) throws -> [OutputLine] {
        let url = try #require(Bundle.module.url(forResource: fixture, withExtension: "jsonl", subdirectory: "Fixtures"))
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        return [OutputLine(stream: .user, line: prompt, at: start)]
            + lines.enumerated().map { OutputLine(stream: .stdout, line: $1, at: start.addingTimeInterval(Double($0 + 1) * step)) }
    }

    static func recaps(_ lines: [OutputLine], provider: String) -> [TurnRecap] {
        ChatStream.timeline(lines, currentProvider: provider).blocks.compactMap { if case let .turn(_, recap) = $0 { recap } else { nil } }
    }

    static func seconds(_ ms: Int) -> String { "\(ms / 1000)s" }

    @Test func claudesTurnRunsFromYourMessageToItsResult() throws {
        let lines = try Self.log("claude-stream")
        let recaps = Self.recaps(lines, provider: "claude")
        #expect(recaps.count == 1)
        let recap = try #require(recaps.first)
        #expect(recap.outcome == .done)
        #expect(recap.start == Self.t0)
        // The result is the fixture's second-to-last line.
        #expect(recap.end == lines[lines.count - 2].at)
        #expect(recap.durationMs == 61_000)
        // What Claude reported is kept beside it.
        #expect(recap.reportedMs == 4762)
    }

    @Test func codexTurnsAreTimedToo() throws {
        let lines = try Self.log("codex-stream", step: 2)
        let recaps = Self.recaps(lines, provider: "codex")
        #expect(recaps.count == 1)
        // `turn.completed` is the seventh line after your message.
        #expect(recaps.first?.durationMs == 14_000)
        #expect(recaps.first?.label(Self.seconds) == "14s")
    }

    @Test func openCodesStepsMakeOneTurnThatEndsWhenItExits() throws {
        var lines = try Self.log("opencode-steps")
        lines.append(OutputLine(stream: .exit, line: ExitMarker(code: 0, stopped: false).line.line, at: Self.t0.addingTimeInterval(9)))
        let blocks = ChatStream.timeline(lines, currentProvider: "opencode").blocks
        let turns = blocks.compactMap { if case let .turn(_, recap) = $0 { recap } else { nil } }
        #expect(turns.count == 1)
        // Below everything the turn did.
        guard case .turn = blocks.last else { Issue.record("expected the turn's line last, got \(blocks)"); return }
        let recap = try #require(turns.first)
        #expect(recap.usage == UsageTotals(inputTokens: 300, outputTokens: 30))
        #expect(abs((recap.costUsd ?? 0) - 0.03) < 0.000_1)
        #expect(recap.durationMs == 9000)
    }

    @Test func aStoppedTurnSaysHowLongItRan() throws {
        let lines = try Self.log("codex-stream").prefix(4)
            + [OutputLine(stream: .exit, line: ExitMarker(code: 15, stopped: true).line.line, at: Self.t0.addingTimeInterval(72))]
        let recap = try #require(Self.recaps(Array(lines), provider: "codex").first)
        #expect(recap.outcome == .stopped)
        #expect(recap.label(RelativeTimeStub.duration) == "Stopped after 1m 12s")
    }

    @Test func aTurnWhoseAgentCrashedSaysItFailed() throws {
        let lines = try Self.log("claude-stream").prefix(10)
            + [OutputLine(stream: .exit, line: ExitMarker(code: 1, stopped: false).line.line, at: Self.t0.addingTimeInterval(40))]
        let blocks = ChatStream.timeline(Array(lines), currentProvider: "claude").blocks
        #expect(blocks.contains { if case .error = $0 { true } else { false } })
        guard case let .turn(_, recap)? = blocks.last else { Issue.record("expected a turn line last, got \(blocks)"); return }
        #expect(recap.label(Self.seconds) == "Failed after 40s")
    }

    @Test func aLogWithoutTimesFallsBackToWhatClaudeReported() throws {
        let lines = try Self.log("claude-stream").map { OutputLine(stream: $0.stream, line: $0.line) }
        let recap = try #require(Self.recaps(lines, provider: "claude").first)
        #expect(recap.start == nil)
        #expect(recap.durationMs == 4762)
        // Codex never reported one: nothing is guessed.
        let codex = try Self.log("codex-stream").map { OutputLine(stream: $0.stream, line: $0.line) }
        #expect(Self.recaps(codex, provider: "codex").first?.label(Self.seconds) == "—")
    }

    @Test func workingTimeLeavesOutTheTimeBetweenTurns() throws {
        let first = try Self.log("codex-stream", prompt: "One")
        let second = try Self.log("codex-stream", prompt: "Two", from: Self.t0.addingTimeInterval(3600))
        let timeline = ChatStream.timeline(first + second, currentProvider: "codex")
        let time = ChatTime(blocks: timeline.blocks, started: timeline.startedAt)
        #expect(time == ChatTime(workingMs: 14_000, turns: 2, started: Self.t0))
    }

    @Test func aTurnStillUnderWayKnowsWhenItStarted() throws {
        let lines = try Self.log("codex-stream")
        // Mid-turn: from your message, though the app that sent it has quit since.
        #expect(ChatStream.timeline(Array(lines.prefix(5)), currentProvider: "codex").turnStart == Self.t0)
        // Ended: nothing is running.
        #expect(ChatStream.timeline(lines, currentProvider: "codex").turnStart == nil)
    }

    @Test func labelsSayHowTheTurnEnded() {
        let start = Self.t0, end = Self.t0.addingTimeInterval(134)
        #expect(TurnRecap(start: start, end: end).label(RelativeTimeStub.duration) == "2m 14s")
        #expect(TurnRecap(summary: "Fixed the parser", start: start, end: end).label(RelativeTimeStub.duration)
            == "Fixed the parser · Done in 2m 14s")
        #expect(TurnRecap(outcome: .stopped).label(Self.seconds) == "Stopped")
        #expect(TurnRecap(outcome: .failed, reportedMs: 40_000).label(Self.seconds) == "Failed after 40s")
        #expect(TurnRecap().label(Self.seconds) == "—")
    }

    @Test func linesFromBeforeTimesStillDecode() throws {
        let old = try JSONDecoder().decode(OutputLine.self, from: Data(#"{"stream":"stdout","line":"hi"}"#.utf8))
        #expect(old == OutputLine(stream: .stdout, line: "hi"))
        let timed = OutputLine(stream: .user, line: "go", at: Date(timeIntervalSince1970: 1_790_000_000.123))
        let data = try JSONEncoder().encode(timed)
        #expect(String(decoding: data, as: UTF8.self).contains(#""at":1790000000123"#))
        #expect(try JSONDecoder().decode(OutputLine.self, from: data).at == timed.at)
    }

    @Test func theLogStampsEveryLineAndTheStartSurvivesARelaunch() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("turn-times-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let before = Date()
        let engine = SessionEngine(executor: LocalExecutor.shared, logDirectory: dir)
        engine.recordInput(sessionId: "s", text: "Go")
        engine.record(sessionId: "s", OutputLine(stream: .stdout, line: #"{"type":"turn.started"}"#))
        // Another Mac's line keeps that Mac's time.
        let elsewhere = Date(timeIntervalSince1970: 1_790_000_000)
        engine.record(sessionId: "s", OutputLine(stream: .note, line: "From the other Mac", at: elsewhere))
        // Relaunched: a new engine reads the same log.
        let lines = SessionEngine(executor: LocalExecutor.shared, logDirectory: dir).replay(sessionId: "s").map(\.line)
        #expect(lines.count == 3)
        #expect(lines[0].at.map { $0 >= before.addingTimeInterval(-0.001) } == true)
        #expect(lines[2].at == elsewhere)
        let start = ChatStream.timeline(lines, currentProvider: "codex").turnStart
        #expect(start != nil && start == lines[0].at)
    }
}

extension OutputLine {
    /// The line without the time it was logged, for comparing what was logged.
    var untimed: OutputLine { OutputLine(stream: stream, line: line) }
}

/// `RelativeTime.duration`'s format, which lives in the app.
enum RelativeTimeStub {
    static func duration(_ ms: Int) -> String {
        let s = ms / 1000
        if s < 60 { return "\(s)s" }
        let m = s / 60, r = s % 60
        if m < 60 { return r > 0 ? "\(m)m \(r)s" : "\(m)m" }
        return "\(m / 60)h \(m % 60)m"
    }
}
