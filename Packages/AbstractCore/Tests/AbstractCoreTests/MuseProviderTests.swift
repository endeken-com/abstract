import Foundation
import Testing
@testable import AbstractCore

@Suite("Muse Code")
struct MuseProviderTests {
    let provider = MuseProvider()

    private func context(_ policy: PermissionPolicy = .ask) -> LaunchContext {
        LaunchContext(cwd: "/tmp/clean-worktree", prompt: "Say hello.", permissionPolicy: policy)
    }

    private static func fixture(_ name: String) throws -> [AgentEvent] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures"))
        let parser = MuseProvider().makeParser()
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n").flatMap { parser.feed(String($0), stream: .stdout) }
    }

    /// The session id a launch payload asks the host to start or resume.
    private func sessionId(in spec: LaunchSpec) throws -> String {
        let lines = try #require(spec.stdinInitial).split(separator: "\n")
        for line in lines {
            let msg = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
            if msg["method"]?.string == "session/start" || msg["method"]?.string == "session/resume" {
                return try #require(msg["params"]?["sessionId"]?.string)
            }
        }
        throw NSError(domain: "test", code: 1)
    }

    @Test func startsAndResumesInTheSameWorktree() throws {
        let start = provider.buildLaunch(context())
        #expect(start.command == "muse")
        #expect(start.cwd == "/tmp/clean-worktree")
        #expect(start.args == ["serve", "--trust-workspace", "--disable-write", "--disable-shell"])
        #expect(start.keepStdinOpen)
        #expect(provider.followUpMode == .stdin)
        let initial = try #require(start.stdinInitial)
        #expect(initial.contains(#""method":"initialize""#))
        #expect(initial.contains(#""method":"session/start""#))
        #expect(initial.contains(#""workspaceRoot":"/tmp/clean-worktree""#))
        #expect(initial.contains(#""approvalMode":"denyUnmatched""#))
        // No turn yet: the host answers concurrently, so the turn is only
        // sent once the session is confirmed loaded.
        #expect(!initial.contains("turn/start"))
        // The prompt never rides in argv, where any process could read it.
        #expect(!start.args.contains { $0.contains("Say hello.") })

        let resume = provider.buildResume(context(), resumeId: "session-1")
        #expect(resume.cwd == start.cwd)
        #expect(resume.args == start.args)
        let resumed = try #require(resume.stdinInitial)
        #expect(resumed.contains(#""method":"session/resume""#))
        #expect(resumed.contains(#""sessionId":"session-1""#))
        #expect(resumed.contains(#""excludeItems":true"#))
    }

    @Test func mintedIdsAreUUIDv7() throws {
        let id = try sessionId(in: provider.buildLaunch(context()))
        let parts = id.split(separator: "-")
        #expect(parts.count == 5)
        #expect(parts[2].hasPrefix("7"))
        #expect(["8", "9", "a", "b"].contains { parts[3].hasPrefix($0) })
        #expect(try sessionId(in: provider.buildLaunch(context())) != id)
    }

    @Test func choosesModelAndKeepsTheCLIConfiguredDefault() throws {
        var selected = context()
        selected.model = "muse-wonder-1.0"
        selected.effort = "high"
        selected.binaryOverride = "/opt/muse"
        let spec = provider.buildLaunch(selected)
        #expect(spec.command == "/opt/muse")
        #expect(try #require(spec.stdinInitial).contains(#""modelId":"muse-wonder-1.0""#))
        #expect(try !#require(provider.buildLaunch(context()).stdinInitial).contains("modelId"))
        #expect(provider.fallbackModels.models.map(\.id) == ["muse-wonder-1.0"])
    }

    @Test func readsTheCLIsConfiguredModelWithoutStoringCredentials() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("muse-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".config/muse"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try #"{"model":"muse-wonder-1.0"}"#.write(to: home.appendingPathComponent(".config/muse/settings.json"),
                                                    atomically: true, encoding: .utf8)
        #expect(provider.configuredDefaultModel(home: home.path) == "muse-wonder-1.0")
        #expect(provider.configuredDefaultModel(home: home.path + "/missing") == nil)
    }

    @Test func mapsEachPermissionChoiceWithoutWideningAccess() throws {
        let ask = provider.buildLaunch(context(.ask))
        #expect(ask.args.contains("--disable-write") && ask.args.contains("--disable-shell"))
        #expect(!ask.args.contains("--disable-sandbox"))
        #expect(try #require(ask.stdinInitial).contains(#""approvalMode":"denyUnmatched""#))

        let edits = provider.buildLaunch(context(.autoEdits))
        #expect(!edits.args.contains("--disable-write") && !edits.args.contains("--disable-shell"))
        #expect(!edits.args.contains("--disable-sandbox"))
        // Commands are refused outright, not held for an approval Abstract
        // cannot answer.
        #expect(try #require(edits.stdinInitial).contains(#""approvalMode":"denyUnmatched""#))

        let bypass = provider.buildLaunch(context(.bypass))
        #expect(bypass.args.contains("--disable-sandbox"))
        #expect(try #require(bypass.stdinInitial).contains(#""approvalMode":"allowAll""#))
        #expect(provider.permissionDetail(.ask).contains("read-only"))
        #expect(provider.permissionDetail(.autoEdits).contains("cannot answer"))
        #expect(TurnStop.action(provider, status: .running, requestId: "stop") == .terminate)
    }

    @Test func firstTurnIsSentOnlyOnceTheSessionIsLoaded() throws {
        var ctx = context(.bypass)
        ctx.model = "muse-wonder-1.0"
        ctx.effort = "high"
        let spec = provider.buildLaunch(ctx)
        let id = try sessionId(in: spec)
        let parser = try #require(provider.makeParser() as? MuseParser)
        #expect(parser.takePendingInput().isEmpty)
        let reply = #"{"jsonrpc":"2.0","id":2,"result":{"session":{"sessionId":""# + id
            + #"","modelId":"muse-wonder-1.0","workspaceRoot":"/tmp/clean-worktree"}}}"#
        let events = parser.feed(reply, stream: .stdout)
        #expect(events.contains(.sessionId(id)))
        let sent = parser.takePendingInput()
        #expect(sent.count == 1)
        let turn = try JSONDecoder().decode(JSONValue.self, from: Data(sent[0].utf8))
        #expect(turn["method"]?.string == "turn/start")
        #expect(turn["params"]?["sessionId"]?.string == id)
        #expect(turn["params"]?["reasoningEffort"]?.string == "high")
        #expect(turn["params"]?["input"]?.array?.first?["text"]?.string == "Say hello.")
        #expect(parser.takePendingInput().isEmpty)
    }

    @Test func replayingTheSessionReplyDoesNotSpendTheFirstTurn() throws {
        let spec = provider.buildLaunch(context(.bypass))
        let id = try sessionId(in: spec)
        let reply = #"{"jsonrpc":"2.0","id":2,"result":{"session":{"sessionId":""# + id + #"","modelId":"muse-wonder-1.0"}}}"#
        // The log is folded again in this same process when the chat opens;
        // that parser never drains, and the live one must still get its turn.
        _ = provider.makeParser().feed(reply, stream: .stdout)
        let live = try #require(provider.makeParser() as? MuseParser)
        _ = live.feed(reply, stream: .stdout)
        #expect(live.takePendingInput().count == 1)
        // Once drained it is gone: a later relaunch registers its own turn.
        let again = try #require(provider.makeParser() as? MuseParser)
        _ = again.feed(reply, stream: .stdout)
        #expect(again.takePendingInput().isEmpty)
    }

    @Test func resumedChatWithANewModelSwitchesBeforeItsTurn() throws {
        var ctx = context(.bypass)
        ctx.model = "muse-wonder-full-1.0"
        _ = provider.buildResume(ctx, resumeId: "session-9")
        let parser = try #require(provider.makeParser() as? MuseParser)
        let reply = #"{"jsonrpc":"2.0","id":2,"result":{"session":{"sessionId":"session-9","modelId":"muse-wonder-1.0"}}}"#
        _ = parser.feed(reply, stream: .stdout)
        let sent = parser.takePendingInput()
        #expect(sent.count == 2)
        #expect(sent[0].contains(#""method":"session/setModel""#))
        #expect(sent[0].contains(#""modelId":"muse-wonder-full-1.0""#))
        #expect(sent[1].contains(#""method":"turn/start""#))
    }

    @Test func followUpsNameTheirSession() throws {
        let line = try #require(provider.buildUserMessage("Again.", images: [], sessionId: "session-1"))
        let msg = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
        #expect(msg["method"]?.string == "turn/start")
        #expect(msg["params"]?["sessionId"]?.string == "session-1")
        #expect(msg["params"]?["input"]?.array?.first?["text"]?.string == "Again.")
        #expect(provider.buildUserMessage("Again.", images: [], sessionId: nil) == nil)
        #expect(provider.buildUserMessage("Again.") == nil)
    }

    @Test func cleanCLIRecordingShowsStartAnswerAndCompletion() throws {
        let events = try Self.fixture("muse-echo-start")
        #expect(events.contains(.sessionId("11111111-1111-4111-8111-111111111111")))
        #expect(events.contains(.status(.running, detail: nil)))
        #expect(events.contains(.text(role: .assistant, text: "echo: Hello from a clean test session.",
                                     blockId: "01a1471b-894b-7ff0-85e0-e05e6f1a7765", partial: true)))
        #expect(events.contains(.status(.finished, detail: nil)))
    }

    @Test func cleanCLIRecordingResumesTheSession() throws {
        let events = try Self.fixture("muse-echo-resume")
        #expect(events.contains(.sessionId("11111111-1111-4111-8111-111111111111")))
        var finalTexts: [String] = []
        for case let .text(_, text, _, false) in events { finalTexts.append(text) }
        #expect(finalTexts == ["echo: A second clean turn."])
    }

    /// A clean Muse CLI emitted this stream while a local fake model returned
    /// a read_file call. No model account or real profile entered the fixture.
    @Test func cliRecordingShowsToolAndAnswer() throws {
        let events = try Self.fixture("muse-mock-tool")
        #expect(events.contains(.toolUse(id: "call_test", name: "read_file", input: .object([:]), edit: nil)))
        #expect(events.contains(.toolResult(toolUseId: "call_test",
                                            output: "Read text file `hello.txt`.\n1|hello from the clean workspace",
                                            isError: false, edit: nil)))
        #expect(events.contains { if case let .text(.assistant, text, _, false) = $0 {
            text == "I read hello.txt."
        } else { false } })
        #expect(events.contains(.status(.finished, detail: nil)))
    }

    @Test func signedInWonderRecordingShowsToolAnswerAndResume() throws {
        let first = try Self.fixture("muse-wonder-start")
        let second = try Self.fixture("muse-wonder-resume")
        let firstId = try #require(first.compactMap { if case let .sessionId(id) = $0 { id } else { nil } }.first)
        let secondId = try #require(second.compactMap { if case let .sessionId(id) = $0 { id } else { nil } }.first)
        #expect(firstId == secondId)
        #expect(first.contains { if case let .toolUse(_, name, _, _) = $0 { name == "read_file" } else { false } })
        #expect(first.contains { if case let .toolResult(_, text, false, _) = $0 {
            text.contains("hello from the clean workspace")
        } else { false } })
        #expect(first.contains { if case let .text(.assistant, text, _, false) = $0 {
            text == "hello from the clean workspace"
        } else { false } })
        #expect(second.contains { if case let .text(.assistant, text, _, false) = $0 { text == "hello.txt" } else { false } })
    }

    /// Recorded from `muse serve` in a clean /tmp workspace, then stripped
    /// of the real home directory. One turn: read, search, shell, edit,
    /// create, and a read that fails.
    @Test func serveRecordingShowsFilesChangesAndSearches() throws {
        let events = try Self.fixture("muse-serve-tools")
        #expect(events.contains(.sessionId("01a14729-33bd-76a3-a92f-67c07ae22697")))
        #expect(events.contains(.status(.running, detail: nil)))
        #expect(events.contains(.status(.idle, detail: nil)))

        var uses: [String: JSONValue] = [:]
        var results: [String: Bool] = [:]
        for event in events {
            if case let .toolUse(id, _, input, _) = event { uses[id] = input }
            if case let .toolResult(id, _, isError, _) = event { results[id] = isError }
        }
        var names: [String] = []
        for case let .toolUse(_, name, _, _) in events { names.append(name) }
        #expect(names == ["read_file", "search", "bash", "edit_file", "write_file", "read_file"])
        // Every call is answered exactly once, under its own id.
        #expect(Set(uses.keys) == Set(results.keys))
        #expect(uses.values.contains(.object(["path": .string("hello.txt")])))
        #expect(uses.values.contains(.object(["pattern": .string("needle")])))
        #expect(uses.values.contains(.object(["path": .string("hello.txt"),
                                               "find": .string("second line"), "replace": .string("changed line")])))
        #expect(uses.values.contains(.object(["path": .string("made.txt"), "content": .string("made")])))
        #expect(uses.values.contains { $0["command"]?.string == "echo probe-shell-ok" })
        // The missing file fails; everything else completes.
        let failed = try #require(uses.first { $0.value == .object(["path": .string("missing-nope.txt")]) }?.key)
        #expect(results[failed] == true)
        #expect(results.filter { $0.key != failed }.values.allSatisfy { !$0 })
        #expect(events.contains { if case let .toolResult(id, text, true, _) = $0 {
            id == failed && text.contains("No such file or directory")
        } else { false } })
        #expect(events.contains { if case let .text(.assistant, text, _, false) = $0 { text == "done" } else { false } })

        // Through the timeline, the edit and the new file carry their previews.
        var timeline = Timeline()
        timeline.append(contentsOf: events)
        var previews: [String: EditPreview] = [:]
        for entry in timeline.entries {
            if case let .toolUse(_, name, _, edit) = entry.event, let edit { previews[name] = edit }
        }
        #expect(previews["edit_file"]?.filePath == "hello.txt")
        #expect(previews["edit_file"]?.lines.map(\.content) == ["second line", "changed line"])
        #expect(previews["write_file"]?.filePath == "made.txt")
        #expect(previews["write_file"]?.lines.map(\.content) == ["made"])
    }

    /// The same session resumed on a fresh host: web search and fetch arrive
    /// as ordinary tool calls with their query and URL.
    @Test func serveResumeShowsWebSearchAndFetch() throws {
        let events = try Self.fixture("muse-serve-resume")
        #expect(events.contains(.sessionId("01a14729-33bd-76a3-a92f-67c07ae22697")))
        #expect(events.contains(.toolUse(id: "call_01a1481985af7207b6871ad7c24d02cb", name: "web_search",
                                         input: .object(["query": .string("current Swift version")]), edit: nil)))
        #expect(events.contains(.toolUse(id: "call_01a1481999837281ac913b17a80dd6ff", name: "web_fetch",
                                         input: .object(["url": .string("https://example.com")]), edit: nil)))
        #expect(events.contains { if case let .toolResult(_, text, false, _) = $0 {
            text.contains("Example Domain")
        } else { false } })
        #expect(events.contains(.status(.idle, detail: nil)))
    }

    /// The logged serve lines fold to the same events offline, every time:
    /// what a relaunch, a paired Mac and the phone rebuild from.
    @Test func serveLogRefoldsToTheSameEvents() throws {
        #expect(try Self.fixture("muse-serve-tools") == Self.fixture("muse-serve-tools"))
        #expect(try Self.fixture("muse-serve-resume") == Self.fixture("muse-serve-resume"))
    }

    @Test func serveFoldKeepsUnparsableArgumentsHonest() {
        let parser = provider.makeParser()
        // A completed call that was never started, with arguments that are
        // not JSON: the call and its output survive, no target is invented.
        let line = #"{"jsonrpc":"2.0","method":"item/completed","params":{"item":{"itemId":"i1","kind":"toolCall","revision":2,"status":"completed","tool":"read_file","callId":"c1","args":"{path: hello.txt","visibleOutput":"the output"}}}"#
        #expect(parser.feed(line, stream: .stdout) == [
            .toolUse(id: "c1", name: "read_file", input: .object([:]), edit: nil),
            .toolResult(toolUseId: "c1", output: "the output", isError: false, edit: nil),
        ])
        // An older revision of the same call changes nothing.
        let stale = #"{"jsonrpc":"2.0","method":"item/started","params":{"item":{"itemId":"i1","kind":"toolCall","revision":1,"status":"inProgress","tool":"read_file","callId":"c1","args":"{}"}}}"#
        #expect(parser.feed(stale, stream: .stdout).isEmpty)
    }

    @Test func serveFoldAccumulatesStreamedOutput() {
        let parser = provider.makeParser()
        _ = parser.feed(#"{"jsonrpc":"2.0","method":"item/started","params":{"item":{"itemId":"i2","kind":"toolCall","revision":1,"status":"inProgress","tool":"bash","callId":"c2","args":"{\"command\":\"echo hi\"}"}}}"#, stream: .stdout)
        #expect(parser.feed(#"{"jsonrpc":"2.0","method":"item/delta","params":{"itemId":"i2","field":"output","delta":"hi\n"}}"#, stream: .stdout).isEmpty)
        // The settled item carries no output of its own; the streamed text is the result.
        #expect(parser.feed(#"{"jsonrpc":"2.0","method":"item/completed","params":{"item":{"itemId":"i2","kind":"toolCall","revision":2,"status":"completed","tool":"bash","callId":"c2","args":"{}"}}}"#, stream: .stdout)
            == [.toolResult(toolUseId: "c2", output: "hi\n", isError: false, edit: nil)])
    }

    @Test func serveTurnFailureNamesTheModelProblem() {
        let line = #"{"jsonrpc":"2.0","method":"turn/completed","params":{"sessionId":"s","turnId":"t","terminal":"failed","reason":"model `muse-does-not-exist` does not exist or you lack access"}}"#
        let events = provider.makeParser().feed(line, stream: .stdout)
        #expect(events.contains(.error("Muse Code cannot use this model. Choose another model in the chat. model `muse-does-not-exist` does not exist or you lack access")))
        #expect(events.contains(.status(.errored, detail: nil)))
    }

    @Test func cliFailureIsAnErrorInsteadOfAnEmptyAnswer() throws {
        let events = try Self.fixture("muse-mock-failure")
        #expect(events.contains(.error("your API key from META_API_KEY was rejected — update or unset it")))
        #expect(events.contains(.status(.errored, detail: nil)))
    }

    @Test func unavailableModelOffersAChoiceTheUserCanTake() {
        let line = #"{"stream":{"kind":"session","id":"s"},"payload_type":"run.terminal.failed","payload":{"reason":"model `muse-does-not-exist` does not exist or you lack access"}}"#
        let events = provider.makeParser().feed(line, stream: .stdout)
        #expect(events.contains(.error("Muse Code cannot use this model. Choose another model in the chat. model `muse-does-not-exist` does not exist or you lack access")))
        #expect(events.contains(.status(.errored, detail: nil)))
    }

    @Test func failuresAndUnknownRecordsStayVisible() {
        let parser = provider.makeParser()
        #expect(parser.feed("missing meta credentials: run muse login", stream: .stderr)
            == [.raw(line: "missing meta credentials: run muse login", stream: .stderr)])
        #expect(parser.onExit(code: 1).contains(.error("Muse Code needs sign-in. Run muse login on this Mac, then try again.")))
        let other = provider.makeParser()
        let unknown = #"{"stream":{"kind":"session","id":"s"},"payload_type":"new.event","payload":{}}"#
        #expect(other.feed(unknown, stream: .stdout).contains(.raw(line: unknown, stream: .stdout)))
    }

    @Test func modelCatalogOnlyOffersRowsExposedByTheCLI() {
        let response = #"{"id":2,"jsonrpc":"2.0","result":{"models":[{"modelId":"muse-wonder-1.0","displayLabel":"Muse Wonder","description":"Complex coding","isDefault":true,"variants":["low","high"],"defaultReasoningEffort":"high"},{"modelId":"muse-wonder-full-1.0","displayLabel":"Muse Wonder Full","isDefault":false,"variants":["high"]}]}}"#
        let catalog = MuseModelDiscovery.catalog(response)
        #expect(catalog?.models.map(\.id) == ["muse-wonder-1.0", "muse-wonder-full-1.0"])
        #expect(catalog?.accountDefault?.id == "muse-wonder-1.0")
        #expect(catalog?.models.first?.defaultEffort == "high")
        let fullOnly = #"{"id":2,"result":{"models":[{"modelId":"muse-wonder-full-1.0","isDefault":false}]}}"#
        #expect(MuseModelDiscovery.catalog(fullOnly)?.models.map(\.id)
            == ["muse-wonder-1.0", "muse-wonder-full-1.0"])
        #expect(MuseModelDiscovery.catalog(#"{"id":2,"result":{"models":[]}}"#) == nil)
    }

    @Test func namingUsesTheEmptyPresetAndReadsTheTerminalAnswer() throws {
        let spec = try #require(provider.namingLaunch(prompt: "Name this chat", home: "/tmp/clean-worktree",
                                                      binary: "/opt/muse", model: "muse-wonder-1.0"))
        #expect(spec.command == "/opt/muse")
        #expect(["--preset", "empty", "--disable-shell", "--disable-write", "--disable-web-tools", "--no-session-log"]
            .allSatisfy(spec.args.contains))
        let help = "--preset --no-session-log --disable-shell --disable-write --disable-web-tools"
        #expect(provider.namingCheckPasses(help))
        #expect(!provider.namingCheckPasses("--preset --no-session-log"))
        let url = try #require(Bundle.module.url(forResource: "muse-echo-naming", withExtension: "jsonl", subdirectory: "Fixtures"))
        let output = try String(contentsOf: url, encoding: .utf8)
        #expect(provider.namingAnswer(output) == "echo: Name this chat.")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ABSTRACT_MUSE_PROBE_BIN"] != nil),
          .timeLimit(.minutes(1)))
    func modelDiscoveryCompletesAgainstTheInstalledCLI() async {
        let binary = ProcessInfo.processInfo.environment["ABSTRACT_MUSE_PROBE_BIN"]!
        let catalog = await provider.discoverModels(executor: LocalExecutor.shared, binary: binary)
        #expect(catalog?.models.contains { $0.id == "muse-wonder-1.0" } == true)
    }
}

/// Run with ABSTRACT_MUSE_E2E=1 after `muse login`. This does not record the
/// signed-in profile or its stream into a public fixture.
@Suite("Muse Code signed-in CLI", .enabled(if: ProcessInfo.processInfo.environment["ABSTRACT_MUSE_E2E"] != nil))
struct MuseRealCLITests {
    @Test(.timeLimit(.minutes(3)))
    func writesInTheWorktreeAndResumesTheSameSession() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("abstract-muse-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let provider = MuseProvider()
        let binary = ProcessInfo.processInfo.environment["ABSTRACT_MUSE_BIN"] ?? provider.binary
        let engine = SessionEngine(executor: LocalExecutor.shared, logDirectory: workspace.appendingPathComponent("logs"))
        let parser = try #require(provider.makeParser() as? MuseParser)

        /// Feed the host until the turn ends, writing whatever the parser
        /// answers with, as the app does.
        func turn() async -> [AgentEvent] {
            var events: [AgentEvent] = []
            for await event in engine.events {
                switch event {
                case let .line(_, _, line):
                    events += parser.feed(line.line, stream: line.stream)
                    for reply in parser.takePendingInput() { try? engine.write(sessionId: "muse-real", reply) }
                    if events.contains(.status(.idle, detail: nil)) || events.contains(.status(.errored, detail: nil)) {
                        return events
                    }
                case let .exit(_, code):
                    return events + parser.onExit(code: code)
                }
            }
            return events
        }

        let context = LaunchContext(cwd: workspace.path,
                                    prompt: "Create hi.txt containing only hi, then say done.",
                                    permissionPolicy: .bypass, binaryOverride: binary,
                                    model: "muse-wonder-1.0")
        try engine.launch(sessionId: "muse-real", spec: provider.buildLaunch(context))
        defer { engine.stop(sessionId: "muse-real") }
        let first = await turn()
        #expect(first.contains(.status(.idle, detail: nil)))
        #expect(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("hi.txt").path))
        #expect(first.contains { if case let .toolUse(_, "write_file", input, _) = $0 {
            input["path"]?.string == "hi.txt"
        } else { false } })
        let sessionId = try #require(first.compactMap { if case let .sessionId(id) = $0 { id } else { nil } }.first)

        let followUp = try #require(provider.buildUserMessage(
            "What is the name of the file you just made? Reply with only its name.",
            images: [], sessionId: sessionId))
        try engine.write(sessionId: "muse-real", followUp)
        let second = await turn()
        #expect(second.contains { if case let .text(.assistant, text, _, false) = $0 { text.contains("hi.txt") } else { false } })
    }
}
