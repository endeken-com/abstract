import Foundation
import Testing
import AbstractCore

@Suite struct AgentTaskTests {
    /// A live run (claude 2.1.280): a background subagent and a background
    /// shell command, then the turns the CLI starts itself as each one ends.
    static func fixtureEvents() throws -> [AgentEvent] {
        let url = try #require(Bundle.module.url(forResource: "claude-background", withExtension: "jsonl", subdirectory: "Fixtures"))
        let parser = ClaudeProvider().makeParser()
        return try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .flatMap { parser.feed($0, stream: .stdout) }
    }

    static func fixtureTimeline() throws -> Timeline {
        var t = Timeline()
        t.append(contentsOf: try fixtureEvents())
        return t
    }

    // MARK: - parsing

    @Test func parsesATaskStarting() {
        let events = ClaudeProviderTests.feed([#"""
        {"type":"system","subtype":"task_started","task_id":"a19","tool_use_id":"toolu_1","description":"Audit the parser","subagent_type":"general-purpose","is_backgrounded":true,"spawn_depth":1,"task_type":"local_agent","prompt":"Read the parser and list gaps.","uuid":"u","session_id":"s"}
        """#])
        #expect(events == [.task(.started(AgentTask(
            id: "a19", kind: .agent, description: "Audit the parser", toolUseId: "toolu_1",
            subagentType: "general-purpose", prompt: "Read the parser and list gaps.", isBackgrounded: true)))])
    }

    @Test func aShellTaskStartedByASubagentSaysSo() {
        let events = ClaudeProviderTests.feed([#"""
        {"type":"system","subtype":"task_started","task_id":"b6w","owned_by_subagent":true,"tool_use_id":"toolu_2","description":"Sleep","is_backgrounded":false,"task_type":"local_bash"}
        """#])
        #expect(events == [.task(.started(AgentTask(id: "b6w", kind: .shell, description: "Sleep", toolUseId: "toolu_2", ownedBySubagent: true)))])
    }

    @Test func parsesProgressUpdatesAndTheEnd() {
        let events = ClaudeProviderTests.feed([
            #"{"type":"system","subtype":"task_progress","task_id":"a19","tool_use_id":"toolu_1","description":"Running tests","usage":{"total_tokens":12170,"tool_uses":3,"duration_ms":1593},"last_tool_name":"Bash"}"#,
            #"{"type":"system","subtype":"task_updated","task_id":"a19","patch":{"is_backgrounded":true}}"#,
            #"{"type":"system","subtype":"task_updated","task_id":"a19","patch":{"status":"killed","end_time":1790215784418}}"#,
            #"{"type":"system","subtype":"task_notification","task_id":"a19","tool_use_id":"toolu_1","status":"completed","output_file":"/tmp/t/a19.output","summary":"All green.","usage":{"total_tokens":13900,"tool_uses":4,"duration_ms":11233}}"#,
        ])
        #expect(events == [
            .task(.progress(taskId: "a19", activity: "Running tests", lastToolName: "Bash",
                            usage: TaskUsage(tokens: 12170, toolUses: 3, durationMs: 1593))),
            .task(.updated(taskId: "a19", status: nil, isBackgrounded: true, error: nil)),
            .task(.updated(taskId: "a19", status: .stopped, isBackgrounded: nil, error: nil)),
            .task(.finished(taskId: "a19", status: .completed, summary: "All green.", outputFile: "/tmp/t/a19.output",
                            usage: TaskUsage(tokens: 13900, toolUses: 4, durationMs: 11233))),
        ])
    }

    @Test func theRunningSetIsUnderstoodButAddsNothing() {
        let events = ClaudeProviderTests.feed([
            #"{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"a19","task_type":"local_agent","description":"x"}]}"#,
        ])
        #expect(events.isEmpty)
    }

    @Test func aSubagentsMessagesComeUnderTheCallThatStartedIt() {
        let events = ClaudeProviderTests.feed([
            #"{"type":"assistant","message":{"id":"msg_sub","role":"assistant","content":[{"type":"tool_use","id":"toolu_s1","name":"Bash","input":{"command":"ls"}}]},"parent_tool_use_id":"toolu_1"}"#,
            #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_s1","type":"tool_result","content":"a.txt","is_error":false}]},"parent_tool_use_id":"toolu_1"}"#,
            #"{"type":"assistant","message":{"id":"msg_sub2","role":"assistant","content":[{"type":"text","text":"Found a.txt"}]},"parent_tool_use_id":"toolu_1"}"#,
        ])
        #expect(events == [
            .subagent(parentToolUseId: "toolu_1", .toolUse(id: "toolu_s1", name: "Bash", input: .object(["command": .string("ls")]), edit: nil)),
            .subagent(parentToolUseId: "toolu_1", .toolResult(toolUseId: "toolu_s1", output: "a.txt", isError: false, edit: nil)),
            .subagent(parentToolUseId: "toolu_1", .text(role: .assistant, text: "Found a.txt", blockId: "msg_sub2:0", partial: false)),
        ])
    }

    @Test func aLongCommandsHeartbeatIsHousekeeping() {
        // Every 30 s while a command runs in the foreground (claude 2.1.280).
        let events = ClaudeProviderTests.feed([
            #"{"type":"tool_progress","tool_use_id":"toolu_1-heartbeat-0","tool_name":"Bash","parent_tool_use_id":"toolu_1","elapsed_time_seconds":30,"heartbeat":true,"session_id":"s"}"#,
        ])
        #expect(events.isEmpty)
    }

    @Test func fixtureUnderstandsEveryLine() throws {
        var raws: [String] = []
        for case let .raw(line, _) in try Self.fixtureEvents() { raws.append(line) }
        #expect(raws.isEmpty, "unexpected raw lines: \(raws.map { String($0.prefix(120)) })")
    }

    // MARK: - timeline

    @Test func listsTheBackgroundTasksWithHowTheyEnded() throws {
        let tasks = try Self.fixtureTimeline().tasks.filter(\.isBackgrounded)
        #expect(tasks.map(\.id) == ["a1921f0954f52ee57", "bl8cio4rv"])
        #expect(tasks.map(\.kind) == [.agent, .shell])
        #expect(tasks.allSatisfy { $0.status == .completed })

        let agent = tasks[0]
        #expect(agent.subagentType == "general-purpose")
        #expect(agent.prompt == "Run the bash command: sleep 8; echo sub-done and report the output.")
        #expect(agent.summary?.contains("sub-done") == true)
        #expect(agent.usage == TaskUsage(tokens: 13900, toolUses: 1, durationMs: 11233))
        // A subagent's output file is its transcript, not something to read.
        #expect(agent.outputFile == nil)

        let shell = tasks[1]
        #expect(shell.summary == #"Background command "Run background bash command" completed (exit code 0)"#)
        #expect(shell.outputFile?.hasSuffix("/tasks/bl8cio4rv.output") == true)
    }

    @Test func keepsATasksProgressWhileItRuns() {
        var t = Timeline()
        t.append(.task(.started(AgentTask(id: "a", kind: .agent, description: "Audit", isBackgrounded: true))))
        t.append(.task(.progress(taskId: "a", activity: "Reading Timeline.swift", lastToolName: "Read",
                                 usage: TaskUsage(tokens: 900, toolUses: 2, durationMs: 4000))))
        let task = try? #require(t.tasks.first)
        #expect(task?.status == .running)
        #expect(task?.activity == "Reading Timeline.swift")
        #expect(task?.lastToolName == "Read")
        #expect(task?.usage?.toolUses == 2)
    }

    @Test func workMovedToTheBackgroundJoinsTheList() {
        var t = Timeline()
        t.append(.task(.started(AgentTask(id: "b", kind: .shell, description: "npm test", toolUseId: "toolu_9"))))
        #expect(t.tasks.filter(\.isBackgrounded).isEmpty)
        t.append(.task(.updated(taskId: "b", status: nil, isBackgrounded: true, error: nil)))
        #expect(t.tasks.filter(\.isBackgrounded).map(\.id) == ["b"])
        t.append(.task(.updated(taskId: "b", status: .failed, isBackgrounded: nil, error: "exit 1")))
        #expect(t.tasks.first?.status == .failed)
        #expect(t.tasks.first?.error == "exit 1")
    }

    @Test func aShellTaskKnowsWhereItsOutputGoesWhileItRuns() throws {
        var t = Timeline()
        t.append(.task(.started(AgentTask(id: "bl8", kind: .shell, description: "tests", toolUseId: "toolu_7", isBackgrounded: true))))
        t.append(.toolResult(toolUseId: "toolu_7", output: "Command running in background with ID: bl8. Output is being written to: /tmp/claude-501/-tmp-work/s/tasks/bl8.output. You will be notified when it completes.", isError: false, edit: nil))
        #expect(t.tasks.first?.outputFile == "/tmp/claude-501/-tmp-work/s/tasks/bl8.output")
        // As in the recording, before the command ends.
        let events = try Self.fixtureEvents()
        let beforeEnd = events.prefix { if case .task(.finished(taskId: "bl8cio4rv", _, _, _, _)) = $0 { false } else { true } }
        var live = Timeline()
        live.append(contentsOf: Array(beforeEnd))
        #expect(live.tasks.first { $0.id == "bl8cio4rv" }?.outputFile?.hasSuffix("/tasks/bl8cio4rv.output") == true)
    }

    @Test func eventsForAnUnknownTaskAreIgnored() {
        var t = Timeline()
        t.append(.task(.finished(taskId: "ghost", status: .completed, summary: nil, outputFile: nil, usage: nil)))
        #expect(t.tasks.isEmpty)
    }

    @Test func aSubagentsWorkStaysOutOfTheConversation() throws {
        let timeline = try Self.fixtureTimeline()
        let replies = timeline.blocks.compactMap { block -> String? in
            if case let .assistant(_, text, _, _) = block { text } else { nil }
        }
        #expect(replies.first == "STARTED")
        #expect(!replies.contains { $0.contains("Command completed successfully") })
        let callNames = timeline.blocks.flatMap { block -> [String] in
            if case let .tools(_, calls) = block { calls.map(\.name) } else { [] }
        }
        #expect(callNames == ["Agent", "Bash", "Read"])
    }

    @Test func aSubagentsWorkIsItsOwnTimeline() throws {
        let sub = try Self.fixtureTimeline().subagent("toolu_01BYU4UZZXwKVwCttGq15kG7")
        let blocks = sub.blocks
        guard case let .tools(_, calls)? = blocks.first else { Issue.record("expected the subagent's tool call first"); return }
        #expect(calls.map(\.name) == ["Bash"])
        #expect(calls.first?.result?.output == "sub-done")
        guard case let .assistant(_, text, _, _)? = blocks.last else { Issue.record("expected its reply last"); return }
        #expect(text.contains("sub-done"))
        #expect(try Self.fixtureTimeline().subagent("toolu_none").isEmpty)
    }

    // MARK: - control

    @Test func stopsATaskOverTheControlChannel() throws {
        let line = try #require(ClaudeProvider().buildStopTask("a19", requestId: "stop-1"))
        #expect(line == #"{"type":"control_request","request_id":"stop-1","request":{"subtype":"stop_task","task_id":"a19"}}"# + "\n")
        #expect(CodexProvider().buildStopTask("a19", requestId: "r") == nil)
    }

    @Test func movesWorkToTheBackgroundLikeCtrlB() throws {
        let one = try #require(ClaudeProvider().buildBackground(toolUseId: "toolu_9", requestId: "bg-1"))
        #expect(one == #"{"type":"control_request","request_id":"bg-1","request":{"subtype":"background_tasks","tool_use_id":"toolu_9"}}"# + "\n")
        let all = try #require(ClaudeProvider().buildBackground(toolUseId: nil, requestId: "bg-2"))
        #expect(all == #"{"type":"control_request","request_id":"bg-2","request":{"subtype":"background_tasks"}}"# + "\n")
        #expect(CodexProvider().buildBackground(toolUseId: nil, requestId: "r") == nil)
    }
}
