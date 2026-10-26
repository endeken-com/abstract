import Foundation
import Testing
@testable import AbstractCore

private func blocks(_ events: [AgentEvent]) -> [TimelineBlock] {
    var timeline = Timeline()
    timeline.append(contentsOf: events)
    return timeline.blocks
}

private func compactions(_ blocks: [TimelineBlock]) -> [(CompactionTrigger, CompactionState)] {
    blocks.compactMap { if case let .compaction(_, trigger, state) = $0 { (trigger, state) } else { nil } }
}

@Suite("Compaction markers")
struct CompactionMarkerTests {
    @Test func roundTripsThroughALogLine() {
        let marker = CompactionMarker.finished(CompactionResult(tokensBefore: 19776, tokensAfter: 5061, contextWindow: 258_400),
                                               trigger: .manual, durationMs: 4939)
        #expect(marker.line.stream == .compaction)
        #expect(CompactionMarker(marker.line) == marker)
    }

    @Test func ignoresOtherLines() {
        #expect(CompactionMarker(OutputLine(stream: .stdout, line: "{}")) == nil)
        #expect(CompactionMarker(OutputLine(stream: .compaction, line: "not json")) == nil)
    }

    @Test func becomesTheMatchingEvent() {
        #expect(CompactionMarker.started(.manual).event == .compaction(.started(.manual)))
        #expect(CompactionMarker.failed("boom").event == .compaction(.failed("boom")))
    }

    @Test func aChatStreamReadsMarkersBeforeAnyParser() {
        let stream = ChatStream(providerId: "codex")
        #expect(stream.feed(CompactionMarker.started(.manual).line) == [.compaction(.started(.manual))])
    }
}

@Suite("Compaction in the timeline")
struct CompactionTimelineTests {
    let result = CompactionResult(tokensBefore: 23126, tokensAfter: 3819, summary: "Did X.")

    @Test func startedThenFinishedIsOneDoneRow() {
        let rows = compactions(blocks([.compaction(.started(.manual)), .compaction(.finished(result, trigger: .manual, durationMs: 18056))]))
        #expect(rows.count == 1)
        #expect(rows.first?.0 == .manual)
        #expect(rows.first?.1 == .done(result, durationMs: 18056))
    }

    @Test func aSecondStartWhileRunningIsTheSameRow() {
        // Abstract logs a start, then Claude says `status: compacting`.
        let rows = compactions(blocks([.compaction(.started(.manual)), .compaction(.started(nil)),
                                       .compaction(.finished(result, trigger: .manual, durationMs: nil))]))
        #expect(rows.count == 1)
        #expect(rows.first?.0 == .manual)
    }

    @Test func claudesOwnStartIsAutoUntilItSaysOtherwise() {
        #expect(compactions(blocks([.compaction(.started(nil))])).first?.0 == .auto)
        let rows = compactions(blocks([.compaction(.started(nil)), .compaction(.finished(result, trigger: .manual, durationMs: nil))]))
        #expect(rows.first?.0 == .manual)
    }

    @Test func stillRunningWhenTheTurnEndsIsFailed() {
        let rows = compactions(blocks([
            .compaction(.started(.manual)),
            .usage(UsageTotals(inputTokens: 1, outputTokens: 1, cacheRead: 0, cacheWrite: 0), costUsd: nil, durationMs: nil, turns: nil),
        ]))
        #expect(rows.first?.1 == .failed(CompactionState.stoppedEarly))
    }

    @Test func stillRunningWhenAnErrorArrivesIsFailedAndTheErrorShows() {
        let out = blocks([.compaction(.started(.manual)), .error("Prompt is too long")])
        #expect(compactions(out).first?.1 == .failed(CompactionState.stoppedEarly))
        #expect(out.contains { if case .error(_, "Prompt is too long") = $0 { true } else { false } })
    }

    @Test func theEmptyTurnAfterACompactionHasNoRule() {
        let out = blocks([
            .compaction(.started(.manual)),
            .system(model: "haiku", cwd: nil, permissionMode: nil, sessionId: "s"),
            .compaction(.finished(result, trigger: .manual, durationMs: nil)),
            .usage(UsageTotals(inputTokens: 0, outputTokens: 0, cacheRead: 0, cacheWrite: 0), costUsd: 0, durationMs: 18000, turns: 1),
            .status(.idle, detail: nil),
        ])
        #expect(!out.contains { if case .turn = $0 { true } else { false } })
    }

    @Test func autoCompactionMidTurnKeepsTheTurnRule() {
        let out = blocks([
            .text(role: .user, text: "go", blockId: nil, partial: false),
            .compaction(.started(nil)),
            .compaction(.finished(result, trigger: .auto, durationMs: nil)),
            .text(role: .assistant, text: "Carrying on.", blockId: "m:0", partial: false),
            .usage(UsageTotals(inputTokens: 1, outputTokens: 1, cacheRead: 0, cacheWrite: 0), costUsd: nil, durationMs: 1000, turns: 1),
        ])
        #expect(compactions(out).first?.0 == .auto)
        #expect(out.contains { if case .turn = $0 { true } else { false } })
    }

    @Test func aFinishWithNoStartStillShows() {
        // A side channel's markers, if the start line was lost.
        #expect(compactions(blocks([.compaction(.finished(result, trigger: nil, durationMs: 4000))])).count == 1)
    }

    @Test func knowsWhenOneIsStillRunning() {
        var timeline = Timeline()
        timeline.append(.compaction(.started(.manual)))
        #expect(timeline.hasRunningCompaction)
        timeline.append(.compaction(.failed("x")))
        #expect(!timeline.hasRunningCompaction)
    }

    @Test func aTranscriptForTheNextAgentSkipsIt() {
        let text = HandoffTranscript.render(blocks: blocks([.compaction(.finished(result, trigger: .manual, durationMs: nil))]),
                                            agentName: "Claude Code", name: { $0 })
        #expect(!text.contains("Did X."))
    }
}
