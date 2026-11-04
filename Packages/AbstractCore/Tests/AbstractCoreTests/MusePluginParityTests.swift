import Foundation
import Testing
@testable import AbstractCore

/// Muse Code's agent plugin (ABS-185) against the Swift `MuseProvider` it
/// replaces: every fixture line folds to the same events and the same stdin
/// answers, and every launch, follow-up, answer and naming call matches
/// (minted ids aside). Serialized: both sides keep a process-wide registry of
/// first turns, keyed by session ids the fixtures share.
@Suite(.serialized) struct MusePluginParityTests {
    let swift = MuseProvider()

    /// A real picture on disk, which both sides send as base64.
    static let picture: String = {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("abstract-muse-parity-\(getpid()).png").path
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!
        FileManager.default.createFile(atPath: path, contents: png)
        return path
    }()

    static func plugin() throws -> ScriptedProvider {
        try #require(AgentPlugins.shared.anyAgent("muse"))
    }

    static let fixtures = ["muse-echo-naming", "muse-echo-resume", "muse-echo-start", "muse-mock-failure", "muse-mock-tool",
                           "muse-serve-reasoning", "muse-serve-resume", "muse-serve-tools", "muse-wonder-resume", "muse-wonder-start"]

    static func lines(_ name: String) throws -> [String] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    static func text(_ name: String) throws -> String {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Lines no parser should trip on, and the serve and exec corners.
    static let oddLines: [String] = [
        "", "   ", " \t\u{85}", "not json", "[]", "42", "null", "\"text\"", "{}", #"{"jsonrpc":"2.0"}"#, #"{"method":7}"#,
        #"{"jsonrpc":7,"method":"turn/started"}"#, #"{"payload_type":5,"method":"turn/started"}"#,
        #"{"payload_type":"run.lifecycle.started","jsonrpc":"2.0"}"#,
        // Replies.
        #"{"jsonrpc":"2.0","id":1,"error":{"message":"missing credential"}}"#,
        #"{"jsonrpc":"2.0","id":1,"error":"nope"}"#,
        #"{"jsonrpc":"2.0","id":2,"error":{"message":"model x does not exist or you lack access"}}"#,
        #"{"jsonrpc":"2.0","id":3,"error":null}"#,
        #"{"jsonrpc":"2.0","id":3.9,"error":{"message":"You are not signed in"}}"#,
        #"{"jsonrpc":"2.0","id":4,"error":{"message":"whatever"}}"#,
        #"{"jsonrpc":"2.0","id":"2","result":{"session":{"sessionId":"s-odd"}}}"#,
        #"{"jsonrpc":"2.0","id":2,"result":{"session":{"sessionId":7}}}"#,
        #"{"jsonrpc":"2.0","id":2,"result":{"session":null}}"#,
        #"{"jsonrpc":"2.0","id":2.5,"result":{"session":{"sessionId":"s-odd","modelId":"m","workspaceRoot":"/w"}}}"#,
        #"{"jsonrpc":"2.0","id":2,"result":{"session":{"sessionId":"s-odd","modelId":null}}}"#,
        #"{"jsonrpc":"2.0","id":null}"#,
        // Notifications.
        #"{"jsonrpc":"2.0","method":"session/started","params":{"session":{"sessionId":"s-odd"}}}"#,
        #"{"jsonrpc":"2.0","method":"session/started","params":{"session":{"sessionId":"s-other"}}}"#,
        #"{"jsonrpc":"2.0","method":"session/started","params":null}"#,
        #"{"jsonrpc":"2.0","method":"turn/started"}"#,
        #"{"jsonrpc":"2.0","method":"turn/completed","params":{"terminal":"failed"}}"#,
        #"{"jsonrpc":"2.0","method":"turn/completed","params":{"terminal":"failed","reason":"Please login again"}}"#,
        #"{"jsonrpc":"2.0","method":"turn/started"}"#,
        #"{"jsonrpc":"2.0","method":"turn/completed","params":{"durationMs":12.9}}"#,
        #"{"jsonrpc":"2.0","method":"turn/completed","params":{"durationMs":"12"}}"#,
        #"{"jsonrpc":"2.0","method":"item/started"}"#,
        #"{"jsonrpc":"2.0","method":"item/completed","params":{"item":null}}"#,
        #"{"jsonrpc":"2.0","method":"item/updated","params":{"item":{"kind":"mystery"}}}"#,
        #"{"jsonrpc":"2.0","method":"item/completed","params":{"item":{"kind":"mystery"}}}"#,
        #"{"jsonrpc":"2.0","method":"item/completed","params":{"item":{"kind":"userMessage","itemId":"u"}}}"#,
        #"{"jsonrpc":"2.0","method":"item/delta","params":{"itemId":"a1","field":"text","delta":"Hel"}}"#,
        #"{"jsonrpc":"2.0","method":"item/delta","params":{"itemId":"a1","field":"text","delta":""}}"#,
        #"{"jsonrpc":"2.0","method":"item/delta","params":{"itemId":"a1","field":"text","delta":"lo"}}"#,
        #"{"jsonrpc":"2.0","method":"item/completed","params":{"item":{"kind":"agentMessage","itemId":"a1"}}}"#,
        #"{"jsonrpc":"2.0","method":"item/completed","params":{"item":{"kind":"agentMessage","itemId":"a1","text":null}}}"#,
        #"{"jsonrpc":"2.0","method":"item/updated","params":{"item":{"kind":"agentMessage","itemId":"a2","text":"x"}}}"#,
        #"{"jsonrpc":"2.0","method":"item/delta","params":{"itemId":"r9","field":"summary.-1","delta":"neg"}}"#,
        #"{"jsonrpc":"2.0","method":"item/delta","params":{"itemId":"r9","field":"summary.x","delta":"bad"}}"#,
        #"{"jsonrpc":"2.0","method":"item/delta","params":{"itemId":"r9","field":"summary.+0","delta":"plus"}}"#,
        #"{"jsonrpc":"2.0","method":"item/delta","params":{"itemId":"r9","field":"summary.","delta":"none"}}"#,
        #"{"jsonrpc":"2.0","method":"item/delta","params":{"itemId":"r9","field":"summary.0","delta":""}}"#,
        #"{"jsonrpc":"2.0","method":"item/delta","params":{"itemId":"r9","field":"summary.002","delta":"third"}}"#,
        #"{"jsonrpc":"2.0","method":"item/delta","params":{"itemId":"r9","field":"summary.1","delta":"second"}}"#,
        #"{"jsonrpc":"2.0","method":"item/delta","params":{"itemId":"r9","field":"summary.99999999999999999999","delta":"big"}}"#,
        #"{"jsonrpc":"2.0","method":"item/delta","params":{"itemId":"r9","field":"other","delta":"z"}}"#,
        #"{"jsonrpc":"2.0","method":"item/delta","params":{"itemId":"r9","delta":"z"}}"#,
        #"{"jsonrpc":"2.0","method":"item/delta","params":{"itemId":7,"field":"text","delta":"z"}}"#,
        #"{"jsonrpc":"2.0","method":"item/completed","params":{"item":{"kind":"reasoning","itemId":"r9","summary":[1,"",null]}}}"#,
        #"{"jsonrpc":"2.0","method":"item/completed","params":{"item":{"kind":"reasoning","itemId":"r10","summary":"flat","text":"raw"}}}"#,
        #"{"jsonrpc":"2.0","method":"item/completed","params":{"item":{"kind":"reasoning","summary":["x"]}}}"#,
        #"{"jsonrpc":"2.0","method":"item/delta","params":{"itemId":"t1","field":"output","delta":"out "}}"#,
        #"{"jsonrpc":"2.0","method":"item/started","params":{"item":{"kind":"toolCall","itemId":"t1","revision":3,"status":"inProgress","args":"[1,2]"}}}"#,
        #"{"jsonrpc":"2.0","method":"item/updated","params":{"item":{"kind":"toolCall","itemId":"t1","revision":2,"status":"completed"}}}"#,
        #"{"jsonrpc":"2.0","method":"item/updated","params":{"item":{"kind":"toolCall","itemId":"t1","revision":3.7,"status":"failed","failureReason":"boom"}}}"#,
        #"{"jsonrpc":"2.0","method":"item/completed","params":{"item":{"kind":"toolCall","itemId":"t1","revision":9,"status":"completed","visibleOutput":"late"}}}"#,
        #"{"jsonrpc":"2.0","method":"item/completed","params":{"item":{"kind":"toolCall","revision":1,"status":"completed"}}}"#,
        #"{"jsonrpc":"2.0","method":"item/completed","params":{"item":{"kind":"toolCall","itemId":"t2","callId":"c2","tool":"bash","args":"null","status":"rejected","failureReason":"denied"}}}"#,
        #"{"jsonrpc":"2.0","method":"item/completed","params":{"item":{"kind":"toolCall","itemId":"t3","args":"{\"a\":1.5,\"b\":[true,null]}","status":"timedOut"}}}"#,
        #"{"jsonrpc":"2.0","method":"item/started","params":{"item":{"kind":"webSearch","itemId":"w1","query":"swift","args":"{}"}}}"#,
        #"{"jsonrpc":"2.0","method":"item/started","params":{"item":{"kind":"webSearch","itemId":"w2","query":"swift","args":"3"}}}"#,
        #"{"jsonrpc":"2.0","method":"item/started","params":{"item":{"kind":"webSearch","itemId":"w3","query":"swift","args":"{\"q\":\"x\"}"}}}"#,
        #"{"jsonrpc":"2.0","method":"item/completed","params":{"item":{"kind":"webSearch","itemId":"w4","status":"cancelled"}}}"#,
        #"{"jsonrpc":"2.0","method":"session/tokenUsage","params":{"usage":null}}"#,
        #"{"jsonrpc":"2.0","method":"session/tokenUsage","params":{"usage":{"inputTokens":10.8,"outputTokens":"5","cacheReadTokens":20}}}"#,
        #"{"jsonrpc":"2.0","method":"session/tokenUsage","params":{}}"#,
        #"{"jsonrpc":"2.0","id":11,"method":"userInput/request","params":{"sessionId":"s","userInputId":"q1","questions":[]}}"#,
        #"{"jsonrpc":"2.0","method":"userInput/requested","params":{"sessionId":"s","userInputId":"q1"}}"#,
        #"{"jsonrpc":"2.0","id":"str-id","method":"userInput/request","params":{"userInputId":"q1"}}"#,
        #"{"jsonrpc":"2.0","id":null,"method":"userInput/request","params":{"userInputId":"q2"}}"#,
        #"{"jsonrpc":"2.0","method":"userInput/request","params":{"userInputId":"q3"}}"#,
        #"{"jsonrpc":"2.0","id":12,"method":"userInput/request","params":null}"#,
        #"{"jsonrpc":"2.0","method":"session/statusChanged","params":{}}"#,
        #"{"jsonrpc":"2.0","method":"approval/request","params":{}}"#,
        #"{"jsonrpc":"2.0","method":"something/new","params":{}}"#,
        // Exec journal.
        #"{"payload_type":"run.model.configured","payload":{"model_id":"m"}}"#,
        #"{"stream":{"kind":"session","id":"e1"},"payload_type":"run.model.configured","payload":{"model_id":7}}"#,
        #"{"stream":{"kind":"run","id":"e2"},"payload_type":"run.lifecycle.started"}"#,
        #"{"payload_type":"task.lifecycle.proposed","payload":{"task_id":"k1","event":{"task_kind":"tool.read_file"}}}"#,
        #"{"payload_type":"task.lifecycle.proposed","payload":{"task_id":"k2","event":{"task_kind":"model.step"}}}"#,
        #"{"payload_type":"task.lifecycle.scheduled","payload":{"task_id":"k1","event":{"idempotency_key":"tool:call_1"}}}"#,
        #"{"payload_type":"task.lifecycle.scheduled","payload":{"task_id":"k2","event":{"idempotency_key":"tool:call_2"}}}"#,
        #"{"payload_type":"task.lifecycle.scheduled","payload":{"task_id":"k1","event":{"idempotency_key":"other"}}}"#,
        #"{"payload_type":"tool.result","payload":{"call_id":"call_1","correlation_facts":{"outcome":"error"}}}"#,
        #"{"payload_type":"tool.result","payload":{"call_id":"call_1","text":"ok","correlation_facts":{"outcome":"success"}}}"#,
        #"{"payload_type":"tool.result","payload":{"text":"orphan"}}"#,
        #"{"payload_type":"run.output.delta","payload":{"text":""}}"#,
        #"{"payload_type":"run.output.delta","payload":{"text":"hi","run_stream":{"id":"rs"}}}"#,
        #"{"payload_type":"run.terminal.cancelled","payload":{"text":"stopped"}}"#,
        #"{"payload_type":"run.terminal.failed","payload":{}}"#,
        #"{"payload_type":"run.terminal.completed","payload":{"text":"done"}}"#,
        #"{"payload_type":"new.event","payload":{}}"#,
        "  {\"payload_type\":\"run.lifecycle.started\"}\u{85}",
        "missing meta credentials: run muse login",
        "unknown model requested",
    ]

    /// Minted ids differ run to run; everything else must not.
    static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}",
                                  with: "<id>", options: .regularExpression)
    }
    static func normalized(_ texts: [String]) -> [String] { texts.map(normalized) }
    static func normalized(_ text: String?) -> String? { text.map(normalized) }

    /// The sessions a recording's `session/start` reply loads.
    static func sessions(in lines: [String]) -> [String] {
        lines.compactMap { line in
            guard let msg = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)), msg["id"]?.int == 2 else { return nil }
            return msg["result"]?["session"]?["sessionId"]?.string
        }
    }

    /// A chat whose first turn waits for these sessions on both sides, with a
    /// model the recordings mostly didn't start with, so it switches first.
    static func firstTurn(model: String? = "muse-wonder-full-1.0") -> LaunchContext {
        LaunchContext(cwd: "/tmp/clean-worktree", prompt: "Say hello.", permissionPolicy: .bypass, model: model, effort: "high",
                      images: ["/nonexistent/abstract-muse-parity.png", "/tmp/not-an-image.txt", Self.picture])
    }

    func register(_ sessions: [String], plugin: ScriptedProvider, model: String?) {
        for id in sessions {
            _ = swift.buildResume(Self.firstTurn(model: model), resumeId: id)
            _ = plugin.buildResume(Self.firstTurn(model: model), resumeId: id)
        }
    }

    func unregister(_ sessions: [String], plugin: ScriptedProvider) {
        for id in sessions {
            MusePendingTurns.remove(id)
            _ = plugin.script.evaluate("MuseAgent.pendingTurns.remove(\(JSONValue.string(id).compact()))")
        }
    }

    /// How many stdin lines the Swift parser queued on stdout. It hands its
    /// thread back now and then: CI runs tests on very few, and async tests
    /// elsewhere time out behind seconds of parsing.
    @discardableResult
    func expectSameFold(_ lines: [String], plugin: ScriptedProvider, model: String? = "muse-wonder-full-1.0",
                        sourceLocation: SourceLocation = #_sourceLocation) async -> Int {
        var queued = 0
        let sessions = Self.sessions(in: lines) + ["s-odd"]
        for stream in [OutputStreamKind.stdout, .stderr] {
            register(sessions, plugin: plugin, model: model)
            defer { unregister(sessions, plugin: plugin) }
            let a = MuseParser(), b = plugin.makeParser()
            let bInput = b as? InputDrivingParser
            #expect(bInput != nil, sourceLocation: sourceLocation)
            for (index, line) in lines.enumerated() {
                if index % 20 == 19 { await Task.yield() }
                let expected = a.feed(line, stream: stream), actual = b.feed(line, stream: stream)
                #expect(actual == expected, "line \(index + 1) on \(stream): \(line)", sourceLocation: sourceLocation)
                let sent = Self.normalized(a.takePendingInput()), got = Self.normalized(bInput?.takePendingInput() ?? [])
                if stream == .stdout { queued += sent.count }
                #expect(got == sent, "input after line \(index + 1) on \(stream)", sourceLocation: sourceLocation)
            }
            for code in [Int32(0), 1, nil] as [Int32?] {
                #expect(b.onExit(code: code) == a.onExit(code: code), "exit \(String(describing: code)) on \(stream)",
                        sourceLocation: sourceLocation)
            }
        }
        // A batch reads the same as line by line.
        register(sessions, plugin: plugin, model: model)
        defer { unregister(sessions, plugin: plugin) }
        let one = plugin.makeParser(), many = plugin.makeParser()
        let batched = many.feed(lines: lines.map { OutputLine(stream: .stdout, line: $0) })
        #expect(batched == lines.map { one.feed($0, stream: .stdout) }, sourceLocation: sourceLocation)
        return queued
    }

    // MARK: Folding

    @Test(arguments: fixtures)
    func fixturesFoldTheSame(_ fixture: String) async throws {
        let plugin = try Self.plugin()
        let lines = try Self.lines(fixture)
        let switched = await expectSameFold(lines, plugin: plugin)
        let kept = await expectSameFold(lines, plugin: plugin, model: nil)
        let odd = await expectSameFold(lines + Self.oddLines, plugin: plugin)
        // A recording that loads a session sends its first turn (after a model
        // switch when the chat's model differs). The odd lines add a receipt for
        // each of their four userInput requests with an id, and load `s-odd`
        // (a switch and a turn) when nothing loaded first.
        let loads = !Self.sessions(in: lines).isEmpty
        #expect(kept == (loads ? 1 : 0))
        #expect(switched >= kept && switched <= kept + 1)
        #expect(odd == switched + (loads ? 0 : 2) + 4)
    }

    @Test func oddLinesFoldTheSame() async throws {
        let plugin = try Self.plugin()
        await expectSameFold(Self.oddLines, plugin: plugin)
        await expectSameFold(Array(Self.oddLines.reversed()), plugin: plugin)
        // Each one alone, for the exit it leaves.
        for line in Self.oddLines { await expectSameFold([line], plugin: plugin) }
        await expectSameFold([], plugin: plugin)
    }

    @Test func replayDoesNotSpendTheFirstTurn() throws {
        let plugin = try Self.plugin()
        let reply = #"{"jsonrpc":"2.0","id":2,"result":{"session":{"sessionId":"parity-replay","modelId":"muse-wonder-1.0"}}}"#
        register(["parity-replay"], plugin: plugin, model: "muse-wonder-1.0")
        defer { unregister(["parity-replay"], plugin: plugin) }
        for _ in 0..<3 {
            let a = MuseParser(), b = try #require(plugin.makeParser() as? InputDrivingParser)
            #expect(b.feed(reply, stream: .stdout) == a.feed(reply, stream: .stdout))
            // The replayed fold queued it but never drained, so it's still there for the next.
            #expect(b.feed(reply, stream: .stdout) == a.feed(reply, stream: .stdout))
        }
        let a = MuseParser(), b = try #require(plugin.makeParser() as? InputDrivingParser)
        _ = a.feed(reply, stream: .stdout); _ = b.feed(reply, stream: .stdout)
        let sent = Self.normalized(a.takePendingInput())
        #expect(sent.count == 1)
        #expect(Self.normalized(b.takePendingInput()) == sent)
        let again = MuseParser(), other = try #require(plugin.makeParser() as? InputDrivingParser)
        _ = again.feed(reply, stream: .stdout); _ = other.feed(reply, stream: .stdout)
        #expect(again.takePendingInput().isEmpty)
        #expect(other.takePendingInput().isEmpty)
    }

    // MARK: Launching

    static func contexts(_ policy: PermissionPolicy) -> [LaunchContext] {
        [
            LaunchContext(cwd: "/tmp/clean-worktree", prompt: "Say hello.", permissionPolicy: policy),
            LaunchContext(cwd: "/tmp/w t", prompt: "-starts with a dash", permissionPolicy: policy, extraArgs: ["--verbose", "x y"],
                          binaryOverride: "  /opt/muse  ", model: "muse-wonder-1.0", effort: "high", outputStyle: .concise,
                          images: ["/nonexistent/a.png"], instructions: "Be a pirate.",
                          skills: SkillsLaunch(folder: "/tmp/skills-home")),
            LaunchContext(cwd: "/tmp/clean-worktree", prompt: "Plan \"this\" / that\n", permissionPolicy: policy,
                          binaryOverride: "   ", effort: "turbo", outputStyle: .explanatory),
        ]
    }

    func expectSameSpec(_ a: LaunchSpec, _ b: LaunchSpec, _ note: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(b.command == a.command, "\(note) command", sourceLocation: sourceLocation)
        #expect(b.args == a.args, "\(note) args", sourceLocation: sourceLocation)
        #expect(b.cwd == a.cwd, "\(note) cwd", sourceLocation: sourceLocation)
        #expect(b.env == a.env, "\(note) env", sourceLocation: sourceLocation)
        #expect(b.keepStdinOpen == a.keepStdinOpen, "\(note) keepStdinOpen", sourceLocation: sourceLocation)
        #expect(Self.normalized(b.stdinInitial) == Self.normalized(a.stdinInitial), "\(note) stdin", sourceLocation: sourceLocation)
    }

    static func sessionId(in spec: LaunchSpec) -> String? {
        for line in (spec.stdinInitial ?? "").split(separator: "\n") {
            guard let msg = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else { continue }
            if let id = msg["params"]?["sessionId"]?.string { return id }
        }
        return nil
    }

    /// The first turn each side registered for a session, as JSON.
    func pendingTurns(_ id: String, plugin: ScriptedProvider) -> (JSONValue?, JSONValue?) {
        let turn = MusePendingTurns.peek(id).map { turn -> JSONValue in
            .object(["prompt": .string(turn.prompt), "model": turn.model.map(JSONValue.string) ?? .null,
                     "effort": turn.effort.map(JSONValue.string) ?? .null, "images": .array(turn.images.map(JSONValue.string))])
        }
        // The plugin also keeps the pictures it read while launching; Swift reads them when it sends.
        return (turn, plugin.script.evaluate("(function (t) { if (t) { t = Object.assign({}, t); delete t.imageParts; } return t; })"
                                              + "(MuseAgent.pendingTurns.peek(\(JSONValue.string(id).compact())))"))
    }

    @Test(arguments: PermissionPolicy.allCases)
    func launchesTheSame(_ policy: PermissionPolicy) throws {
        let plugin = try Self.plugin()
        for (index, ctx) in Self.contexts(policy).enumerated() {
            let a = swift.buildLaunch(ctx), b = plugin.buildLaunch(ctx)
            expectSameSpec(a, b, "launch \(index) \(policy)")
            let ids = (try #require(Self.sessionId(in: a)), try #require(Self.sessionId(in: b)))
            #expect(ids.0 != ids.1)
            let (turnA, turnB) = (pendingTurns(ids.0, plugin: plugin).0, pendingTurns(ids.1, plugin: plugin).1)
            #expect(turnA != nil && turnB == turnA, "launch \(index) \(policy) first turn")
            unregister([ids.0, ids.1], plugin: plugin)

            let resumeId = "parity-resume-\(index)"
            expectSameSpec(swift.buildResume(ctx, resumeId: resumeId), plugin.buildResume(ctx, resumeId: resumeId),
                           "resume \(index) \(policy)")
            let (resumedA, resumedB) = pendingTurns(resumeId, plugin: plugin)
            #expect(resumedA != nil && resumedB == resumedA, "resume \(index) \(policy) first turn")
            unregister([resumeId], plugin: plugin)
        }
        #expect(plugin.permissionDetail(policy) == swift.permissionDetail(policy))
    }

    @Test func mintedIdsAreUUIDv7() throws {
        let plugin = try Self.plugin()
        let id = try #require(plugin.script.evaluate("MuseAgent.newId()")?.string)
        let parts = id.split(separator: "-")
        #expect(parts.map(\.count) == [8, 4, 4, 4, 12])
        #expect(parts[2].hasPrefix("7"))
        #expect(["8", "9", "a", "b"].contains { parts[3].hasPrefix($0) })
        #expect(id == id.lowercased())
        // The first 48 bits are the time, in milliseconds.
        let ms = try #require(UInt64(parts[0] + parts[1], radix: 16))
        #expect(abs(Double(ms) - Date().timeIntervalSince1970 * 1000) < 60_000)
        #expect(plugin.script.evaluate("MuseAgent.newId()")?.string != id)
    }

    @Test func describesTheSameAgent() throws {
        let plugin = try Self.plugin()
        #expect(plugin.id == swift.id)
        #expect(plugin.name == swift.name)
        #expect(plugin.logoAsset == swift.logoAsset)
        #expect(plugin.binary == swift.binary)
        #expect(plugin.detectArgs == swift.detectArgs)
        #expect(plugin.followUpMode == .stdin)
        #expect(plugin.skillDelivery == swift.skillDelivery)
        #expect(plugin.toolServerSupport == swift.toolServerSupport)
        #expect(plugin.commands == swift.commands)
        #expect(plugin.compaction == nil && swift.compaction == nil)
        #expect(plugin.fallbackModels == swift.fallbackModels)
        #expect(plugin.buildInterrupt(requestId: "r") == swift.buildInterrupt(requestId: "r"))
        #expect(plugin.buildStopTask("t", requestId: "r") == swift.buildStopTask("t", requestId: "r"))
        #expect(plugin.buildBackground(toolUseId: "t", requestId: "r") == swift.buildBackground(toolUseId: "t", requestId: "r"))
        #expect(plugin.buildPermissionModeChange(.bypass, requestId: "r") == swift.buildPermissionModeChange(.bypass, requestId: "r"))
        #expect(plugin.configuredDefaultEffort(home: "/nonexistent") == swift.configuredDefaultEffort(home: "/nonexistent"))
    }

    @Test func readsTheSameConfiguredModel() throws {
        let plugin = try Self.plugin()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("muse-parity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".config/muse"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent(".config/muse/settings.json")
        for contents in [#"{"model":"muse-wonder-1.0"}"#, #"{"model":7}"#, #"{"model":null}"#, "{}", "not json", "", "[]",
                         #"{"model":"muse-wonder-full-1.0","effort":"high"}"#] {
            try contents.write(to: file, atomically: true, encoding: .utf8)
            #expect(plugin.configuredDefaultModel(home: home.path) == swift.configuredDefaultModel(home: home.path), "\(contents)")
        }
        #expect(plugin.configuredDefaultModel(home: home.path + "/missing") == swift.configuredDefaultModel(home: home.path + "/missing"))
    }

    // MARK: Answers on stdin

    @Test func followUpsAreTheSame() throws {
        let plugin = try Self.plugin()
        let messages: [(String, [String], String?)] = [("Again.", [String](), "session-1" as String?), ("Again.", [], nil), ("Again.", [], ""),
                                        ("-dash \"quoted\" / \u{e9}", ["/nonexistent/a.png", "/tmp/x.txt"], "session-2"),
                                        ("With a picture.", [Self.picture], "session-3")]
        for (text, images, session) in messages {
            #expect(Self.normalized(plugin.buildUserMessage(text, images: images, sessionId: session))
                    == Self.normalized(swift.buildUserMessage(text, images: images, sessionId: session)), "\(text) \(String(describing: session))")
            #expect(plugin.buildUserMessage(text, images: images) == swift.buildUserMessage(text, images: images))
        }
        #expect(plugin.buildUserMessage("Again.") == swift.buildUserMessage("Again."))
    }

    @Test func questionAnswersAreTheSame() throws {
        let plugin = try Self.plugin()
        let question = #"{"id":"format","header":"Format","question":"Which format?","selection":{"mode":"single"},"options":[{"label":"Short","description":"15 seconds"},{"label":"Long"}]}"#
        let second = #"{"id":"audio","header":"Audio","question":"How should audio work?","selection":{"mode":"single"},"options":[{"label":"Captions"},{"label":"Voice"}]}"#
        let input = try #require(JSONValue.parse(#"{"sessionId":"session-1","userInputId":"input-1","toolName":"request_user_input","questions":["# + question + "," + second + "]}"))
        let multiple = try #require(JSONValue.parse(#"{"sessionId":"session-1","userInputId":"input-2","questions":[{"id":"targets","question":"Which targets?","selection":{"mode":"multiple"},"options":[{"label":"Mac"},{"label":"Phone"},{"label":7}]}]}"#))
        let long = String(repeating: "x", count: 600) + ", Mac"
        let cases: [(String, Bool, JSONValue?)] = [
            ("input-1", true, AgentQuestion.answeredInput(input, answers: ["Which format?": "Short", "How should audio work?": "Record later"])),
            ("input-1", true, AgentQuestion.answeredInput(input, answers: ["Which format?": "Long", "How should audio work?": "Voice"])),
            ("input-1", true, AgentQuestion.answeredInput(input, answers: ["Which format?": "Short"])),
            ("input-1", true, AgentQuestion.answeredInput(input, answers: ["Which format?": "", "How should audio work?": "Voice"])),
            ("input-1", true, input),
            ("input-1", false, input),
            ("input-9", true, input),
            ("input-1", true, nil),
            ("input-1", true, .null),
            ("input-1", true, JSONValue.parse(#"{"userInputId":"input-1","questions":[]}"#)),
            ("input-1", true, JSONValue.parse(#"{"sessionId":"s","userInputId":"input-1"}"#)),
            ("input-1", true, JSONValue.parse(#"{"sessionId":"s","userInputId":"input-1","answers":[],"questions":[{"id":"q","question":"Q?"}]}"#)),
            ("input-1", true, JSONValue.parse(#"{"sessionId":"s","userInputId":"input-1","answers":{"Q?":"free"},"questions":[{"id":"q","question":"Q?"}]}"#)),
            ("input-1", true, JSONValue.parse(#"{"sessionId":"s","userInputId":"input-1","answers":{"Q?":"free"},"questions":[{"question":"Q?"}]}"#)),
            ("input-2", true, AgentQuestion.answeredInput(multiple, answers: ["Which targets?": "Mac, Phone"])),
            ("input-2", true, AgentQuestion.answeredInput(multiple, answers: ["Which targets?": "Phone,,Mac"])),
            ("input-2", true, AgentQuestion.answeredInput(multiple, answers: ["Which targets?": "Mac, another device"])),
            ("input-2", true, AgentQuestion.answeredInput(multiple, answers: ["Which targets?": "Mac, , Phone"])),
            ("input-2", true, AgentQuestion.answeredInput(multiple, answers: ["Which targets?": "\tMac\t,Phone "])),
            ("input-2", true, AgentQuestion.answeredInput(multiple, answers: ["Which targets?": long])),
            ("input-2", false, multiple),
        ]
        for (index, (requestId, allow, given)) in cases.enumerated() {
            let a = swift.buildPermissionResponse(requestId: requestId, allow: allow, input: given)
            let b = plugin.buildPermissionResponse(requestId: requestId, allow: allow, input: given)
            #expect(Self.normalized(b) == Self.normalized(a), "case \(index)")
        }
    }

    // MARK: Models

    @Test func modelCatalogsAreTheSame() throws {
        let plugin = try Self.plugin()
        let replies = [
            #"{"id":2,"jsonrpc":"2.0","result":{"models":[{"modelId":"muse-wonder-1.0","displayLabel":"Muse Wonder","description":"Complex coding","isDefault":true,"variants":["low","high"],"defaultReasoningEffort":"high"},{"modelId":"muse-wonder-full-1.0","displayLabel":"Muse Wonder Full","isDefault":false,"variants":["high"]}]}}"#,
            #"{"id":2,"result":{"models":[{"modelId":"muse-wonder-full-1.0","isDefault":false}]}}"#,
            #"{"id":2,"result":{"models":[]}}"#,
            #"{"id":2,"result":{"models":[{"modelId":""},{"modelId":7},{"modelId":"other","displayLabel":"Other","isDefault":1,"variants":["a",1,null]},{"modelId":"third","isDefault":true,"description":null}]}}"#,
            #"{"id":2.4,"result":{"models":[{"modelId":"x"}]}}"#,
            #"{"id":1,"result":{"models":[{"modelId":"x"}]}}"#,
            #"{"id":2,"result":{"models":{}}}"#,
            #"{"id":2,"result":null}"#,
            "not json", "",
        ]
        for reply in replies {
            let expected = MuseModelDiscovery.catalog(reply)
            let answer = plugin.script.evaluate("MuseAgent.modelCatalog(\(JSONValue.string(reply).compact()))")
            let actual = answer.flatMap { AgentEventJSON.decodeCodable(ModelCatalog.self, $0) }
            #expect(actual == expected, "\(reply)")
            #expect((answer == nil) == (expected == nil), "\(reply)")
        }
    }

    // MARK: Naming

    @Test func namingIsTheSame() throws {
        let plugin = try Self.plugin()
        let namings: [(String, String, String?, String?)] = [("Name this chat", "/tmp/clean-worktree", "/opt/muse" as String?, "muse-wonder-1.0" as String?),
                                              ("-starts with a dash", "/tmp/h", nil, nil), ("", "/tmp/h", nil, "")]
        for (prompt, home, binary, model) in namings {
            let a = try #require(swift.namingLaunch(prompt: prompt, home: home, binary: binary, model: model))
            let b = try #require(plugin.namingLaunch(prompt: prompt, home: home, binary: binary, model: model))
            expectSameSpec(a, b, "naming \(prompt)")
            let checkA = try #require(swift.namingCheck(home: home, binary: binary))
            let checkB = try #require(plugin.namingCheck(home: home, binary: binary))
            expectSameSpec(checkA, checkB, "naming check")
        }
        var outputs = try Self.fixtures.map(Self.text)
        outputs += ["", "\n\n", "not json",
                    #"{"payload_type":"run.terminal.completed","payload":{"text":"one"}}"# + "\n"
                        + #"{"payload_type":"run.terminal.completed","payload":{"text":7}}"# + "\n"
                        + #"{"payload_type":"run.terminal.failed","payload":{"reason":"why"}}"#,
                    #"{"payload_type":"run.terminal.completed","payload":{"text":"a"}}"# + "\r\n"
                        + #"{"payload_type":"run.terminal.completed","payload":{"text":"b"}}"#,
                    #"{"payload_type":"run.terminal.completed","payload":{"text":"a"}}"# + "\n\r\n"
                        + #"{"payload_type":"run.terminal.failed","payload":{"reason":"b"}}"# + "\n",
                    "--preset --no-session-log --disable-shell --disable-write --disable-web-tools",
                    "--preset --no-session-log"]
        for output in outputs {
            #expect(plugin.namingAnswer(output) == swift.namingAnswer(output))
            #expect(plugin.namingError(output) == swift.namingError(output))
            #expect(plugin.namingCheckPasses(output) == swift.namingCheckPasses(output))
        }
    }
}
