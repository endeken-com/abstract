import Foundation
import Testing
@testable import AbstractCore

@Suite("Gemini through Antigravity CLI")
struct GeminiProviderTests {
    private var provider: ScriptedProvider { get throws { try #require(AgentPlugins.shared.anyAgent("gemini")) } }
    private let conversation = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"

    private func events(_ fixture: String, exit: Int32 = 0) throws -> [AgentEvent] {
        let url = try #require(Bundle.module.url(forResource: "gemini-\(fixture)", withExtension: "jsonl", subdirectory: "Fixtures"))
        let parser = try provider.makeParser()
        var output: [AgentEvent] = []
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            output += parser.feed(String(line), stream: .stdout)
        }
        return output + parser.onExit(code: exit)
    }

    @Test func bundledManifestUsesOnlyVerifiedCapabilities() throws {
        let gemini = try provider
        #expect(gemini.binary == "agy")
        #expect(gemini.detectArgs == ["--version"])
        #expect(gemini.install?.contains("antigravity.google/cli/install.sh") == true)
        #expect(gemini.iconURL?.lastPathComponent == "icon.svg")
        #expect(gemini.logoAsset == "ProviderGemini")
        #expect(gemini.followUpMode == .respawn)
        #expect(gemini.can("session.persistence") && gemini.can("models.discover") && gemini.can("naming"))
        #expect(!gemini.can("permission") && !gemini.can("permission.mode") && !gemini.can("prompt.image"))
        #expect(gemini.skillDelivery == nil && gemini.toolServerSupport == .none)
    }

    @Test func launchAndResumeUseTheVerifiedHeadlessFlags() throws {
        let gemini = try provider
        let ctx = LaunchContext(cwd: "/workspace", prompt: "Say hello", permissionPolicy: .ask,
                                model: "gemini-3.8-flash-low", instructions: "Be brief")
        let first = gemini.buildLaunch(ctx)
        #expect(first.command == "agy" && first.cwd == "/workspace" && !first.keepStdinOpen)
        #expect(first.args == ["--print", "Be brief\n\nSay hello", "--output-format", "stream-json",
                               "--model", "gemini-3.8-flash-low"])
        let resumed = gemini.buildResume(ctx, resumeId: conversation)
        #expect(resumed.args == first.args + ["--conversation", conversation])
        #expect(gemini.buildLaunch(LaunchContext(cwd: "/workspace", prompt: "x", permissionPolicy: .autoEdits))
            .args.suffix(2) == ["--mode", "accept-edits"])
        #expect(gemini.buildLaunch(LaunchContext(cwd: "/workspace", prompt: "x", permissionPolicy: .plan))
            .args.suffix(2) == ["--mode", "plan"])
        #expect(gemini.buildLaunch(LaunchContext(cwd: "/workspace", prompt: "x", permissionPolicy: .bypass))
            .args.last == "--dangerously-skip-permissions")
    }

    @Test func catalogueUsesOnlyGeminiIdsFromTheAccount() throws {
        let gemini = try provider
        let output = """
        gemini-3.8-flash-high\tGemini 3.8 Flash (High)
        gemini-3.8-flash-medium\tGemini 3.8 Flash (Medium)
        claude-sonnet-4-6\tClaude Sonnet 4.6 (Thinking)
        gemini-3.8-flash-low\tGemini 3.8 Flash (Low)
        """
        let value = try #require(Agents.call(gemini, "GeminiAgent.catalog", .string(output)))
        let models = try #require(AgentEventJSON.decodeCodable(ModelCatalog.self, value))
        #expect(models.models.map(\.id) == ["gemini-3.8-flash-high", "gemini-3.8-flash-medium", "gemini-3.8-flash-low"])
        #expect(models.accountDefault?.id == "gemini-3.8-flash-medium")
        #expect(gemini.fallbackModels.models.map(\.id) == models.models.map(\.id))
    }

    @Test func namingUsesStrictHeadlessPermissionsAndReadsTheResult() throws {
        let gemini = try provider
        #expect(ChatNaming.namer(for: "gemini", installed: { _ in false })?.id == "gemini")
        let spec = try #require(gemini.namingLaunch(prompt: "Name this chat", home: "/tmp/home", binary: nil,
                                                     model: "gemini-3.8-flash-low"))
        #expect(spec.command == "agy" && spec.cwd == "/tmp/home")
        #expect(spec.args == ["--print", "Name this chat", "--output-format", "json", "--model", "gemini-3.8-flash-low",
                               "--disable-slash-commands", "--settings", #"{"toolPermission":"strict"}"#])
        #expect(spec.stdinInitial == nil && !spec.keepStdinOpen)

        let success = #"{"status":"SUCCESS","response":"{\"title\":\"Add Gemini chats\",\"branch\":\"feature/gemini-chats\"}"}"#
        #expect(gemini.namingAnswer(success).flatMap(ChatNaming.parse) ==
                .init(title: "Add Gemini chats", branch: "feature/gemini-chats"))
        #expect(gemini.namingError(success) == nil)
        let failure = #"{"status":"ERROR","error":"Authentication required","response":""}"#
        #expect(gemini.namingAnswer(failure) == nil)
        #expect(gemini.namingError(failure) == "Authentication required")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ABSTRACT_GEMINI_E2E"] != nil))
    func signedInDiscoveryRunsThroughTheHostExecutor() async throws {
        let gemini = try provider
        let models = await gemini.discoverModels(executor: LocalExecutor.shared, binary: nil)
        #expect(models?.models.contains { $0.id == "gemini-3.8-flash-medium" } == true)
        #expect(models?.models.allSatisfy { $0.id.hasPrefix("gemini-") } == true)
    }

    @Test func liveFixtureFoldsTextToolsUsageAndCompletion() throws {
        let output = try events("turn1")
        #expect(output.contains(.sessionId(conversation)))
        #expect(output.contains(.toolUse(id: conversation + ":2", name: "read_file",
                                         input: .object(["Path": .string("/workspace/README.txt"),
                                                         "file_path": .string("/workspace/README.txt")]), edit: nil)))
        #expect(output.contains(.toolResult(toolUseId: conversation + ":2", output: "1 lines, 12 bytes", isError: false, edit: nil)))
        #expect(output.contains(.text(role: .assistant, text: "amber maple sky\n", blockId: "agy-text-3", partial: false)))
        #expect(output.contains(.usage(UsageTotals(inputTokens: 19403, outputTokens: 170, cacheRead: 0, cacheWrite: 0),
                                       costUsd: nil, durationMs: nil, turns: nil)))
        #expect(output.contains(.status(.finished, detail: nil)))
    }

    @Test func resumedFixtureKeepsIdAndUsesOnlyCurrentTurnUsage() throws {
        let output = try events("turn2")
        #expect(output.contains(.sessionId(conversation)))
        #expect(output.contains(.text(role: .assistant, text: "The exact two words were:\n\namber maple\n", blockId: "agy-text-6", partial: false)))
        let usage = output.compactMap { event -> UsageTotals? in
            if case let .usage(totals, _, _, _) = event { return totals }
            return nil
        }
        #expect(usage.count == 1)
        #expect(usage[0].inputTokens < 19403, "the result's cumulative session usage must not be charged to this turn")
    }

    @Test func errorsAndUnknownLinesDoNotCrashAReplay() throws {
        let output = try events("error", exit: 1)
        #expect(output.contains { if case let .error(message) = $0 { message.contains("gemini-not-a-model") } else { false } })
        #expect(output.contains(.status(.errored, detail: nil)))
        let parser = try provider.makeParser()
        #expect(parser.feed(#"{"event":"future_event","payload":{}}"#, stream: .stdout) ==
                [.raw(line: #"{"event":"future_event","payload":{}}"#, stream: .stdout)])
        #expect(parser.feed("not json", stream: .stdout) == [.raw(line: "not json", stream: .stdout)])
        #expect(parser.onExit(code: 130).contains(.status(.errored, detail: nil)))
    }
}
