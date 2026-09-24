import Foundation
import Testing
@testable import AbstractCore

private enum Lines {
    static let claudeReply = #"{"type":"assistant","message":{"id":"m1","role":"assistant","content":[{"type":"text","text":"Claude did the first part."}]}}"#
    static let claudeResult = #"{"type":"result","subtype":"success","is_error":false,"result":"done","usage":{"input_tokens":1,"output_tokens":1}}"#
    static let codexReply = #"{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"Codex carried on."}}"#
    static let codexDone = #"{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}"#

    static func out(_ line: String) -> OutputLine { OutputLine(stream: .stdout, line: line) }
    static func user(_ text: String) -> OutputLine { OutputLine(stream: .user, line: text) }
}

@Suite("Handoff markers")
struct HandoffMarkerTests {
    @Test func roundTripsThroughALogLine() {
        let marker = HandoffMarker(phase: .handoff, from: "claude", to: "codex", summary: "Did X", source: .app,
                                   transcriptPath: "/tmp/t.md")
        let line = marker.line
        #expect(line.stream == .handoff)
        #expect(HandoffMarker(line) == marker)
    }

    @Test func ignoresOtherLines() {
        #expect(HandoffMarker(Lines.out("{}")) == nil)
        #expect(HandoffMarker(OutputLine(stream: .handoff, line: "not json")) == nil)
    }

    @Test func logLinesStillDecodeWithTheNewStream() throws {
        let data = try JSONEncoder().encode(HandoffMarker(phase: .summarize, from: "claude", to: "codex").line)
        let decoded = try JSONDecoder().decode(OutputLine.self, from: data)
        #expect(decoded.stream == .handoff)
    }
}

@Suite("Chat stream")
struct ChatStreamTests {
    let handoff = HandoffMarker(phase: .handoff, from: "claude", to: "codex", summary: "Claude did the first part.", source: .agent)

    @Test func eachAgentsOutputIsParsedByItsOwnParser() {
        let lines = [Lines.user("start"), Lines.out(Lines.claudeReply), Lines.out(Lines.claudeResult),
                     handoff.line, Lines.user("go on"), Lines.out(Lines.codexReply), Lines.out(Lines.codexDone)]
        let blocks = ChatStream.timeline(lines, currentProvider: "codex").blocks
        let texts = blocks.compactMap { block -> String? in
            switch block {
            case let .user(_, text): "you: \(text)"
            case let .assistant(_, text, _, _): "agent: \(text)"
            case let .handoff(_, from, to, _, _): "handoff: \(from)→\(to)"
            default: nil
            }
        }
        #expect(texts == ["you: start", "agent: Claude did the first part.", "handoff: claude→codex",
                          "you: go on", "agent: Codex carried on."])
        #expect(!blocks.contains { if case .raw = $0 { true } else { false } })
    }

    @Test func aLogWithoutMarkersUsesTheCurrentAgent() {
        let stream = ChatStream(providerId: "codex")
        #expect(ChatStream.firstProvider(in: [Lines.out(Lines.codexReply)], current: "codex") == "codex")
        let events = stream.feed(Lines.out(Lines.codexReply))
        #expect(events.contains(.text(role: .assistant, text: "Codex carried on.", blockId: "item_0", partial: false)))
    }

    @Test func theFirstSegmentBelongsToTheAgentHandedOverFrom() {
        let lines = [Lines.out(Lines.claudeReply), handoff.line]
        #expect(ChatStream.firstProvider(in: lines, current: "codex") == "claude")
    }

    @Test func theSummaryTurnIsHiddenAndCaptured() {
        let stream = ChatStream(providerId: "claude")
        #expect(stream.feed(HandoffMarker(phase: .summarize, from: "claude", to: "codex").line).isEmpty)
        #expect(stream.isSummarizing)
        let reply = stream.feed(Lines.out(Lines.claudeReply))
        #expect(reply.isEmpty)
        #expect(!stream.summaryFinished)
        let result = stream.feed(Lines.out(Lines.claudeResult))
        // Usage still counts; nothing else shows.
        #expect(result.allSatisfy { if case .usage = $0 { true } else { false } })
        #expect(stream.summaryFinished)
        #expect(!stream.summaryFailed)
        #expect(stream.capturedSummary == "Claude did the first part.")

        let after = stream.feed(handoff.line)
        #expect(!stream.isSummarizing)
        #expect(stream.providerId == "codex")
        #expect(after == [.handoff(from: "claude", to: "codex", summary: "Claude did the first part.", source: .agent)])
    }

    @Test func aProcessExitEndsTheSummaryTurn() {
        let stream = ChatStream(providerId: "codex")
        _ = stream.feed(HandoffMarker(phase: .summarize, from: "codex", to: "claude").line)
        _ = stream.feed(Lines.out(Lines.codexReply))
        #expect(stream.onExit(code: 0).isEmpty)
        #expect(stream.summaryFinished)
        #expect(stream.capturedSummary == "Codex carried on.")
    }

    @Test func aFailedSummaryTurnIsReported() {
        let stream = ChatStream(providerId: "claude")
        _ = stream.feed(HandoffMarker(phase: .summarize, from: "claude", to: "codex").line)
        _ = stream.feed(Lines.out(#"{"type":"result","subtype":"error","is_error":true,"result":"Claude AI usage limit reached"}"#))
        #expect(stream.summaryFinished)
        #expect(stream.summaryFailed)
    }

    @Test func restartingGivesAFreshParserForTheAgent() {
        let stream = ChatStream(providerId: "claude")
        stream.restart(providerId: "codex")
        #expect(stream.providerId == "codex")
        #expect(!stream.feed(Lines.out(Lines.codexReply)).isEmpty)
    }
}

@Suite("Handoff text")
struct HandoffTextTests {
    static let blocks: [TimelineBlock] = [
        .user(id: 1, text: "Add a login screen"),
        .assistant(id: 2, text: "I'll add it.", streaming: false, opensTurn: true),
        .thinking(id: 3, text: "secret reasoning"),
        .tools(id: 4, calls: [
            ToolCall(id: "t1", name: "Edit", input: .object(["file_path": .string("/wt/Login.swift")])),
            ToolCall(id: "t2", name: "Bash", input: .object(["command": .string("swift test")])),
        ]),
        .assistant(id: 5, text: "Login screen added; tests pass.", streaming: false, opensTurn: false),
        .user(id: 6, text: "Now add sign-up"),
        .error(id: 7, message: "Claude AI usage limit reached"),
    ]

    @Test func transcriptKeepsTheConversationAndToolsButNotThinking() {
        let md = HandoffTranscript.render(blocks: Self.blocks, agentName: "Claude")
        #expect(md.contains("## You\n\nAdd a login screen"))
        #expect(md.contains("## Claude\n\nI'll add it."))
        #expect(md.contains("- Edit `/wt/Login.swift`"))
        #expect(md.contains("- Bash `swift test`"))
        #expect(md.contains("Claude AI usage limit reached"))
        #expect(!md.contains("secret reasoning"))
    }

    @Test func digestCoversTheAskTheStateAndTheFiles() {
        let digest = HandoffDigest.build(blocks: Self.blocks)
        #expect(digest.contains("Add a login screen"))
        #expect(digest.contains("Now add sign-up"))
        #expect(digest.contains("Login screen added; tests pass."))
        #expect(digest.contains("/wt/Login.swift"))
        #expect(digest.contains("usage limit reached"))
        #expect(!digest.contains("secret reasoning"))
    }

    @Test func digestIsCapped() {
        let long = String(repeating: "word ", count: 5_000)
        let digest = HandoffDigest.build(blocks: [.user(id: 1, text: long), .assistant(id: 2, text: long, streaming: false, opensTurn: true)])
        #expect(digest.count <= HandoffDigest.maxLength)
    }

    @Test func preambleNamesTheAgentTheSummaryAndTheTranscript() {
        let text = HandoffPreamble.compose(from: "Claude", summary: "Did X.", transcriptPath: "/a/t.md", resuming: false,
                                           message: "continue")
        #expect(text.contains("Claude"))
        #expect(text.contains("Did X."))
        #expect(text.contains("/a/t.md"))
        #expect(text.hasSuffix("continue"))
    }

    @Test func preambleWithoutATranscriptStillCarriesTheSummary() {
        let text = HandoffPreamble.compose(from: "Codex", summary: "Did Y.", transcriptPath: nil, resuming: true, message: "go")
        #expect(text.contains("Did Y."))
        #expect(!text.contains("transcript is at"))
    }
}

@Suite("Limit detection")
struct LimitDetectorTests {
    @Test(arguments: [
        ("Claude AI usage limit reached|1790000000", LimitKind.usage),
        ("You've hit your usage limit. Upgrade to Pro", .usage),
        ("You've hit your limit · resets 3pm", .usage),
        ("Credit balance is too low", .usage),
        ("stream error: exceeded retry limit, last status: 429 Too Many Requests", .rateLimit),
        ("API Error: Rate limit exceeded", .rateLimit),
        ("Prompt is too long", .context),
        ("Your input exceeds the context window of this model", .context),
        ("input length and max_tokens exceed context limit", .context),
    ])
    func recognisesLimits(message: String, kind: LimitKind) {
        #expect(LimitDetector.classify(message) == kind)
    }

    @Test(arguments: ["claude exited with code 1", "File not found", "Failed to authenticate"])
    func ignoresOtherErrors(message: String) {
        #expect(LimitDetector.classify(message) == nil)
    }
}
