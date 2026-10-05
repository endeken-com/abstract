import Foundation
import Testing
@testable import AbstractCore

@Suite("Stopping a turn")
struct TurnStopTests {
    private static let agents: [any ProviderDefinition] = [ClaudeProvider(), CodexProvider(), OpenCodeProvider()]

    private static func feed(_ lines: [String]) -> [AgentEvent] {
        let parser = ClaudeProvider().makeParser()
        return lines.flatMap { parser.feed($0, stream: .stdout) }
    }

    /// What claude 2.1.283 printed when interrupted mid-reply, ids shortened.
    private static let interruptedReply = [
        #"{"type":"control_response","response":{"subtype":"success","request_id":"stop-1","response":{"still_queued":[]}}}"#,
        ##"{"type":"assistant","message":{"id":"msg_1","type":"message","role":"assistant","content":[{"type":"text","text":"# The History of Bridges"}]},"parent_tool_use_id":null,"session_id":"s"}"##,
        #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]},"parent_tool_use_id":null,"session_id":"s"}"#,
        #"{"type":"result","subtype":"error_during_execution","is_error":true,"duration_ms":6268,"num_turns":2,"total_cost_usd":0,"terminal_reason":"aborted_streaming","stop_reason":null,"errors":["[ede_diagnostic] result_type=user last_content_type=n/a stop_reason=null"],"usage":{"input_tokens":0,"output_tokens":0},"session_id":"s"}"#,
    ]

    /// The same, interrupted while a command ran.
    private static let interruptedTool = [
        #"{"type":"control_response","response":{"subtype":"success","request_id":"stop-2","response":{"still_queued":[]}}}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"The user doesn't want to proceed with this tool use.","is_error":true,"tool_use_id":"toolu_1"}]},"parent_tool_use_id":null,"session_id":"s","tool_use_result":"User rejected tool use"}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]},"parent_tool_use_id":null,"session_id":"s"}"#,
        #"{"type":"result","subtype":"error_during_execution","is_error":true,"duration_ms":11312,"num_turns":3,"terminal_reason":"aborted_tools","stop_reason":"tool_use","session_id":"s"}"#,
    ]

    @Test func claudeIsInterruptedOverItsControlChannel() throws {
        let line = try #require(ClaudeProvider().buildInterrupt(requestId: "stop-1"))
        #expect(line == #"{"type":"control_request","request_id":"stop-1","request":{"subtype":"interrupt"}}"# + "\n")
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
        #expect(json["request"]?["subtype"]?.string == "interrupt")
    }

    @Test func midTurnClaudeIsInterruptedAndTheOthersAreEnded() {
        let claude = ClaudeProvider()
        for status in [SessionStatus.running, .waitingInput] {
            #expect(TurnStop.action(claude, status: status, requestId: "r") == .interrupt(claude.buildInterrupt(requestId: "r")!))
        }
        // Between turns there is nothing to interrupt.
        #expect(TurnStop.action(claude, status: .idle, requestId: "r") == .terminate)
        for agent in [CodexProvider(), OpenCodeProvider()] as [any ProviderDefinition] {
            #expect(agent.buildInterrupt(requestId: "r") == nil)
            #expect(TurnStop.action(agent, status: .running, requestId: "r") == .terminate)
        }
    }

    @Test func theInterruptReachesTheRunningAgent() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let engine = SessionEngine(executor: LocalExecutor.shared, logDirectory: dir)
        // Prints the first line it is sent, as an agent reading its stdin would get it.
        try engine.launch(sessionId: "c", spec: LaunchSpec(command: "/bin/sh", args: ["-c", "read line; printf '%s\\n' \"$line\""],
                                                           cwd: dir.path, keepStdinOpen: true))
        guard case let .interrupt(line) = TurnStop.action(ClaudeProvider(), status: .running, requestId: "stop-3") else {
            Issue.record("Claude should be interrupted"); return
        }
        try engine.write(sessionId: "c", line)
        var printed: [String] = []
        for await event in engine.events {
            if case let .line(_, _, output) = event { printed.append(output.line) }
            if case .exit = event { break }
        }
        #expect(printed == [line.trimmingCharacters(in: .newlines)])
    }

    @Test func anInterruptedReplyEndsQuietlyAndWaitsForYou() {
        let events = Self.feed(Self.interruptedReply)
        #expect(!events.contains { if case .error = $0 { true } else { false } })
        #expect(!events.contains(.status(.errored, detail: nil)))
        #expect(events.last == .status(.idle, detail: nil))
        var timeline = Timeline()
        timeline.append(contentsOf: events)
        let blocks = timeline.blocks
        // The reply so far, then one quiet rule; not the CLI's note as a message of yours.
        #expect(blocks.count == 2)
        guard case .assistant = blocks.first, case let .turn(_, summary, duration, _, _) = blocks.last else {
            Issue.record("Expected the reply and a Stopped rule, got \(blocks)"); return
        }
        #expect(summary == "Stopped")
        #expect(duration == 6268)
    }

    @Test func anInterruptedCommandEndsQuietlyToo() {
        let events = Self.feed(Self.interruptedTool)
        #expect(!events.contains { if case .error = $0 { true } else { false } })
        #expect(!events.contains { if case .text(.user, _, _, _) = $0 { true } else { false } })
        #expect(events.contains(TurnStop.rule))
        #expect(events.last == .status(.idle, detail: nil))
    }

    @Test func claudesOwnErrorsAreStillErrors() {
        let events = Self.feed([#"{"type":"result","subtype":"error_during_execution","is_error":true,"result":"API Error: 500","terminal_reason":"completed"}"#])
        #expect(events.contains(.error("API Error: 500")))
        #expect(events.last == .status(.errored, detail: nil))
        #expect(!events.contains(TurnStop.rule))
    }

    @Test func aStopYouAskedForIsNotAFailureForAnyAgent() {
        for agent in Self.agents {
            for code: Int32? in [143, 15, nil, 0] {
                let events = ChatStream(providerId: agent.id).onExit(code: code, stopRequested: true)
                #expect(events == TurnStop.events, "\(agent.id) exiting with \(String(describing: code))")
            }
        }
    }

    @Test func anExitNobodyAskedForIsStillAnError() {
        for agent in Self.agents {
            let events = ChatStream(providerId: agent.id).onExit(code: 143)
            #expect(events.contains { if case .error = $0 { true } else { false } }, "\(agent.id)")
            #expect(events.last == .status(.errored, detail: nil), "\(agent.id)")
            #expect(!events.contains(TurnStop.rule))
        }
    }
}
