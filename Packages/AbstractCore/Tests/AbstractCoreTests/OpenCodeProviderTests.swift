import Foundation
import Testing
@testable import AbstractCore

@Suite struct OpenCodeProviderTests {
    let provider = OpenCodeProvider()

    @Test func launchesAndResumesWithModelVariantAndFiles() {
        let context = LaunchContext(cwd: "/tmp/work", prompt: "Fix this", permissionPolicy: .ask,
                                    model: "openai/gpt-5.4", effort: "high", images: ["/tmp/image.png"])
        let first = provider.buildLaunch(context)
        #expect(first.command == "opencode")
        #expect(first.args == ["run", "--format", "json", "--thinking", "--dir", "/tmp/work", "--model", "openai/gpt-5.4", "--variant", "high",
                               "--file", "/tmp/image.png", "Fix this"])
        #expect(first.cwd == "/tmp/work")
        #expect(!first.keepStdinOpen)
        #expect(provider.followUpMode == .respawn)

        let resumed = provider.buildResume(context, resumeId: "ses_123")
        #expect(Array(resumed.args.prefix(8)) == ["run", "--format", "json", "--thinking", "--dir", "/tmp/work", "--session", "ses_123"])
        #expect(resumed.args.last == "Fix this")
    }

    @Test func onlyFullAutonomyEnablesAutoApproval() {
        let ask = LaunchContext(cwd: "/tmp/work", prompt: "hello", permissionPolicy: .ask)
        var edits = ask; edits.permissionPolicy = .autoEdits
        var bypass = ask; bypass.permissionPolicy = .bypass
        #expect(!provider.buildLaunch(ask).args.contains("--auto"))
        #expect(!provider.buildLaunch(edits).args.contains("--auto"))
        #expect(provider.buildLaunch(bypass).args.contains("--auto"))
        #expect(provider.permissionDetail(.ask) != PermissionPolicy.ask.detail)
        #expect(ClaudeProvider().permissionDetail(.ask) == PermissionPolicy.ask.detail)
    }

    @Test func readsTheConfiguredModel() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: home) }
        #expect(provider.configuredDefaultModel(home: home) == nil)
        try FileManager.default.createDirectory(atPath: home + "/.config/opencode", withIntermediateDirectories: true)
        try Data(#"{"model":"anthropic/claude-sonnet-5"}"#.utf8).write(to: URL(fileURLWithPath: home + "/.config/opencode/opencode.json"))
        #expect(provider.configuredDefaultModel(home: home) == "anthropic/claude-sonnet-5")
    }

    @Test func parsesRecordedRunEvents() {
        let parser = provider.makeParser()
        let start = #"{"type":"step_start","sessionID":"ses_a","part":{"type":"step-start"}}"#
        let tool = #"{"type":"tool_use","sessionID":"ses_a","part":{"type":"tool","tool":"read","callID":"call_1","state":{"status":"completed","input":{"filePath":"a.txt"},"output":"banana"}}}"#
        let text = #"{"type":"text","sessionID":"ses_a","part":{"id":"prt_1","type":"text","text":"banana"}}"#
        let finish = #"{"type":"step_finish","sessionID":"ses_a","part":{"type":"step-finish","tokens":{"input":10,"output":2,"cache":{"read":3,"write":0}},"cost":0}}"#
        #expect(parser.feed(start, stream: .stdout) == [.sessionId("ses_a"), .status(.running, detail: nil)])
        #expect(parser.feed(tool, stream: .stdout) == [
            .toolUse(id: "call_1", name: "read", input: .object(["filePath": .string("a.txt")]), edit: nil),
            .toolResult(toolUseId: "call_1", output: "banana", isError: false, edit: nil),
        ])
        #expect(parser.feed(text, stream: .stdout) == [.text(role: .assistant, text: "banana", blockId: "prt_1", partial: false)])
        #expect(parser.feed(finish, stream: .stdout) == [
            .usage(UsageTotals(inputTokens: 10, outputTokens: 2, cacheRead: 3, cacheWrite: 0),
                   costUsd: 0, durationMs: nil, turns: nil),
        ])
        #expect(parser.onExit(code: 0) == [.status(.finished, detail: nil)])
    }

    @Test func discoversModelVariantsFromVerboseCatalog() throws {
        let output = """
        openai/gpt-5.4
        {
          "name": "GPT-5.4",
          "variants": {"high": {"reasoningEffort": "high"}, "low": {"reasoningEffort": "low"}, "fast": {"latency": "fast"}}
        }
        opencode/free
        {"name":"Free","variants":{}}
        """
        let catalog = try #require(OpenCodeProvider.modelCatalog(from: output))
        #expect(catalog.models.map(\.id) == ["openai/gpt-5.4", "opencode/free"])
        #expect(catalog.models[0].label == "GPT-5.4")
        #expect(catalog.models[0].efforts == ["low", "high"])
        #expect(catalog.models[1].efforts.isEmpty)
    }
}
