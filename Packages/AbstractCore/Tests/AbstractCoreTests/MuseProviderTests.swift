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

    @Test func startsAndResumesInTheSameWorktree() {
        let start = provider.buildLaunch(context())
        #expect(start.command == "muse")
        #expect(start.cwd == "/tmp/clean-worktree")
        #expect(start.args == ["exec", "--json", "--workspace", "/tmp/clean-worktree",
                               "--approval-mode", "on-request", "--approval-judge", "off",
                               "--disable-write", "--disable-shell", "Say hello."])
        #expect(!start.keepStdinOpen)
        #expect(provider.followUpMode == .respawn)

        let resume = provider.buildResume(context(), resumeId: "session-1")
        #expect(resume.args.contains("--session-id"))
        #expect(resume.args[resume.args.firstIndex(of: "--session-id")! + 1] == "session-1")
        #expect(resume.cwd == start.cwd)
    }

    @Test func choosesModelAndKeepsTheCLIConfiguredDefault() {
        var selected = context()
        selected.model = "muse-wonder-1.0"
        selected.effort = "high"
        selected.binaryOverride = "/opt/muse"
        let spec = provider.buildLaunch(selected)
        #expect(spec.command == "/opt/muse")
        #expect(spec.args.contains("--model"))
        #expect(spec.args[spec.args.firstIndex(of: "--model")! + 1] == "muse-wonder-1.0")
        #expect(spec.args.contains("--reasoning-effort"))
        #expect(spec.args.last == "Say hello.")
        #expect(!provider.buildLaunch(context()).args.contains("--model"))
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

    @Test func mapsEachPermissionChoiceWithoutWideningAccess() {
        let ask = provider.buildLaunch(context(.ask)).args
        #expect(ask.contains("on-request") && ask.contains("off"))
        #expect(ask.contains("--disable-write") && ask.contains("--disable-shell"))
        #expect(!ask.contains("--yolo") && !ask.contains("--disable-approval"))

        let edits = provider.buildLaunch(context(.autoEdits)).args
        #expect(edits.contains("untrusted") && edits.contains("off"))
        #expect(!edits.contains("--yolo") && !edits.contains("--disable-sandbox"))

        let bypass = provider.buildLaunch(context(.bypass)).args
        #expect(bypass.contains("--yolo"))
        #expect(provider.permissionDetail(.ask).contains("read-only"))
        #expect(provider.permissionDetail(.autoEdits).contains("cannot answer"))
        #expect(TurnStop.action(provider, status: .running, requestId: "stop") == .terminate)
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

        func run(_ spec: LaunchSpec) async throws -> [AgentEvent] {
            try engine.launch(sessionId: "muse-real", spec: spec)
            let parser = provider.makeParser()
            var events: [AgentEvent] = []
            for await event in engine.events {
                switch event {
                case let .line(_, _, line): events += parser.feed(line.line, stream: line.stream)
                case let .exit(_, code): return events + parser.onExit(code: code)
                }
            }
            return events
        }

        let firstContext = LaunchContext(cwd: workspace.path,
                                         prompt: "Create hi.txt containing only hi, then say done.",
                                         permissionPolicy: .bypass, binaryOverride: binary,
                                         model: "muse-wonder-1.0")
        let first = try await run(provider.buildLaunch(firstContext))
        #expect(first.contains(.status(.finished, detail: nil)))
        #expect(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("hi.txt").path))
        let sessionId = try #require(first.compactMap { if case let .sessionId(id) = $0 { id } else { nil } }.first)

        var followUp = firstContext
        followUp.prompt = "What is the name of the file you just made? Reply with only its name."
        let second = try await run(provider.buildResume(followUp, resumeId: sessionId))
        #expect(second.contains(.sessionId(sessionId)))
        #expect(second.contains { if case let .text(.assistant, text, _, false) = $0 { text.contains("hi.txt") } else { false } })
    }
}
