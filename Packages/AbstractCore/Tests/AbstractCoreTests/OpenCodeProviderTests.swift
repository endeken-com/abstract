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

@Suite("OpenCode compaction")
struct OpenCodeCompactionTests {
    /// `GET /session/{id}/message` after a compaction, from OpenCode 1.18.18, trimmed.
    static let messages = #"""
    [{"info":{"role":"user"},"parts":[{"type":"text","text":"Reply with just: ok"}]},
     {"info":{"role":"assistant","mode":"build","tokens":{"total":16151}},"parts":[{"type":"step-start"},{"type":"text","text":"ok"}]},
     {"info":{"role":"user"},"parts":[{"type":"compaction"}]},
     {"info":{"role":"assistant","mode":"compaction","summary":true,"tokens":{"total":785}},"parts":[{"type":"reasoning","text":"thinking"},{"type":"text","text":"## Objective\n- Reply ok."}]}]
    """#

    static func json(_ text: String) -> JSONValue { (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))) ?? .null }

    @Test func readsThePortItListensOn() {
        #expect(OpenCodeServer.port(fromLine: "opencode server listening on http://127.0.0.1:61070") == 61070)
        #expect(OpenCodeServer.port(fromLine: "Warning: OPENCODE_SERVER_PASSWORD is not set") == nil)
    }

    @Test func splitsTheModelAtItsFirstSlash() {
        #expect(OpenCodeServer.model("opencode/big-pickle")?.provider == "opencode")
        #expect(OpenCodeServer.model("opencode/big-pickle")?.model == "big-pickle")
        #expect(OpenCodeServer.model("openrouter/anthropic/claude-sonnet-5")?.provider == "openrouter")
        #expect(OpenCodeServer.model("openrouter/anthropic/claude-sonnet-5")?.model == "anthropic/claude-sonnet-5")
        #expect(OpenCodeServer.model("big-pickle") == nil)
        #expect(OpenCodeServer.model("/x") == nil)
    }

    @Test func theContextBeforeIsTheLastReplysTokens() {
        let before = Self.json(Self.messages).array.map { JSONValue.array(Array($0.prefix(2))) } ?? .null
        #expect(OpenCodeServer.contextTokens(messages: before) == 16151)
        #expect(OpenCodeServer.contextTokens(messages: Self.json(Self.messages)) == 16151, "the compaction's own reply doesn't count")
    }

    @Test func theSummaryIsTheCompactionReplysText() {
        #expect(OpenCodeServer.summary(messages: Self.json(Self.messages)) == "## Objective\n- Reply ok.")
        #expect(OpenCodeServer.summary(messages: Self.json("[]")) == nil)
    }

    @Test func readsErrorsAndStatus() {
        #expect(OpenCodeServer.errorMessage(#"{"name":"NotFoundError","data":{"message":"Session not found: ses_x"}}"#) == "Session not found: ses_x")
        #expect(OpenCodeServer.errorMessage("gateway down") == nil)
        #expect(OpenCodeServer.split("true\n200") == ("true", 200))
        #expect(OpenCodeServer.split("{\"a\":1}\nmore\n404") == ("{\"a\":1}\nmore", 404))
    }

    @Test func percentEncodesTheDirectoryQueryValueByHand() {
        // URLComponents.queryItems leaves `+` unescaped, and OpenCode reads a
        // literal `+` as a space; space, `&` and `#` must stay encoded too.
        #expect(OpenCodeServer.url(base: "http://127.0.0.1:4096", path: "/session/x/message",
                                   directory: "/Users/dev/a b/libc++&x#y")
                == "http://127.0.0.1:4096/session/x/message?directory=/Users/dev/a%20b/libc%2B%2B%26x%23y")
    }

    @Test func maxTimeIsWholeSecondsUntilTheDeadlineAtLeastOne() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(OpenCodeServer.maxTime(until: now.addingTimeInterval(120.4), from: now) == "120")
        #expect(OpenCodeServer.maxTime(until: now.addingTimeInterval(0.4), from: now) == "1", "clamped to at least 1")
        #expect(OpenCodeServer.maxTime(until: now, from: now) == nil, "at the deadline")
        #expect(OpenCodeServer.maxTime(until: now.addingTimeInterval(-5), from: now) == nil, "past the deadline")
    }

    @Test func noModelAnywhereSaysSo() async {
        let home = NSTemporaryDirectory() + "oc-\(UUID().uuidString)"
        let request = CompactionRequest(sessionId: "ses_x", cwd: NSTemporaryDirectory())
        await #expect(throws: AbstractError.message("OpenCode needs a model to compact with; choose one for this chat.")) {
            try await OpenCodeCompactor().compact(request, executor: HomeOnly(home: home))
        }
    }

    @Test func stoppingDuringSummarizeKillsCurlAndTheServer() async throws {
        let dir = NSTemporaryDirectory() + "oc-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let server = dir + "opencode"
        try "#!/bin/sh\necho $$ > \(dir)server.pid\necho 'opencode server listening on http://127.0.0.1:4096'\nexec sleep 30\n"
            .write(toFile: server, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: server)
        let request = CompactionRequest(sessionId: "ses_x", cwd: dir, model: "opencode/x", binaryOverride: server)
        let task = Task { try await OpenCodeCompactor().compact(request, executor: FakeCurl(dir: dir)) }
        let deadline = Date().addingTimeInterval(15)
        while !FileManager.default.fileExists(atPath: dir + "curl.pid"), Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        try await Task.sleep(for: .seconds(4)) // SIGTERM, then SIGKILL after the grace period.
        for name in ["curl.pid", "server.pid"] {
            let pid = try #require(Int32(String(contentsOfFile: dir + name, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
            #expect(kill(pid, 0) != 0, "\(name) is gone")
        }
    }

    @Test func openCodeCompactsThroughItsServer() {
        #expect(OpenCodeProvider().commands.extra.contains(.compact))
        guard case .sideChannel(let compactor)? = OpenCodeProvider().compaction else { Issue.record("no side channel"); return }
        #expect(compactor is OpenCodeCompactor)
    }
}

/// LocalExecutor with another home, so no real OpenCode config is read.
private struct HomeOnly: Executor {
    let home: String
    var homeDirectory: String { home }
    let base = LocalExecutor.shared
    func run(_ command: String, _ args: [String], cwd: String?) async throws -> ExecResult { try await base.run(command, args, cwd: cwd) }
    func spawn(_ spec: LaunchSpec, onLine: @escaping @Sendable (OutputLine) -> Void,
               onExit: @escaping @Sendable (Int32?) -> Void) throws -> RunningProcess { try base.spawn(spec, onLine: onLine, onExit: onExit) }
    func fileExists(_ path: String) -> Bool { base.fileExists(path) }
    func readFile(_ path: String) throws -> String { try base.readFile(path) }
    func createDirectory(_ path: String) throws { try base.createDirectory(path) }
    func removeItem(_ path: String) throws { try base.removeItem(path) }
    func which(_ binary: String) async -> String? { await base.which(binary) }
}

/// LocalExecutor whose `curl` answers the message list at once and blocks on
/// `summarize`, noting its pid, as OpenCode's does for minutes.
private struct FakeCurl: Executor {
    let dir: String
    var homeDirectory: String { dir }
    let base = LocalExecutor.shared
    func run(_ command: String, _ args: [String], cwd: String?) async throws -> ExecResult { try await base.run(command, args, cwd: cwd) }
    func spawn(_ spec: LaunchSpec, onLine: @escaping @Sendable (OutputLine) -> Void,
               onExit: @escaping @Sendable (Int32?) -> Void) throws -> RunningProcess {
        guard spec.command == "curl" else { return try base.spawn(spec, onLine: onLine, onExit: onExit) }
        let script = "for a; do last=$a; done; case $last in *summarize*) echo $$ > \(dir)curl.pid; exec sleep 30;; *) printf '[]\\n200';; esac"
        let fake = LaunchSpec(command: "/bin/sh", args: ["-c", script, "curl"] + spec.args, cwd: spec.cwd, keepStdinOpen: false)
        return try base.spawn(fake, onLine: onLine, onExit: onExit)
    }
    func fileExists(_ path: String) -> Bool { base.fileExists(path) }
    func readFile(_ path: String) throws -> String { try base.readFile(path) }
    func createDirectory(_ path: String) throws { try base.createDirectory(path) }
    func removeItem(_ path: String) throws { try base.removeItem(path) }
    func which(_ binary: String) async -> String? { await base.which(binary) }
}
