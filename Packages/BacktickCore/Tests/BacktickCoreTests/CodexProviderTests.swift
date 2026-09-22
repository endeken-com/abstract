import Foundation
import Testing
import BacktickCore

@Suite struct CodexProviderTests {
    let provider = CodexProvider()
    let ctx = LaunchContext(cwd: "/tmp/work", prompt: "make hi.txt", permissionPolicy: .autoEdits)

    static func fixtureEvents() throws -> [AgentEvent] {
        let url = try #require(Bundle.module.url(forResource: "codex-stream", withExtension: "jsonl", subdirectory: "Fixtures"))
        let parser = CodexProvider().makeParser()
        return try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .flatMap { parser.feed($0, stream: .stdout) }
    }

    static func feed(_ lines: [String]) -> [AgentEvent] {
        let parser = CodexProvider().makeParser()
        return lines.flatMap { parser.feed($0, stream: .stdout) }
    }

    // MARK: - launch

    @Test func passesThePromptAsTheFinalPositionalArg() {
        let spec = provider.buildLaunch(ctx)
        #expect(spec.command == "codex")
        #expect(spec.args == ["exec", "--json", "-C", "/tmp/work", "--skip-git-repo-check", "-s", "workspace-write", "make hi.txt"])
        #expect(spec.cwd == "/tmp/work")
        #expect(!spec.keepStdinOpen)
        #expect(spec.stdinInitial == nil)
        #expect(provider.followUpMode == .respawn)
    }

    @Test func mapsSandboxPolicies() {
        var ask = ctx; ask.permissionPolicy = .ask
        #expect(provider.buildLaunch(ask).args.contains("workspace-write"))
        var bypass = ctx; bypass.permissionPolicy = .bypass
        #expect(provider.buildLaunch(bypass).args.contains("danger-full-access"))
    }

    @Test func buildsAResumeInvocation() {
        var c = ctx; c.extraArgs = ["-m", "o4"]
        let spec = provider.buildResume(c, resumeId: "thread-1")
        #expect(Array(spec.args.prefix(3)) == ["exec", "resume", "thread-1"])
        #expect(spec.args.last == "make hi.txt")
        #expect(Array(spec.args.suffix(3)) == ["-m", "o4", "make hi.txt"])
        #expect(!spec.keepStdinOpen)
    }

    @Test func binaryOverrideReplacesTheCommand() {
        var c = ctx; c.binaryOverride = "/opt/bin/codex"
        #expect(provider.buildLaunch(c).command == "/opt/bin/codex")
    }

    @Test func hasNoStdinProtocol() {
        #expect(provider.buildUserMessage("hi") == nil)
        #expect(provider.buildPermissionResponse(requestId: "r", allow: true, input: nil) == nil)
    }

    @Test func providerMetadata() {
        #expect(provider.id == "codex")
        #expect(provider.name == "Codex")
        #expect(provider.logoAsset == "ProviderOpenAI")
        #expect(provider.binary == "codex")
        #expect(provider.detectArgs == ["--version"])
    }

    // MARK: - recorded fixture

    @Test func fixtureEmitsTheThreadIdAsTheSessionId() throws {
        #expect(try Self.fixtureEvents().first == .sessionId("01a0cad4-f355-7380-b8cd-3b7b34fac1a4"))
    }

    @Test func fixtureMarksTheTurnRunning() throws {
        #expect(try Self.fixtureEvents().contains(.status(.running, detail: nil)))
    }

    @Test func fixtureCapturesAgentMessageText() throws {
        var texts: [(text: String, blockId: String?, partial: Bool)] = []
        for case let .text(_, text, blockId, partial) in try Self.fixtureEvents() { texts.append((text, blockId, partial)) }
        #expect(texts.count == 2)
        #expect(texts.first?.text.contains("create `hi.txt`") == true)
        #expect(texts.first?.partial == false)
        #expect(texts.last?.text == "Created `hi.txt` containing `hi`.")
        #expect(texts.last?.blockId == "item_2")
    }

    @Test func fixtureTurnsCommandExecutionIntoBashToolUseAndResult() throws {
        let events = try Self.fixtureEvents()
        var uses: [(id: String, name: String, input: JSONValue)] = []
        for case let .toolUse(id, name, input, _) in events { uses.append((id, name, input)) }
        #expect(uses.count == 1)
        let use = try #require(uses.first)
        #expect(use.name == "Bash")
        #expect(use.id == "item_1")
        #expect(use.input == .object(["command": .string(#"/bin/zsh -lc "printf 'hi\\n' > hi.txt""#)]))

        var results: [(id: String, isError: Bool)] = []
        for case let .toolResult(id, _, isError, _) in events { results.append((id, isError)) }
        #expect(results.count == 1)
        #expect(results.first?.id == "item_1")
        #expect(results.first?.isError == false)
    }

    @Test func fixtureEmitsUsageAndFinishedOnTurnCompleted() throws {
        let events = try Self.fixtureEvents()
        var usages: [UsageTotals] = []
        for case let .usage(usage, _, _, _) in events { usages.append(usage) }
        #expect(usages == [UsageTotals(inputTokens: 34277, outputTokens: 66, cacheRead: 29056, cacheWrite: 0)])
        #expect(events.last == .status(.finished, detail: nil))
    }

    @Test func fixtureUnderstandsEveryLine() throws {
        var raws: [String] = []
        for case let .raw(line, _) in try Self.fixtureEvents() { raws.append(line) }
        #expect(raws.isEmpty, "unexpected raw lines: \(raws)")
    }

    // MARK: - robustness

    @Test func malformedLineIsExactlyOneRawEvent() {
        let parser = provider.makeParser()
        #expect(parser.feed("{not json", stream: .stdout) == [.raw(line: "{not json", stream: .stdout)])
    }

    @Test func unknownEventTypesFallBackToRaw() {
        let parser = provider.makeParser()
        #expect(parser.feed(#"{"type":"something.new"}"#, stream: .stdout)
            == [.raw(line: #"{"type":"something.new"}"#, stream: .stdout)])
        #expect(parser.feed("warn: x", stream: .stderr) == [.raw(line: "warn: x", stream: .stderr)])
    }

    @Test func errorsOnTurnFailed() {
        let parser = provider.makeParser()
        #expect(parser.feed(#"{"type":"turn.failed","error":{"message":"nope"}}"#, stream: .stdout)
            == [.error("nope"), .status(.errored, detail: nil)])
        #expect(parser.feed(#"{"type":"error","message":"boom"}"#, stream: .stdout)
            == [.error("boom"), .status(.errored, detail: nil)])
    }

    @Test func reportsExitStatus() {
        #expect(provider.makeParser().onExit(code: 0) == [.status(.finished, detail: nil)])
        #expect(provider.makeParser().onExit(code: 2) == [.error("codex exited with code 2"), .status(.errored, detail: nil)])
    }

    @Test func survivesHostileInput() {
        let junk = [
            "[]", "null", "1", "{}", "{\"type\":\"thread.started\"}", "{\"type\":\"item.completed\"}",
            "{\"type\":\"item.completed\",\"item\":{\"type\":7}}",
            "{\"type\":\"item.completed\",\"item\":{\"type\":\"command_execution\",\"exit_code\":1e300}}",
            "{\"type\":\"item.completed\",\"item\":{\"type\":\"file_change\",\"changes\":[null],\"diff\":5}}",
            "{\"type\":\"turn.completed\",\"usage\":[1,2]}",
            "{\"type\":\"turn.failed\",\"error\":\"flat\"}",
            "{\"type\":\"item.started\",\"item\":{\"id\":\"x\"",
        ]
        let events = Self.feed(junk)
        #expect(events.contains(.usage(.zero, costUsd: nil, durationMs: nil, turns: nil)))
        #expect(events.contains(.error("flat")))
    }

    // MARK: - behaviour beyond the fixture

    @Test func nonZeroExitCodeIsAnError() {
        let events = Self.feed([
            #"{"type":"item.completed","item":{"id":"c","type":"command_execution","command":"false","aggregated_output":"","exit_code":1,"status":"failed"}}"#,
        ])
        #expect(events == [
            .toolUse(id: "c", name: "Bash", input: .object(["command": .string("false")]), edit: nil),
            .toolResult(toolUseId: "c", output: "", isError: true, edit: nil),
        ])
    }

    @Test func fileChangeCarriesAnEditPreview() {
        let events = Self.feed([
            #"{"type":"item.completed","item":{"id":"p","type":"file_change","status":"completed","changes":[{"path":"a.txt","diff":"--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-old\n+new\n"}]}}"#,
        ])
        let edit = EditPreview(filePath: "a.txt", additions: 1, deletions: 1,
                               lines: [.init(origin: .removed, content: "old"), .init(origin: .added, content: "new")])
        #expect(events.count == 2)
        if case let .toolUse(id, name, _, e) = events.first {
            #expect(id == "p"); #expect(name == "ApplyPatch"); #expect(e == edit)
        } else {
            Issue.record("expected a toolUse, got \(String(describing: events.first))")
        }
        #expect(events.last == .toolResult(toolUseId: "p", output: "", isError: false, edit: edit))
    }

    @Test func streamingAgentMessageIsPartialUntilCompleted() {
        let events = Self.feed([
            #"{"type":"item.updated","item":{"id":"m","type":"agent_message","text":"Hel"}}"#,
            #"{"type":"item.completed","item":{"id":"m","type":"agent_message","text":"Hello"}}"#,
        ])
        #expect(events == [
            .text(role: .assistant, text: "Hel", blockId: "m", partial: true),
            .text(role: .assistant, text: "Hello", blockId: "m", partial: false),
        ])
    }
}

@Suite("Codex argv edge cases")
struct CodexArgvTests {
    @Test func promptStartingWithADashIsNotReadAsAFlag() {
        let spec = CodexProvider().buildLaunch(LaunchContext(cwd: "/tmp/w", prompt: "- fix the parser", permissionPolicy: .autoEdits))
        #expect(Array(spec.args.suffix(2)) == ["--", "- fix the parser"])
    }
}
