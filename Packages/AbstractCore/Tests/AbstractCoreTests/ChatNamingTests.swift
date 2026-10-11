import Foundation
import Testing
@testable import AbstractCore

/// The Abstract project's own naming instructions, as the ticket quotes them.
private let abstractInstructions =
    "Start branches with bugfix/, feature/. Keep titles short, for commit messages always do it one line message"

/// A naming answer in `claude --output-format json`'s envelope.
private func claudeAnswer(title: String, branch: String) -> String {
    let inner = #"{"title": "\#(title)", "branch": "\#(branch)"}"#
    let data = try! JSONSerialization.data(withJSONObject: ["type": "result", "is_error": false, "result": inner])
    return String(decoding: data, as: UTF8.self)
}

/// A stand-in `claude` that answers each naming call with the next of
/// `answers` (nil: it fails), keeping each prompt it was sent.
private struct ScriptedAgent {
    let dir: String
    var binary: String { dir + "/agent" }

    init(_ answers: [String?]) throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("naming-" + UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (i, answer) in answers.enumerated() {
            if let answer { try answer.write(toFile: "\(dir)/answer-\(i + 1)", atomically: true, encoding: .utf8) }
        }
        let script = """
            #!/bin/sh
            n=$(cat "\(dir)/count" 2>/dev/null || echo 0); n=$((n + 1)); echo $n > "\(dir)/count"
            cat > "\(dir)/prompt-$n"
            test -f "\(dir)/answer-$n" || { echo "Not signed in." >&2; exit 1; }
            grep -q '^sleep$' "\(dir)/answer-$n" && sleep 5
            cat "\(dir)/answer-$n"
            """
        try script.write(toFile: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary)
    }

    var calls: Int { Int((try? String(contentsOfFile: dir + "/count", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0 }
    func prompt(_ n: Int) -> String { (try? String(contentsOfFile: "\(dir)/prompt-\(n)", encoding: .utf8)) ?? "" }

    func suggest(instructions: String = abstractInstructions, timeout: Duration = .seconds(10)) async -> Result<ChatNaming.Suggestion, ChatNaming.Failure> {
        await ChatNaming.suggest(executor: LocalExecutor.shared, provider: ClaudeProvider(), binary: binary,
                                 instructions: instructions, task: "The relay image push fails", timeout: timeout)
    }
}

@Suite struct ChatNamingTests {
    // MARK: The prompt

    @Test func instructionsReplaceTheBuiltInExamplePrefixes() {
        let guided = ChatNaming.prompt(instructions: abstractInstructions, task: "The relay push fails")
        #expect(guided.contains(abstractInstructions))
        #expect(guided.contains("they override everything else here"))
        #expect(!guided.contains("such as fix/") && !guided.contains("feat/"))

        let plain = ChatNaming.prompt(instructions: "  ", task: "The relay push fails")
        #expect(!plain.contains("<instructions>"))
        #expect(plain.contains("no type folder"))
    }

    @Test func prefixesAreReadFromTheInstructions() {
        #expect(ChatNaming.prefixes(in: abstractInstructions) == ["bugfix/", "feature/"])
        #expect(ChatNaming.prefixes(in: "Use fix/ for bugs and feat/ for features; fix/ again.") == ["fix/", "feat/"])
        #expect(ChatNaming.prefixes(in: "Branches look like `Chore/…` or (docs/).") == ["chore/", "docs/"])
        // Paths and links aren't prefixes.
        #expect(ChatNaming.prefixes(in: "Code lives in src/app; see https://example.com/naming, ./scripts/ and docs/.github") == [])
        #expect(ChatNaming.prefixes(in: "Keep titles short.") == [])
    }

    @Test func aBranchOutsideTheAllowedPrefixesIsMovedBehindTheFirst() {
        let allowed = ["bugfix/", "feature/"]
        #expect(ChatNaming.follows("feature/diff-stats", allowed: allowed))
        #expect(!ChatNaming.follows("fix/relay-image", allowed: allowed))
        #expect(ChatNaming.follows("fix/relay-image", allowed: []))
        let wrong = ChatNaming.Suggestion(title: "Fix the relay image", branch: "fix/relay-image")
        #expect(ChatNaming.corrected(wrong, allowed: allowed).branch == "bugfix/relay-image")
        let bare = ChatNaming.Suggestion(title: "Relay image", branch: "relay-image")
        #expect(ChatNaming.corrected(bare, allowed: allowed).branch == "bugfix/relay-image")
        let right = ChatNaming.Suggestion(title: "Diff stats", branch: "feature/diff-stats")
        #expect(ChatNaming.corrected(right, allowed: allowed) == right)
    }

    // MARK: Asking

    @Test func anAnswerWithAnAllowedPrefixIsUsedAsIs() async throws {
        let agent = try ScriptedAgent([claudeAnswer(title: "Fix the relay image push", branch: "bugfix/relay-image-push")])
        #expect(try await agent.suggest().get() == .init(title: "Fix the relay image push", branch: "bugfix/relay-image-push"))
        #expect(agent.calls == 1)
    }

    @Test func aWrongPrefixIsAskedForAgainNamingTheAllowedOnes() async throws {
        let agent = try ScriptedAgent([claudeAnswer(title: "Fix the relay image", branch: "fix/relay-image"),
                                       claudeAnswer(title: "Fix the relay image", branch: "bugfix/relay-image")])
        #expect(try await agent.suggest().get().branch == "bugfix/relay-image")
        #expect(agent.calls == 2)
        #expect(agent.prompt(2).contains("fix/relay-image, doesn't start with any of the prefixes the naming instructions allow: bugfix/, feature/"))
    }

    @Test func aSecondMissFallsBackToTheFirstAllowedPrefix() async throws {
        let agent = try ScriptedAgent([claudeAnswer(title: "Fix the relay image", branch: "fix/relay-image"),
                                       claudeAnswer(title: "Fix the relay image", branch: "hotfix/relay-image")])
        #expect(try await agent.suggest().get() == .init(title: "Fix the relay image", branch: "bugfix/relay-image"))
        #expect(agent.calls == 2)
    }

    @Test func aFailedCallIsTriedOnceMore() async throws {
        let agent = try ScriptedAgent([nil, claudeAnswer(title: "Show diff stats", branch: "feature/diff-stats")])
        #expect(try await agent.suggest().get().branch == "feature/diff-stats")
        #expect(agent.calls == 2)
    }

    @Test func twoFailedCallsSayWhy() async throws {
        let agent = try ScriptedAgent([nil, nil])
        #expect(await agent.suggest() == .failure(.init("Claude Code exited with an error: Not signed in.")))
        #expect(agent.calls == 2)

        let silent = try ScriptedAgent([#"{"type":"result","is_error":false,"result":"I can't help with that."}"#, "not json"])
        #expect(await silent.suggest() == .failure(.init("Claude Code's answer had no title in it.")))

        let refused = try ScriptedAgent([nil, #"{"type":"result","is_error":true,"result":"Credit balance is too low"}"#])
        #expect(await refused.suggest() == .failure(.init("Claude Code reported an error: Credit balance is too low")))
    }

    @Test(.timeLimit(.minutes(1))) func aCallThatTakesTooLongSaysSo() async throws {
        let agent = try ScriptedAgent(["sleep", "sleep"])
        #expect(await agent.suggest(timeout: .seconds(1)) == .failure(.init("Claude Code didn't answer within 1 seconds.")))
    }

    // MARK: Which agent names

    @Test func everyAgentNamesItsOwnChats() {
        for provider in ProviderRegistry.all {
            #expect(ChatNaming.namer(for: provider.id, installed: { _ in false })?.id == provider.id)
        }
    }

    @Test func anAgentThatCantNameHandsItToTheFirstInstalledOneThatCan() {
        #expect(ChatNaming.namer(for: "retired", installed: { _ in true })?.id == ProviderRegistry.all.first?.id)
        #expect(ChatNaming.namer(for: "retired", installed: { $0 == "opencode" })?.id == "opencode")
        #expect(ChatNaming.namer(for: "retired", installed: { _ in false }) == nil)
    }
}

/// Each agent's own naming call and how its answer is read.
@Suite struct ProviderNamingTests {
    @Test func claudeNamesWithHaikuAndNoTools() throws {
        let spec = try #require(ClaudeProvider().namingLaunch(prompt: "Name it", home: "/tmp/home", binary: nil, model: "opus"))
        #expect(spec.command == "claude" && spec.cwd == "/tmp/home")
        #expect(spec.args == ["-p", "--tools", "", "--model", "haiku", "--output-format", "json", "--no-session-persistence"])
        #expect(spec.stdinInitial == "Name it" && !spec.keepStdinOpen)

        let provider = ClaudeProvider()
        let fenced = #"{"type":"result","is_error":false,"result":"```json\n{\n  \"title\": \"Fix the login button alignment\",\n  \"branch\": \"fix/Login-Button\"\n}\n```"}"#
        #expect(provider.namingAnswer(fenced).flatMap(ChatNaming.parse) == .init(title: "Fix the login button alignment", branch: "fix/login-button"))
        #expect(provider.namingAnswer(#"{"is_error":true,"result":"{\"title\":\"x\",\"branch\":\"y\"}"}"#) == nil)
        #expect(provider.namingAnswer("not json") == nil)
        #expect(provider.namingError(#"{"is_error":true,"result":"Invalid API key"}"#) == "Invalid API key")
        #expect(provider.namingError(fenced) == nil)
    }

    @Test func codexNamesAtLowEffortInAReadOnlySandbox() throws {
        let spec = try #require(CodexProvider().namingLaunch(prompt: "-Name it", home: "/tmp/home", binary: "/bin/codex", model: "gpt-test"))
        #expect(spec.command == "/bin/codex")
        #expect(spec.args == ["exec", "--json", "-C", "/tmp/home", "--skip-git-repo-check", "-s", "read-only",
                              "-c", "model_reasoning_effort=\"low\"", "-m", "gpt-test", "--", "-Name it"])
        #expect(spec.stdinInitial == nil && !spec.keepStdinOpen)

        let output = """
            {"type":"thread.started","thread_id":"t_1"}
            {"type":"item.completed","item":{"type":"agent_message","text":"I will name it."}}
            {"type":"item.completed","item":{"type":"agent_message","text":"{\\"title\\":\\"Fix login button\\",\\"branch\\":\\"bugfix/login-button\\"}"}}
            {"type":"turn.completed"}
            """
        #expect(CodexProvider().namingAnswer(output).flatMap(ChatNaming.parse) == .init(title: "Fix login button", branch: "bugfix/login-button"))
        #expect(CodexProvider().namingAnswer(#"{"type":"turn.failed"}"#) == nil)
        #expect(CodexProvider().namingError(output) == nil)

        // The API's message, out of the JSON Codex wraps it in.
        let failed = """
            {"type":"item.completed","item":{"id":"item_0","type":"error","message":"Model metadata not found."}}
            {"type":"turn.started"}
            {"type":"turn.failed","error":{"message":"{\\"type\\":\\"error\\",\\"status\\":400,\\"error\\":{\\"type\\":\\"invalid_request_error\\",\\"message\\":\\"The 'gpt-test' model is not supported.\\"}}"}}
            """
        #expect(CodexProvider().namingError(failed) == "The 'gpt-test' model is not supported.")
        #expect(CodexProvider().namingError(#"{"type":"error","message":"Reconnecting…"}"#) == "Reconnecting…")
    }

    @Test func openCodeNamesThroughRunWithThePlanAgent() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let provider = OpenCodeProvider()
        let spec = try #require(provider.namingLaunch(prompt: "Name it", home: home, binary: nil, model: "anthropic/claude-sonnet-5"))
        #expect(spec.command == "opencode" && spec.cwd == home && !spec.keepStdinOpen)
        #expect(spec.args == ["run", "--format", "json", "--agent", "plan", "--dir", home, "--model", "anthropic/claude-sonnet-5", "Name it"])

        // Its configured small model comes first.
        try FileManager.default.createDirectory(atPath: home + "/.config/opencode", withIntermediateDirectories: true)
        try Data(#"{"model":"anthropic/claude-sonnet-5","small_model":"anthropic/claude-haiku-4-5"}"#.utf8)
            .write(to: URL(fileURLWithPath: home + "/.config/opencode/opencode.json"))
        let small = try #require(provider.namingLaunch(prompt: "-Name it", home: home, binary: "/opt/opencode", model: nil))
        #expect(small.command == "/opt/opencode")
        #expect(Array(small.args.suffix(4)) == ["--model", "anthropic/claude-haiku-4-5", "--", "-Name it"])
    }

    @Test func openCodesAnswerIsReadFromItsJSONEvents() throws {
        let url = try #require(Bundle.module.url(forResource: "opencode-naming", withExtension: "jsonl", subdirectory: "Fixtures"))
        let output = try String(contentsOf: url, encoding: .utf8)
        #expect(OpenCodeProvider().namingAnswer(output).flatMap(ChatNaming.parse)
            == .init(title: "Fix the relay image push", branch: "bugfix/relay-image-push"))
        let failed = #"{"type":"error","sessionID":"ses_a","error":{"name":"APIError","data":{"message":"unavailable"}}}"#
        #expect(OpenCodeProvider().namingAnswer(failed) == nil)
        #expect(OpenCodeProvider().namingError(failed) == "unavailable")
        #expect(OpenCodeProvider().namingError(output) == nil)
        #expect(OpenCodeProvider().namingAnswer("") == nil)
    }
}
