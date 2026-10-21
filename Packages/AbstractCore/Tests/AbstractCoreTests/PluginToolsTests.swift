import Foundation
import JavaScriptCore
import Synchronization
import Testing
@testable import AbstractCore

/// Plugins give agents tools (ABS-97): declared in the manifest, listed
/// on each chat's `abstract-plugins` MCP server per the project's
/// setting, and run in the plugin's background script with a time limit.
@Suite struct PluginToolsTests {
    var fixture: URL {
        Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent("echo-tool.abstractplugin")
    }

    let echo = PluginAgentTool(name: "echo", description: "Answers with the text you send it.",
                               inputSchema: .object(["type": .string("object")]))

    func manifest(api: Int = 2, capabilities: [String] = ["agent.tools"], background: String? = "background.js",
                  tools: [PluginAgentTool]? = nil) -> PluginManifest {
        PluginManifest(api: api, id: "sh.example.tools", name: "Tools", version: "1.0.0", capabilities: capabilities,
                       background: background, tools: tools ?? [echo])
    }

    func refused(_ manifest: PluginManifest) -> Bool {
        (try? manifest.validate()) == nil
    }

    // MARK: The manifest

    @Test func theTestPluginOffersAnEchoToolRunByItsBackgroundScript() throws {
        let manifest = try PluginPackage.inspect(folder: fixture).manifest
        #expect(manifest.grantedCapabilities == [.agentTools])
        #expect(manifest.agentTools.map(\.name) == ["echo"])
        #expect(manifest.agentTools.first?.schema["required"] == .array([.string("text")]))
        #expect(manifest.appearanceSentences.contains("Tools for your agents — echo."))
        #expect(PluginCapability.agentTools.plainWords.contains("Give your agents tools"))
    }

    @Test func theTestPluginsScriptEchoesWhatItIsSent() throws {
        let source = try String(contentsOf: fixture.appendingPathComponent("background.js"), encoding: .utf8)
        let context = try #require(JSContext())
        context.evaluateScript("const handlers = {}; const AbstractPlugin = { tools: { handle(n, f) { handlers[n] = f; } } };")
        context.evaluateScript(source)
        #expect(context.evaluateScript(#"handlers.echo({ text: "hi" })"#)?.toString() == "Echo: hi")
        context.evaluateScript(#"try { handlers.echo({}); } catch (e) { var failed = e.message; }"#)
        #expect(context.evaluateScript("failed")?.toString() == "Send some text to echo.")
    }

    @Test func toolsNeedTheirGrantABackgroundScriptAndAPI2() throws {
        try manifest().validate()
        #expect(refused(manifest(capabilities: [])))
        #expect(refused(manifest(tools: [])))
        #expect(refused(manifest(background: nil)))
        #expect(refused(manifest(api: 1)))
    }

    @Test func eachToolNeedsASafeUniqueNameADescriptionAndAnObjectSchema() throws {
        #expect(refused(manifest(tools: [echo, echo])))
        for name in ["", "has space", "dotted.name", "ünïcode", String(repeating: "a", count: 29)] {
            #expect(refused(manifest(tools: [PluginAgentTool(name: name, description: "x")])), "\(name)")
        }
        try manifest(tools: [PluginAgentTool(name: "search_issues-2", description: "x")]).validate()
        #expect(refused(manifest(tools: [PluginAgentTool(name: "a", description: "  ")])))
        #expect(refused(manifest(tools: [PluginAgentTool(name: "a", description: "x", inputSchema: .object(["type": .string("string")]))])))
        let many = (0...PluginTools.limit).map { PluginAgentTool(name: "t\($0)", description: "x") }
        #expect(refused(manifest(tools: many)))
    }

    // MARK: What a chat's agent gets

    let offers = [PluginToolOffer(pluginId: "sh.abstract.test.echo", pluginName: "Echo",
                                  tools: [PluginAgentTool(name: "echo", description: "Echoes."),
                                          PluginAgentTool(name: "shout", description: "Shouts.")])]

    func project(_ modes: [String: PluginToolMode]? = nil) -> Project {
        var project = Project(id: "p1", name: "App", rootPath: "/repo")
        project.pluginTools = modes
        return project
    }

    @Test func everyToolAsksFirstUntilTheProjectSaysOtherwise() {
        let tools = PluginTools.published(offers, project: project())
        #expect(tools.map(\.name) == ["echo_echo", "echo_shout"])
        #expect(tools.allSatisfy { $0.mode == .ask })
        #expect(tools.first?.label == "Echo: echo")
        #expect(tools.first?.key == "sh.abstract.test.echo/echo")
    }

    @Test func aToolSetToOffIsLeftOutAndAllowedRunsWithoutAsking() {
        let modes: [String: PluginToolMode] = ["sh.abstract.test.echo/echo": .off, "sh.abstract.test.echo/shout": .allowed]
        let tools = PluginTools.published(offers, project: project(modes))
        #expect(tools.map(\.name) == ["echo_shout"])
        #expect(tools.first?.mode == .allowed)
        // Project Settings still lists it, Off.
        #expect(PluginTools.all(offers, project: project(modes)).map(\.mode) == [.off, .allowed])
    }

    @Test func aChatOutsideAnyProjectGetsNoTools() {
        #expect(PluginTools.published(offers, project: nil).isEmpty)
    }

    @Test func aListingNamesThePluginAndSaysItIsReadOnlyForCodex() {
        let listing = PluginTools.published(offers, project: project())[0].listing
        #expect(listing["name"] == .string("echo_echo"))
        #expect(listing["description"]?.string == "From the Echo plugin. Echoes.")
        #expect(listing["inputSchema"] == .object(["type": .string("object")]))
        #expect(listing["annotations"]?["title"] == .string("Echo: echo"))
        #expect(listing["annotations"]?["readOnlyHint"] == .bool(true))
    }

    @Test func pluginsWithTheSameNameGetDifferentPrefixesWithoutUnderscores() {
        let two = [
            PluginToolOffer(pluginId: "com.a.linear", pluginName: "Linear_Tools!", tools: [echo]),
            PluginToolOffer(pluginId: "com.b.linear", pluginName: "Linear Tools", tools: [echo]),
            PluginToolOffer(pluginId: "com.c.x", pluginName: "A very long plugin name indeed", tools: [echo]),
        ]
        let slugs = PluginTools.slugs(two)
        #expect(slugs["com.a.linear"] == "linear-tools")
        #expect(slugs["com.b.linear"]?.hasPrefix("linear-") == true)
        #expect(slugs["com.b.linear"] != slugs["com.a.linear"])
        #expect(slugs.values.allSatisfy { !$0.contains("_") && $0.count <= 12 })
        // Claude's 64-character limit holds for the longest name.
        let longest = "mcp__\(PluginTools.serverName)__" + "abcdefghijkl_" + String(repeating: "t", count: PluginAgentTool.nameLimit)
        #expect(longest.count <= 64)
    }

    @Test func aCallIsRecognisedUnderEveryAgentsSpelling() {
        #expect(PluginTools.toolName(inStreamName: "mcp__abstract-plugins__echo_echo") == "echo_echo")
        #expect(PluginTools.toolName(inStreamName: "abstract-plugins_echo_echo") == "echo_echo")
        #expect(PluginTools.toolName(inStreamName: CodeHistory.streamName(CodeHistory.historyTool)) == nil)
        #expect(PluginTools.toolName(inStreamName: "Bash") == nil)
    }

    @Test func openCodeReportsAPluginToolCallAsATool() throws {
        // Recorded from a real `opencode run` turn (opencode/big-pickle)
        // against `abstract mcp --plugins` and a stand-in for the app.
        let parser = OpenCodeProvider().makeParser()
        let url = try #require(Bundle.module.url(forResource: "opencode-plugin-tool", withExtension: "jsonl", subdirectory: "Fixtures"))
        let events = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
            .flatMap { parser.feed($0, stream: .stdout) }
        let use = events.compactMap { event -> (name: String, input: JSONValue)? in
            if case let .toolUse(_, name, input, _) = event { return (name, input) }
            return nil
        }.first
        #expect(use?.name == "abstract-plugins_echo_echo")
        #expect(PluginTools.toolName(inStreamName: use?.name ?? "") == "echo_echo")
        #expect(use?.input["text"] == .string("opencode"))
        let output = events.compactMap { event -> String? in
            if case let .toolResult(_, output, _, _) = event { return output }
            return nil
        }.first
        #expect(output == "Echo: opencode")
    }

    @Test func aPluginToolNamedLikeCodeHistoryIsStillThePlugins() {
        #expect(CodeHistory.tool(inStreamName: "mcp__abstract-plugins__git_code_history") == nil)
        #expect(CodeHistory.tool(inStreamName: "abstract-plugins_git_code_history") == nil)
    }

    @Test func onlyYouAnswerAToolsAskFirstCard() {
        #expect(PluginTools.isAsk(PluginTools.askPrefix + "x"))
        #expect(!PluginTools.isAsk("toolu_01"))
        func rule(_ kind: PermissionRuleKind, _ decision: PermissionDecision) -> PermissionRule {
            PermissionRule(projectId: "p1", kind: kind, pattern: "*", decision: decision)
        }
        // A rule naming the tool answers it; a command or path allow never does.
        #expect(PluginTools.ruleAnswersAsk(rule(.tool, .allow)))
        #expect(!PluginTools.ruleAnswersAsk(rule(.command, .allow)))
        #expect(!PluginTools.ruleAnswersAsk(rule(.path, .allow)))
        #expect(PluginTools.ruleAnswersAsk(rule(.command, .deny)))
    }

    // MARK: Routing a call

    @Test func aCallRunsAsksOrIsRefusedByTheProjectsSetting() {
        let all = PluginTools.all(offers, project: project(["sh.abstract.test.echo/echo": .off,
                                                            "sh.abstract.test.echo/shout": .allowed]))
        #expect(PluginTools.route("echo_echo", among: all) == .refused("Echo: echo is turned off in this project."))
        guard case .run(let shout) = PluginTools.route("echo_shout", among: all) else { Issue.record("not run"); return }
        #expect(shout.tool.name == "shout")
        guard case .ask = PluginTools.route("echo_echo", among: PluginTools.all(offers, project: project())) else {
            Issue.record("not asked"); return
        }
        guard case .refused = PluginTools.route("gone_tool", among: all) else { Issue.record("not refused"); return }
    }

    @Test func aResultIsTextAndIsCut() {
        #expect(PluginTools.resultText(.string("hi")) == "hi")
        #expect(PluginTools.resultText(.object(["n": .number(1)])) == #"{"n":1}"#)
        #expect(PluginTools.resultText(.null) == "")
        let long = PluginTools.resultText(.string(String(repeating: "a", count: PluginTools.resultLimit + 10)))
        #expect(long.count == PluginTools.resultLimit + 1)
    }

    @Test func aCallEndsWithItsResultItsTimeLimitOrTheScriptStopping() async {
        let calls = PluginToolCalls(pluginName: "Echo", timeout: 0.2)
        let sent = Mutex<String?>(nil)
        async let answered = calls.call { id in sent.withLock { $0 = id }; return true }
        while sent.withLock({ $0 }) == nil { try? await Task.sleep(for: .milliseconds(5)) }
        await calls.finish(sent.withLock { $0 }!, .result("Echo: hi"))
        #expect(await answered == .result("Echo: hi"))

        #expect(await calls.call { _ in true } == .failed("Echo didn't answer within 0 seconds."))
        #expect(await calls.call { _ in false } == .failed("Echo isn't running, so its tool can't answer."))

        let slow = PluginToolCalls(pluginName: "Echo", timeout: 30)
        async let stopped = slow.call { _ in true }
        while await slow.pending == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        await slow.failAll("Echo stopped.")
        #expect(await stopped == .failed("Echo stopped."))
    }

    // MARK: The bridge

    func handle(_ message: String, background: Bool = true, capabilities: Set<PluginCapability> = [.agentTools]) -> PluginBridge.Outcome {
        var bridge = PluginBridge(capabilities: capabilities)
        bridge.isBackground = background
        let storage = PluginStorage(directory: FileManager.default.temporaryDirectory, pluginId: "sh.example.tools")
        return bridge.handle(message, storage: storage)
    }

    @Test func onlyAGrantedBackgroundScriptAnswersACall() {
        let result = #"{"api":2,"type":"tools.result","payload":{"callId":"c1","result":{"ok":true}}}"#
        #expect(handle(result) == .toolResult(callId: "c1", .result(#"{"ok":true}"#)))
        guard case .refused = handle(result, background: false) else { Issue.record("a screen answered"); return }
        guard case .refused = handle(result, capabilities: [.chatsRead]) else { Issue.record("no grant answered"); return }
        guard case .refused = handle(#"{"api":2,"type":"tools.result","payload":{"result":"x"}}"#) else {
            Issue.record("no call id"); return
        }
        #expect(handle(#"{"api":2,"type":"tools.result","payload":{"callId":"c1","error":"No such issue."}}"#)
            == .toolResult(callId: "c1", .failed("No such issue.")))
    }

    @Test func aLongResultIsReadAndCutRatherThanRefused() {
        let text = String(repeating: "a", count: 100_000)
        let message = #"{"api":2,"type":"tools.result","payload":{"callId":"c1","result":"\#(text)"}}"#
        guard case .toolResult(_, .result(let read)) = handle(message) else { Issue.record("refused"); return }
        #expect(read.count == PluginTools.resultLimit + 1)
    }

    // MARK: The MCP server

    final class FakeSource: PluginToolSource, @unchecked Sendable {
        let lock = NSLock()
        var tools: [JSONValue]? = [.object(["name": .string("echo_echo")])]
        var calls: [(String, JSONValue)] = []

        func list() async -> [JSONValue]? { lock.withLock { tools } }
        func call(_ name: String, arguments: JSONValue) async -> (text: String, isError: Bool) {
            lock.withLock { calls.append((name, arguments)) }
            return ("Echo: \(arguments["text"]?.string ?? "")", false)
        }
    }

    func json(_ line: String?) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(try #require(line).utf8))
    }

    @Test func theServerListsAndCallsThroughTheApp() async throws {
        let source = FakeSource()
        let server = PluginMCPServer(source: source)
        let opened = try json(await server.handle(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#))
        #expect(opened["result"]?["serverInfo"]?["name"] == .string(PluginTools.serverName))
        #expect(opened["result"]?["capabilities"]?["tools"]?["listChanged"] == .bool(true))
        #expect(await server.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)

        let listed = try json(await server.handle(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
        #expect(listed["result"]?["tools"]?.array?.first?["name"] == .string("echo_echo"))

        let called = try json(await server.handle(
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo_echo","arguments":{"text":"hi"}}}"#))
        #expect(called["result"]?["content"]?.array?.first?["text"] == .string("Echo: hi"))
        #expect(called["result"]?["isError"] == .bool(false))
        #expect(source.calls.first?.0 == "echo_echo")
    }

    @Test func theServerSaysTheListChangedOnlyAfterTheAgentListedIt() async throws {
        let source = FakeSource()
        let server = PluginMCPServer(source: source)
        source.lock.withLock { source.tools = [] }
        #expect(await server.listChanged() == false)
        _ = await server.handle(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        #expect(await server.listChanged() == false)
        // Switched Off: the agent is told, once.
        source.lock.withLock { source.tools = [.object(["name": .string("echo_echo")])] }
        #expect(await server.listChanged() == true)
        #expect(await server.listChanged() == false)
        // The app went away: nothing to say.
        source.lock.withLock { source.tools = nil }
        #expect(await server.listChanged() == false)
    }

    @Test func aCallReachesTheAppOverItsSocketAndSaysSoWhenTheAppIsClosed() async throws {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("abs97-\(UUID().uuidString.prefix(8)).sock")
        let closed = LinkedPluginTools(chatId: "chat-1", token: "t0k3n", path: path)
        #expect(await closed.list() == nil)
        #expect(await closed.call("echo_echo", arguments: .object([:])) == ("Abstract isn't open, so plugin tools can't run.", true))

        let seen = Mutex<[PluginToolLink.Request]>([])
        let server = try #require(PluginToolLink.Server(path: path) { request in
            seen.withLock { $0.append(request) }
            if request.op == "list" { return .init(tools: [.object(["name": .string("echo_echo")])]) }
            return .init(text: "Echo: \(request.arguments?["text"]?.string ?? "")", isError: false)
        })
        defer { server.stop() }
        // A second app for the same data folder doesn't take it over.
        #expect(PluginToolLink.Server(path: path) { _ in .init() } == nil)

        let open = LinkedPluginTools(chatId: "chat-1", token: "t0k3n", path: path)
        #expect(await open.list() == [.object(["name": .string("echo_echo")])])
        let reply = await open.call("echo_echo", arguments: .object(["text": .string("hi")]))
        #expect(reply.text == "Echo: hi" && !reply.isError)
        #expect(seen.withLock { $0 }.map(\.chatId) == ["chat-1", "chat-1"])
        #expect(seen.withLock { $0 }.allSatisfy { $0.token == "t0k3n" })
        #expect(seen.withLock { $0 }.last?.name == "echo_echo")
    }

    // MARK: Each agent's launch

    let plugins = PluginToolsLaunch(command: "/Applications/Abstract.app/Contents/Helpers/abstract", chatId: "chat-1", token: "t0k3n")
    let history = HistoryToolLaunch(command: "/Applications/Abstract.app/Contents/Helpers/abstract", chatId: "chat-1")

    @Test func claudeGetsBothServersInOneConfigWithPluginToolsAllowedByServer() throws {
        let spec = ClaudeProvider().buildLaunch(LaunchContext(cwd: "/w", prompt: "hi", permissionPolicy: .ask,
                                                              historyTool: history, pluginTools: plugins))
        let config = try #require(spec.args.firstIndex(of: "--mcp-config").map { spec.args[$0 + 1] })
        let servers = try json(config)["mcpServers"]
        #expect(servers?[CodeHistory.serverName] != nil)
        #expect(servers?[PluginTools.serverName]?["args"] == .array(["mcp", "--chat", "chat-1", "--plugins", "--token", "t0k3n"].map(JSONValue.string)))
        let allowed = try #require(spec.args.firstIndex(of: "--allowedTools").map { spec.args[$0 + 1] })
        #expect(allowed.split(separator: ",").contains("mcp__abstract-plugins"))
        #expect(spec.args.filter { $0 == "--mcp-config" }.count == 1)

        // Plugin tools alone, and neither.
        let alone = ClaudeProvider().buildLaunch(LaunchContext(cwd: "/w", prompt: "hi", permissionPolicy: .ask, pluginTools: plugins))
        #expect(alone.args.contains("mcp__abstract-plugins") && !alone.args.contains("--append-system-prompt"))
        let none = ClaudeProvider().buildLaunch(LaunchContext(cwd: "/w", prompt: "hi", permissionPolicy: .ask))
        #expect(!none.args.contains("--mcp-config"))
        // A resume keeps them.
        let resumed = ClaudeProvider().buildResume(LaunchContext(cwd: "/w", prompt: "hi", permissionPolicy: .ask, pluginTools: plugins),
                                                   resumeId: "s1")
        #expect(resumed.args.contains("mcp__abstract-plugins"))
    }

    @Test func codexGetsTheServerAsConfigOverridesAndWaitsForAnAnswer() {
        let spec = CodexProvider().buildLaunch(LaunchContext(cwd: "/w", prompt: "hi", permissionPolicy: .autoEdits, pluginTools: plugins))
        #expect(spec.args.contains(#"mcp_servers.abstract-plugins.command="/Applications/Abstract.app/Contents/Helpers/abstract""#))
        #expect(spec.args.contains(#"mcp_servers.abstract-plugins.args=["mcp", "--chat", "chat-1", "--plugins", "--token", "t0k3n"]"#))
        #expect(spec.args.contains("mcp_servers.abstract-plugins.tool_timeout_sec=660"))
        #expect(spec.args.last == "hi")
        let none = CodexProvider().buildLaunch(LaunchContext(cwd: "/w", prompt: "hi", permissionPolicy: .autoEdits))
        #expect(!none.args.contains { $0.contains(PluginTools.serverName) })
    }

    @Test func openCodeGetsTheServerMergedBesideCodeHistory() throws {
        let spec = OpenCodeProvider().buildLaunch(LaunchContext(cwd: "/w", prompt: "hi", permissionPolicy: .autoEdits,
                                                                historyTool: history, pluginTools: plugins))
        let config = try json(spec.env["OPENCODE_CONFIG_CONTENT"])
        #expect(config["mcp"]?[CodeHistory.serverName] != nil)
        #expect(config["mcp"]?[PluginTools.serverName]?["command"]
            == .array((["/Applications/Abstract.app/Contents/Helpers/abstract"] + plugins.serverArgs).map(JSONValue.string)))
        let alone = OpenCodeProvider().buildLaunch(LaunchContext(cwd: "/w", prompt: "hi", permissionPolicy: .autoEdits, pluginTools: plugins))
        #expect(try json(alone.env["OPENCODE_CONFIG_CONTENT"])["mcp"]?[CodeHistory.serverName] == nil)
    }

    @Test func aLaunchGetsPluginToolsOnlyWhenTheAppServesThem() {
        let session = Session(id: "chat-1", projectId: "p1", name: "Chat", providerId: "claude", worktreePath: "/w")
        var settings = LaunchSettings(providerOverrides: [:], outputStyle: .default, claudeProfile: nil, attachmentsDirectory: "/a")
        let without = AgentLaunch.spec(for: session, provider: ClaudeProvider(), prompt: "hi", resumeId: nil, settings: settings, home: "/h")
        #expect(!without.args.contains("mcp__abstract-plugins"))
        settings.pluginToolsCommand = "/bin/abstract"
        // Never without the chat's token.
        let tokenless = AgentLaunch.spec(for: session, provider: ClaudeProvider(), prompt: "hi", resumeId: nil, settings: settings, home: "/h")
        #expect(!tokenless.args.contains("mcp__abstract-plugins"))
        settings.pluginToolsToken = "t0k3n"
        let with = AgentLaunch.spec(for: session, provider: ClaudeProvider(), prompt: "hi", resumeId: nil, settings: settings, home: "/h")
        #expect(with.args.contains("mcp__abstract-plugins"))
        #expect(with.args.contains { $0.contains(#""--token","t0k3n""#) })
    }

    // MARK: Saved per project

    @Test func aProjectKeepsItsToolSettings() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("abs97-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try Store(path: dir.appendingPathComponent("abstract.sqlite").path)
        var saved = Project(id: "p1", name: "App", rootPath: "/repo")
        try store.save(saved)
        #expect(try store.project("p1")?.pluginTools == nil)
        #expect(try store.project("p1")?.pluginToolMode(pluginId: "sh.abstract.test.echo", tool: "echo") == .ask)
        saved.pluginTools = ["sh.abstract.test.echo/echo": .off]
        try store.save(saved)
        let read = try #require(try store.project("p1"))
        #expect(read.pluginToolMode(pluginId: "sh.abstract.test.echo", tool: "echo") == .off)
        #expect(read.pluginToolMode(pluginId: "sh.abstract.test.echo", tool: "shout") == .ask)
    }
}

/// The built `abstract mcp --chat <id> --plugins`, the way an agent runs
/// it, against a stand-in for the app on the data folder's socket.
@Suite struct PluginToolsCommandTests {
    @Test func theCommandServesTheChatsPluginToolsFromTheApp() async throws {
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("abs97-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: data) }
        let path = PluginToolLink.socketPath(storePath: data.appendingPathComponent("abstract.sqlite").path)
        let server = try #require(PluginToolLink.Server(path: path) { request in
            guard request.chatId == "chat-1", request.token == "t0k3n" else { return .init(tools: []) }
            if request.op == "list" {
                return .init(tools: [.object(["name": .string("echo_echo"), "description": .string("From the Echo plugin.")])])
            }
            return .init(text: "Echo: \(request.arguments?["text"]?.string ?? "")", isError: false)
        })
        defer { server.stop() }

        let input = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo_echo","arguments":{"text":"hi"}}}"#,
        ].joined(separator: "\n") + "\n"
        var environment = ProcessInfo.processInfo.environment
        environment["ABSTRACT_DATA_DIR"] = data.path
        let binary = Bundle.module.bundleURL.deletingLastPathComponent().appendingPathComponent("abstract")
        let (status, out) = try await withCheckedThrowingContinuation { (done: CheckedContinuation<(Int32, Data), any Error>) in
            Thread.detachNewThread { [environment] in
                done.resume(with: Result {
                    let process = Process()
                    process.executableURL = binary
                    process.arguments = ["mcp", "--chat", "chat-1", "--plugins", "--token", "t0k3n"]
                    process.environment = environment
                    let stdout = Pipe(), stdin = Pipe()
                    process.standardOutput = stdout
                    process.standardInput = stdin
                    process.standardError = FileHandle.nullDevice
                    try process.run()
                    // A command that already exited must fail this write, not kill the test run.
                    _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                    try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
                    try? stdin.fileHandleForWriting.close()
                    let data = stdout.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    return (process.terminationStatus, data)
                })
            }
        }
        #expect(status == 0)
        let replies = String(decoding: out, as: UTF8.self).split(separator: "\n").compactMap {
            try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))
        }
        var byId: [Int: JSONValue] = [:]
        for reply in replies { if let id = reply["id"]?.int { byId[id] = reply } }
        #expect(byId[1]?["result"]?["serverInfo"]?["name"] == .string(PluginTools.serverName))
        #expect(byId[2]?["result"]?["tools"]?.array?.first?["name"] == .string("echo_echo"))
        #expect(byId[3]?["result"]?["content"]?.array?.first?["text"] == .string("Echo: hi"))
    }
}
