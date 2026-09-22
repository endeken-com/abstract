import Foundation
import Testing
import BacktickCore

@Suite struct ClaudeProviderTests {
    let provider = ClaudeProvider()
    let ctx = LaunchContext(cwd: "/tmp/work", prompt: "make hi.txt", permissionPolicy: .autoEdits)

    static func fixtureEvents() throws -> [AgentEvent] {
        let url = try #require(Bundle.module.url(forResource: "claude-stream", withExtension: "jsonl", subdirectory: "Fixtures"))
        let parser = ClaudeProvider().makeParser()
        return try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .flatMap { parser.feed($0, stream: .stdout) }
    }

    static func feed(_ lines: [String]) -> [AgentEvent] {
        let parser = ClaudeProvider().makeParser()
        return lines.flatMap { parser.feed($0, stream: .stdout) }
    }

    // MARK: - launch

    @Test func launchNeverPutsThePromptInArgvAndSendsItOnStdin() {
        let spec = provider.buildLaunch(ctx)
        #expect(spec.command == "claude")
        #expect(!spec.args.contains("make hi.txt"))
        #expect(spec.args == [
            "-p", "--output-format", "stream-json", "--input-format", "stream-json",
            "--verbose", "--include-partial-messages", "--permission-mode", "acceptEdits",
        ])
        #expect(spec.cwd == "/tmp/work")
        #expect(spec.keepStdinOpen)
        #expect(spec.stdinInitial == #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"make hi.txt"}]}}"# + "\n")
    }

    @Test func mapsEveryPermissionPolicy() {
        var ask = ctx; ask.permissionPolicy = .ask
        let askArgs = provider.buildLaunch(ask).args
        #expect(askArgs.suffix(2) == ["--permission-prompts", "host"])
        var bypass = ctx; bypass.permissionPolicy = .bypass
        #expect(provider.buildLaunch(bypass).args.suffix(2) == ["--permission-mode", "bypassPermissions"])
    }

    @Test func appendsExtraArgs() {
        var c = ctx; c.extraArgs = ["--model", "opus"]
        #expect(provider.buildLaunch(c).args.suffix(2) == ["--model", "opus"])
    }

    @Test func binaryOverrideReplacesTheCommand() {
        var c = ctx; c.binaryOverride = "/opt/bin/claude"
        #expect(provider.buildLaunch(c).command == "/opt/bin/claude")
        #expect(provider.buildResume(c, resumeId: "s").command == "/opt/bin/claude")
        c.binaryOverride = ""
        #expect(provider.buildLaunch(c).command == "claude")
    }

    @Test func resumeAddsResumeFlag() throws {
        var c = ctx; c.extraArgs = ["--model", "opus"]
        let spec = provider.buildResume(c, resumeId: "sess-1")
        let i = try #require(spec.args.firstIndex(of: "--resume"))
        #expect(spec.args[i + 1] == "sess-1")
        #expect(spec.args.suffix(2) == ["--model", "opus"])
        #expect(spec.keepStdinOpen)
        #expect(spec.stdinInitial == provider.buildUserMessage("make hi.txt"))
    }

    @Test func stdinPromptLineRoundTripsQuotesAndNewlines() throws {
        let prompt = "say \"hi\" to C:\\tmp\nthen\ttab \u{01} é 🎉 </script>"
        var c = ctx; c.prompt = prompt
        let line = try #require(provider.buildLaunch(c).stdinInitial)
        #expect(line.hasSuffix("\n"))
        #expect(!line.dropLast().contains("\n"), "the prompt's newline must be escaped: one frame per line")

        let obj = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(obj["type"] as? String == "user")
        let message = try #require(obj["message"] as? [String: Any])
        #expect(message["role"] as? String == "user")
        let content = try #require(message["content"] as? [[String: Any]])
        #expect(content.count == 1)
        #expect(content.first?["type"] as? String == "text")
        #expect(content.first?["text"] as? String == prompt)
        #expect(provider.buildUserMessage(prompt) == line)
    }

    @Test func permissionResponseLines() {
        #expect(provider.buildPermissionResponse(requestId: "req-1", allow: true, input: .object(["a": .number(1)]))
            == #"{"type":"control_response","response":{"subtype":"success","request_id":"req-1","response":{"behavior":"allow","updatedInput":{"a":1}}}}"# + "\n")
        #expect(provider.buildPermissionResponse(requestId: "req-1", allow: false, input: nil)
            == #"{"type":"control_response","response":{"subtype":"success","request_id":"req-1","response":{"behavior":"deny","message":"Denied by user"}}}"# + "\n")
        #expect(provider.buildPermissionResponse(requestId: "req-1", allow: true, input: nil)
            == #"{"type":"control_response","response":{"subtype":"success","request_id":"req-1","response":{"behavior":"allow","updatedInput":{}}}}"# + "\n")
    }

    @Test func providerMetadata() {
        #expect(provider.id == "claude")
        #expect(provider.name == "Claude Code")
        #expect(provider.logoAsset == "ProviderClaude")
        #expect(provider.binary == "claude")
        #expect(provider.detectArgs == ["--version"])
        #expect(provider.followUpMode == .stdin)
    }

    // MARK: - recorded fixture

    @Test func fixtureEmitsSessionId() throws {
        #expect(try Self.fixtureEvents().contains(.sessionId("481e8596-8328-48b5-91e9-ff1d9c7b9681")))
    }

    @Test func fixtureEmitsSystemWithModelAndPermissionMode() throws {
        var systems: [(model: String?, mode: String?, sessionId: String?)] = []
        for case let .system(model, _, mode, sessionId) in try Self.fixtureEvents() { systems.append((model, mode, sessionId)) }
        let system = try #require(systems.first)
        #expect(system.model == "claude-opus-5[1m]")
        #expect(system.mode == "acceptEdits")
        #expect(system.sessionId == "481e8596-8328-48b5-91e9-ff1d9c7b9681")
    }

    @Test func fixtureEmitsCompleteWriteToolUse() throws {
        var uses: [(id: String, name: String, input: JSONValue)] = []
        for case let .toolUse(id, name, input, _) in try Self.fixtureEvents() { uses.append((id, name, input)) }
        #expect(uses.count == 1)
        let use = try #require(uses.first)
        #expect(use.name == "Write")
        #expect(use.id == "toolu_01PDRtLov18XvHuvMmw7buyu")
        let filePath = try #require(use.input["file_path"]?.string)
        #expect(filePath.hasSuffix("hi.txt"))
        #expect(use.input["content"]?.string == "hi\n")
    }

    @Test func fixtureEmitsMatchingToolResultWithCreatePreview() throws {
        let events = try Self.fixtureEvents()
        var useIds: [String] = []
        for case let .toolUse(id, _, _, _) in events { useIds.append(id) }
        var results: [(id: String, output: String, isError: Bool, edit: EditPreview?)] = []
        for case let .toolResult(id, output, isError, edit) in events { results.append((id, output, isError, edit)) }

        let result = try #require(results.first)
        #expect(results.count == 1)
        #expect(result.id == useIds.first)
        #expect(!result.isError)
        #expect(result.output.contains("File created successfully"))
        let edit = try #require(result.edit)
        #expect(edit.filePath.hasSuffix("hi.txt"))
        #expect(edit.additions == 1)
        #expect(edit.deletions == 0)
        #expect(edit.lines == [EditPreview.Line(origin: .added, content: "hi")])
    }

    @Test func fixtureStreamsPartialTextThenFinalWithSameBlockId() throws {
        var partials: [(text: String, blockId: String?)] = []
        var finals: [(text: String, blockId: String?)] = []
        for case let .text(role, text, blockId, partial) in try Self.fixtureEvents() where role == .assistant {
            if partial { partials.append((text, blockId)) } else { finals.append((text, blockId)) }
        }
        #expect(!partials.isEmpty)
        #expect(Set(partials.map(\.blockId)).count == 1)
        #expect(partials.map(\.text).joined() == "hi.txt made.")
        #expect(finals.map(\.text) == ["hi.txt made."])
        #expect(finals.first?.blockId == partials.first?.blockId)
        #expect(finals.first?.blockId == "msg_011CfK7oGZYqYhcxaKaA9YMU:0")
    }

    @Test func fixtureEmitsPostTurnSummary() throws {
        var summaries: [String?] = []
        for case let .turnEnd(_, _, _, summary) in try Self.fixtureEvents() { summaries.append(summary) }
        #expect(summaries == ["hi.txt created"])
    }

    @Test func fixtureEmitsUsageMatchingTheResultLine() throws {
        var usages: [(usage: UsageTotals, cost: Double?, duration: Int?, turns: Int?)] = []
        for case let .usage(usage, cost, duration, turns) in try Self.fixtureEvents() { usages.append((usage, cost, duration, turns)) }
        #expect(usages.count == 1)
        let u = try #require(usages.first)
        let cost = try #require(u.cost)
        #expect(abs(cost - 0.2080365) < 5e-8)
        #expect(u.usage == UsageTotals(inputTokens: 4, outputTokens: 154, cacheRead: 52173, cacheWrite: 17808))
        #expect(u.duration == 4762)
        #expect(u.turns == 2)
    }

    @Test func fixtureParksTheSessionIdleAfterASuccessfulResult() throws {
        let events = try Self.fixtureEvents()
        #expect(events.last == .status(.idle, detail: nil))
        #expect(!events.contains(.status(.waitingInput, detail: nil)))
    }

    @Test func fixtureUnderstandsEveryLine() throws {
        var raws: [String] = []
        for case let .raw(line, _) in try Self.fixtureEvents() { raws.append(line) }
        #expect(raws.isEmpty, "unexpected raw lines: \(raws.map { String($0.prefix(120)) })")
    }

    @Test func fixtureMarksEachMessageRunning() throws {
        let running = try Self.fixtureEvents().filter { $0 == .status(.running, detail: nil) }
        #expect(running.count == 2)
    }

    // MARK: - robustness

    @Test func malformedLineIsExactlyOneRawEvent() {
        let parser = provider.makeParser()
        #expect(parser.feed("{not json", stream: .stdout) == [.raw(line: "{not json", stream: .stdout)])
    }

    @Test func stderrLinesAreRaw() {
        let parser = provider.makeParser()
        #expect(parser.feed("boom", stream: .stderr) == [.raw(line: "boom", stream: .stderr)])
        #expect(parser.feed("   ", stream: .stderr).isEmpty)
        #expect(parser.feed("", stream: .stdout).isEmpty)
    }

    @Test func reportsExitStatus() {
        #expect(provider.makeParser().onExit(code: 0) == [.status(.finished, detail: nil)])
        let failed = provider.makeParser().onExit(code: 1)
        #expect(failed.count == 2)
        #expect(failed.first == .error("claude exited with code 1"))
        #expect(failed.last == .status(.errored, detail: nil))
        #expect(provider.makeParser().onExit(code: nil).first == .error("claude exited with code null"))
    }

    @Test func survivesHostileInput() {
        let junk = [
            "[]", "null", "42", "\"str\"", "{}", "{\"type\":null}", "{\"type\":\"system\"}",
            "{\"type\":\"stream_event\"}",
            "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"index\":\"x\",\"delta\":null}}",
            "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"index\":1e300,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":7}}}",
            "{\"type\":\"assistant\",\"message\":{\"content\":[null,1,{\"type\":\"tool_use\"},{\"type\":\"text\"}]}}",
            "{\"type\":\"user\",\"message\":{\"content\":\"plain\"},\"tool_use_result\":{\"structuredPatch\":[1,{\"lines\":[2,\"+x\"]}]}}",
            "{\"type\":\"control_request\",\"request\":{\"subtype\":\"can_use_tool\"}}",
            "{\"type\":\"result\",\"duration_ms\":1e300,\"num_turns\":-1e300,\"usage\":\"nope\",\"is_error\":\"yes\"}",
            "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_start\"",
        ]
        let events = Self.feed(junk)
        #expect(events.contains(.usage(.zero, costUsd: nil, durationMs: nil, turns: nil)))
        #expect(events.contains(.status(.idle, detail: nil)))
    }

    // MARK: - behaviour beyond the fixture

    @Test func finalTextMatchesItsStreamedBlockWhenFramesAreSplitPerBlock() {
        let events = Self.feed([
            #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"m1"}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}}"#,
            #"{"type":"assistant","message":{"id":"m1","content":[{"type":"thinking","thinking":"hmm"}]}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_stop","index":0}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hel"}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"lo"}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_stop","index":1}}"#,
            #"{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"Hello"}]}}"#,
        ])
        #expect(events.contains(.thinking(text: "hmm", blockId: "m1:0", partial: true)))
        #expect(events.contains(.text(role: .assistant, text: "Hel", blockId: "m1:1", partial: true)))
        #expect(events.contains(.text(role: .assistant, text: "Hello", blockId: "m1:1", partial: false)))
    }

    @Test func toolInputFallsBackToStreamedJSONWhenTheFrameHasNone() {
        let events = Self.feed([
            #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"m2"}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t1","name":"Read","input":{}}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"offset\": 1, \"pa"}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"th\": \"a.txt\"}"}}}"#,
            #"{"type":"assistant","message":{"id":"m2","content":[{"type":"tool_use","id":"t1","name":"Read"}]}}"#,
        ])
        #expect(events.last == .toolUse(id: "t1", name: "Read",
                                        input: .object(["offset": .number(1), "path": .string("a.txt")]), edit: nil))
    }

    @Test func numericZeroAndOneStayNumbers() {
        let events = Self.feed([
            #"{"type":"result","is_error":false,"num_turns":1,"duration_ms":0,"usage":{"input_tokens":1,"output_tokens":0,"cache_read_input_tokens":1,"cache_creation_input_tokens":1}}"#,
        ])
        #expect(events.first == .usage(UsageTotals(inputTokens: 1, outputTokens: 0, cacheRead: 1, cacheWrite: 1),
                                       costUsd: nil, durationMs: 0, turns: 1))
    }

    @Test func permissionRequestWaitsForInput() {
        let events = Self.feed([
            #"{"type":"control_request","request_id":"req-9","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"ls"}}}"#,
        ])
        #expect(events == [
            .permissionRequest(requestId: "req-9", toolName: "Bash", input: .object(["command": .string("ls")])),
            .status(.waitingInput, detail: "Permission needed: Bash"),
        ])
    }

    @Test func nonEmptyNeedsActionWaitsForInput() {
        let events = Self.feed([
            #"{"type":"system","subtype":"post_turn_summary","status_detail":"PR drafted","needs_action":"Review the PR"}"#,
        ])
        #expect(events == [
            .turnEnd(durationMs: nil, costUsd: nil, usage: nil, summary: "PR drafted"),
            .status(.waitingInput, detail: "Review the PR"),
        ])
    }

    @Test func erroredResult() {
        let events = Self.feed([#"{"type":"result","subtype":"error_max_turns","is_error":true}"#])
        #expect(events.suffix(2) == [.error("error_max_turns"), .status(.errored, detail: nil)])
    }

    @Test func structuredPatchPreview() throws {
        let events = Self.feed([
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t","content":[{"type":"text","text":"ok "},{"type":"text","text":"done"}],"is_error":true}]},"tool_use_result":{"filePath":"/a.swift","structuredPatch":[{"lines":[" keep","-old","+new","+more"]}]}}"#,
        ])
        #expect(events == [.toolResult(toolUseId: "t", output: "ok done", isError: true, edit: EditPreview(
            filePath: "/a.swift", additions: 2, deletions: 1,
            lines: [.init(origin: .context, content: "keep"), .init(origin: .removed, content: "old"),
                    .init(origin: .added, content: "new"), .init(origin: .added, content: "more")]))])
    }
}

@Suite struct ProviderRegistryTests {
    @Test func listsEveryProviderOnce() {
        let ids = ProviderRegistry.all.map(\.id)
        #expect(ids == ["claude", "codex"])
        #expect(Set(ids).count == ids.count)
    }

    @Test func looksUpById() {
        #expect(ProviderRegistry.provider("claude")?.name == "Claude Code")
        #expect(ProviderRegistry.provider("codex")?.name == "Codex")
        #expect(ProviderRegistry.provider("nope") == nil)
    }
}
