import Foundation
import Testing
@testable import AbstractCore

/// Codex's agent plugin (ABS-185) against the Swift `CodexProvider` it
/// replaces: every fixture line folds to the same events, every launch,
/// naming call and setting matches, `/compact` holds the same conversation
/// with `codex app-server`, and edits get the same diffs written in.
@Suite(.serialized) struct CodexPluginParityTests {
    let swift = CodexProvider()

    static func plugin() throws -> ScriptedProvider {
        try #require(AgentPlugins.shared.anyAgent("codex"))
    }

    static let fixtures = ["codex-stream", "codex-mcp", "codex-warnings"]

    static func lines(_ name: String) throws -> [String] {
        try text(name).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    static func text(_ name: String) throws -> String {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func js(_ text: String) -> String { JSONValue.string(text).compact() }

    static func nested(_ depth: Int) -> String { String(repeating: "[", count: depth) + String(repeating: "]", count: depth) }

    /// Lines no parser should trip on, and the corners of each item type.
    static let oddLines: [String] = [
        "", "   ", " \t\u{85}", "not json", "{not json", "[]", "42", "null", "\"text\"", "{}", #"{"type":7}"#,
        #"{"type":"something.new"}"#, "warn: x", "\r",
        // Threads and turns.
        #"{"type":"thread.started"}"#, #"{"type":"thread.started","thread_id":7}"#, #"{"type":"thread.started","thread_id":"t-odd"}"#,
        #"{"type":"thread.started","thread_id":"first","thread_id":"second"}"#,
        #"{"type":"turn.started",}"#, "\u{feff}{\"type\":\"turn.started\"}", "\u{feff}\u{feff}{\"type\":\"turn.started\"}",
        "  {\"type\":\"turn.started\"}\u{85}", "{\"type\":\"turn.started\"}\r",
        #"{"type":"turn.completed"}"#, #"{"type":"turn.completed","usage":[1,2]}"#, #"{"type":"turn.completed","usage":null}"#,
        #"{"type":"turn.completed","usage":{"input_tokens":10.9,"output_tokens":-3.7,"cached_input_tokens":"5","cache_write_input_tokens":true}}"#,
        #"{"type":"turn.completed","usage":{"input_tokens":1e300,"output_tokens":9.3e18,"cached_input_tokens":-9.3e18,"cache_write_input_tokens":9.2e18}}"#,
        #"{"type":"turn.completed","usage":{"input_tokens":-0,"output_tokens":1e-320}}"#,
        #"{"type":"turn.completed","usage":{"input_tokens":1e400}}"#, #"{"type":"turn.completed","usage":{"input_tokens":1e-400}}"#,
        #"{"type":"turn.completed","usage":{"input_tokens":2.4e-324}}"#, #"{"type":"turn.completed","usage":{"input_tokens":0e-400}}"#,
        #"{"type":"turn.failed","error":{"message":"nope"}}"#, #"{"type":"turn.failed","error":"flat"}"#,
        #"{"type":"turn.failed","message":"top"}"#, #"{"type":"turn.failed","error":{"message":""}}"#, #"{"type":"turn.failed"}"#,
        #"{"type":"turn.failed","error":{"message":7},"message":"fallback"}"#,
        #"{"type":"error","message":"boom"}"#, #"{"type":"error","message":""}"#, #"{"type":"error"}"#,
        #"{"type":"error","error":{"message":"nested"}}"#, #"{"type":"error","error":"Model metadata for `x` not found"}"#,
        // Items.
        #"{"type":"item.started"}"#, #"{"type":"item.completed","item":null}"#, #"{"type":"item.completed","item":{"type":7}}"#,
        #"{"type":"item.completed","item":"flat"}"#, #"{"type":"item.completed","item":{"id":"m0"}}"#,
        #"{"type":"item.started","item":{"id":"x""#,
        #"{"type":"item.updated","item":{"id":"m","type":"agent_message","text":"Hel"}}"#,
        #"{"type":"item.completed","item":{"id":"m","type":"agent_message","text":"Hello 😀 é"}}"#,
        #"{"type":"item.completed","item":{"type":"agent_message"}}"#, #"{"type":"item.completed","item":{"id":7,"type":"agent_message","text":5}}"#,
        #"{"type":"item.started","item":{"id":"r","type":"reasoning","text":"thinking"}}"#,
        #"{"type":"item.completed","item":{"id":"r","type":"reasoning","summary":"sum"}}"#,
        #"{"type":"item.completed","item":{"id":"r2","type":"reasoning","summary":["a"]}}"#,
        #"{"type":"item.started","item":{"id":"c1","type":"command_execution","command":"ls","exit_code":null,"status":"in_progress"}}"#,
        #"{"type":"item.updated","item":{"id":"c1","type":"command_execution","command":"ls","aggregated_output":"a"}}"#,
        #"{"type":"item.completed","item":{"id":"c1","type":"command_execution","command":"ls","aggregated_output":"a\nb","exit_code":0}}"#,
        #"{"type":"item.completed","item":{"id":"c2","type":"command_execution","exit_code":1,"status":"failed"}}"#,
        #"{"type":"item.completed","item":{"id":"c3","type":"command_execution","command":7,"exit_code":1e300}}"#,
        #"{"type":"item.completed","item":{"id":"c4","type":"command_execution","exit_code":"1"}}"#,
        #"{"type":"item.completed","item":{"id":"c5","type":"command_execution","exit_code":true}}"#,
        #"{"type":"item.completed","item":{"id":"c6","type":"command_execution","exit_code":-0}}"#,
        #"{"type":"item.completed","item":{"id":"c7","type":"command_execution","exit_code":0.5}}"#,
        #"{"type":"item.completed","item":{"type":"command_execution","exit_code":1e400}}"#,
        #"{"type":"item.started","item":{"id":"e","type":"error","message":"early"}}"#,
        #"{"type":"item.completed","item":{"id":"e","type":"error","message":"`x` is deprecated"}}"#,
        #"{"type":"item.completed","item":{"id":"e","type":"error","message":""}}"#, #"{"type":"item.completed","item":{"id":"e","type":"error"}}"#,
        #"{"type":"item.completed","item":{"id":"e","type":"error","message":"service tier unavailable"}}"#,
        // File changes.
        #"{"type":"item.completed","item":{"type":"file_change","changes":[null],"diff":5}}"#,
        #"{"type":"item.completed","item":{"id":"p","type":"file_change","status":"completed","changes":[{"path":"a.txt","diff":"--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-old\n+new\n"}]}}"#,
        #"{"type":"item.started","item":{"id":"i","type":"file_change","changes":[{"path":"/w/a.swift","kind":"update"},{"path":"/w/b.swift","kind":"add"}],"status":"in_progress"}}"#,
        #"{"type":"item.updated","item":{"id":"i","type":"file_change","changes":[{"path":"/w/a.swift","kind":"update"},{"path":"/w/b.swift","kind":"add"}],"status":"in_progress"}}"#,
        #"{"type":"item.completed","item":{"id":"i","type":"file_change","changes":[{"path":"/w/a.swift","kind":"update"},{"path":"/w/b.swift","kind":"add"},{"path":7},{"kind":"add"},"x",{"path":"/w/c.swift","kind":null}],"status":"completed"}}"#,
        #"{"type":"item.completed","item":{"id":"f0","type":"file_change","changes":[]}}"#,
        #"{"type":"item.completed","item":{"id":"f1","type":"file_change","path":"top.txt","diff":"@@ -1,2 +1,3 @@\n a\n+b\n c\n@@ -10,2 +11,2 @@\n-x\n+y\n z\n\\ No newline at end of file\n"}}"#,
        #"{"type":"item.completed","item":{"id":"f2","type":"patch_apply","status":"failed","file_path":"p.txt","unified_diff":"+one\n-two\n three\nfour\n"}}"#,
        #"{"type":"item.completed","item":{"id":"f3","type":"patch_apply","changes":[{"path":"q.txt","kind":"add","unified_diff":"@@ -0,0 +1,2 @@\n+a\n+b"}],"status":"error"}}"#,
        #"{"type":"item.completed","item":{"id":"f4","type":"file_change","changes":[{"path":"h.txt","diff":"@@@@ -+3,x +-4,5 @@ ctx\n+a\n@@ -9007199254740990 +abc @@\n b\n@@ -1 +2\n-c\n@@ +7,1 -8 @@ extra -1\n d\n"}]}}"#,
        #"{"type":"item.completed","item":{"id":"f5","type":"file_change","changes":[{"path":"crlf.txt","diff":"@@ -1 +1 @@\r\n-a\r\n+b\r\n"}]}}"#,
        #"{"type":"item.completed","item":{"id":"f6","type":"file_change","changes":[{"path":"u.txt","diff":"+😀 face\n-é\n+́mark\n+++́x\n@@́ -1 +1 @@\n x\n"}]}}"#,
        #"{"type":"item.completed","item":{"id":"f7","type":"file_change","changes":[{"path":"e.txt","diff":"--- a\n+++ b\n"}]}}"#,
        #"{"type":"item.completed","item":{"id":"f8","type":"file_change","changes":[{"path":"n.txt","diff":null,"unified_diff":"+x"}]}}"#,
        #"{"type":"item.completed","item":{"id":"f9","type":"file_change","kind":"add","changes":"nope","diff":"+x"}}"#,
        // MCP and other tools.
        #"{"type":"item.started","item":{"id":"m1","type":"mcp_tool_call","server":"","tool":"t","arguments":null}}"#,
        #"{"type":"item.completed","item":{"id":"m1","type":"mcp_tool_call","server":"","tool":"t","result":{"content":[{"text":"a"},{"type":"image"},{"text":"b"}]},"status":"completed"}}"#,
        #"{"type":"item.completed","item":{"id":"m2","type":"mcp_tool_call","server":"s","result":{"content":[]},"output":"fallback"}}"#,
        #"{"type":"item.completed","item":{"id":"m3","type":"mcp_tool_call","server":"s","tool":"x","error":"flat","status":"completed"}}"#,
        #"{"type":"item.completed","item":{"id":"m4","type":"mcp_tool_call","server":7,"tool":7,"error":{"message":5},"status":"error"}}"#,
        #"{"type":"item.completed","item":{"id":"m5","type":"mcp_tool_call","server":"s","tool":"x","result":{"content":[{"text":""}]},"text":"t"}}"#,
        #"{"type":"item.started","item":{"id":"td","type":"todo_list","items":[{"text":"a","completed":false}]}}"#,
        #"{"type":"item.completed","item":{"id":"td","type":"todo_list","items":[],"status":"failed","result":"r"}}"#,
        #"{"type":"item.completed","item":{"id":"ws","type":"web_search","query":"swift","output":"o","status":"error"}}"#,
        #"{"type":"item.started","item":{"id":"pr","type":"web_search","__proto__":{"x":1},"constructor":2}}"#,
        #"{"type":"item.completed","item":{"id":"z","type":"collab_tool_call"}}"#,
        // A turn starting again forgets the calls it had open.
        #"{"type":"turn.started"}"#,
        #"{"type":"item.completed","item":{"id":"c1","type":"command_execution","command":"ls","exit_code":2}}"#,
        // How deep Foundation reads, and what it refuses.
        #"{"type":"item.started","item":{"id":"deep1","type":"mcp_tool_call","server":"s","tool":"t","arguments":"# + nested(40) + "}}",
        #"{"type":"item.started","item":{"id":"deep2","type":"mcp_tool_call","server":"s","tool":"t","arguments":"# + nested(64) + "}}",
        #"{"type":"item.started","item":{"id":"esc","type":"agent_message","text":"\ud83d\ude00 \u00e9 \/ \u0000"}}"#,
        #"{"type":"item.started","item":{"id":"lone","type":"agent_message","text":"\udc00"}}"#,
        #"{"type":"item.started","item":{"id":"lone2","type":"agent_message","text":"\ud800A"}}"#,
        "{\"type\":\"item.started\",\"item\":{\"id\":\"tab\",\"type\":\"agent_message\",\"text\":\"a\tb\"}}",
        #"{"type":"item.started","item":{"id":"comma","type":"agent_message","text":"x",},}"#,
        #"{"type":"item.started","item":{"id":"comma2","type":"agent_message","text":"x",,}}"#,
        #"{"type":"turn.started"} x"#, #"{"type":"turn.started"}[]"#, "[1,]", #"{'type':'turn.started'}"#,
    ]

    func expectSameFold(_ lines: [String], plugin: ScriptedProvider, sourceLocation: SourceLocation = #_sourceLocation) {
        for stream in [OutputStreamKind.stdout, .stderr] {
            let a = swift.makeParser(), b = plugin.makeParser()
            for (index, line) in lines.enumerated() {
                let expected = a.feed(line, stream: stream), actual = b.feed(line, stream: stream)
                #expect(actual == expected, "line \(index + 1) on \(stream): \(line.prefix(300))", sourceLocation: sourceLocation)
            }
            for code in [Int32(0), 1, 2, -9, nil] as [Int32?] {
                #expect(b.onExit(code: code) == a.onExit(code: code), "exit \(String(describing: code)) on \(stream)",
                        sourceLocation: sourceLocation)
            }
        }
        // A batch reads the same as line by line.
        let one = plugin.makeParser(), many = plugin.makeParser()
        let batched = many.feed(lines: lines.map { OutputLine(stream: .stdout, line: $0) })
        #expect(batched == lines.map { one.feed($0, stream: .stdout) }, sourceLocation: sourceLocation)
        // The retired local agents' filter reads the plugin's events the same.
        let local = LocalModelParser(swift.makeParser()), pluginLocal = LocalModelParser(plugin.makeParser())
        for line in lines {
            #expect(pluginLocal.feed(line, stream: .stdout) == local.feed(line, stream: .stdout), "local \(line.prefix(200))",
                    sourceLocation: sourceLocation)
        }
    }

    // MARK: Folding

    @Test(arguments: fixtures)
    func fixturesFoldTheSame(_ fixture: String) throws {
        let plugin = try Self.plugin()
        let lines = try Self.lines(fixture)
        expectSameFold(lines, plugin: plugin)
        expectSameFold(lines + Self.oddLines, plugin: plugin)
        // Nothing in a recording is left raw.
        let parser = plugin.makeParser()
        let raws = lines.flatMap { parser.feed($0, stream: .stdout) }.filter { if case .raw = $0 { true } else { false } }
        #expect(raws.isEmpty)
    }

    @Test func oddLinesFoldTheSame() throws {
        let plugin = try Self.plugin()
        expectSameFold(Self.oddLines, plugin: plugin)
        expectSameFold(Array(Self.oddLines.reversed()), plugin: plugin)
        for line in Self.oddLines { expectSameFold([line], plugin: plugin) }
        expectSameFold([], plugin: plugin)
    }

    @Test func theAppServerFixtureFoldsTheSame() throws {
        // Not `exec` output, but a chat's log must never trip on it.
        expectSameFold(try Self.lines("codex-app-server-compact"), plugin: try Self.plugin())
    }

    // MARK: Launching

    /// A real picture on disk; Codex is handed its path.
    static let picture: String = {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("abstract-codex-parity-\(getpid()).png").path
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!
        FileManager.default.createFile(atPath: path, contents: png)
        return path
    }()

    static func contexts(_ policy: PermissionPolicy) -> [LaunchContext] {
        let linear = MCPServerLaunch(name: "linear", connection: .url("https://mcp.linear.app/mcp",
                                                                      headers: ["Authorization": "Bearer lin_test", "x-api key": "k", "X_API-KEY": "dup"]),
                                     allowed: ["list_issues", "get \"issue\""], askFirst: ["create_issue"], off: ["delete_issue"],
                                     notes: "File bugs in team ABS.")
        let sentry = MCPServerLaunch(name: "sentry", connection: .command(["sentry-mcp", "--stdio", "a b"], env: ["SENTRY_TOKEN": "t", "B": "2", "a": "1"]),
                                     off: ["purge"])
        let odd = MCPServerLaunch(name: "über srv-ß", connection: .url("http://localhost:1/x", headers: ["ß-key": "v", "e\u{301}": "w", "😀": "x"]),
                                  allowed: ["t"], notes: "  \n  ")
        let empty = MCPServerLaunch(name: "empty", connection: .command([], env: [:]), askFirst: ["a"], notes: "Use it.\n")
        let history = HistoryToolLaunch(command: "/Applications/Abstract.app/Contents/MacOS/abstract", chatId: "chat-1",
                                        instructionFile: "/tmp/history.md")
        return [
            LaunchContext(cwd: "/tmp/work", prompt: "make hi.txt", permissionPolicy: policy),
            LaunchContext(cwd: "/tmp/w t", prompt: "-starts with a dash", permissionPolicy: policy, extraArgs: ["--verbose", "x y"],
                          binaryOverride: "  /opt/codex  ", model: "gpt-6-astra", effort: "high", outputStyle: .concise,
                          images: [Self.picture, "/nonexistent/a.png"], historyTool: history,
                          branchTool: BranchToolLaunch(command: "/bin/abstract", chatId: "chat \"1\""),
                          instructions: "Be a pirate.", pluginTools: PluginToolsLaunch(command: "/bin/abstract", chatId: "chat-1"),
                          toolServers: [linear, sentry], configDirectory: "/tmp/config-dir", skills: SkillsLaunch(folder: "/tmp/skills-home")),
            LaunchContext(cwd: "/tmp/work/", prompt: "Plan \"this\" / that\n\u{1}", permissionPolicy: policy, binaryOverride: "   ",
                          model: "  ", effort: "turbo", outputStyle: .explanatory, instructions: "   \n", toolServers: [odd, empty]),
            LaunchContext(cwd: "/tmp/work", prompt: "-\u{301} not a dash", permissionPolicy: policy, outputStyle: .learning,
                          historyTool: HistoryToolLaunch(command: "abstract", chatId: "c"), toolServers: [sentry]),
            LaunchContext(cwd: "/tmp/work", prompt: "", permissionPolicy: policy, outputStyle: .proactive, images: ["/x.png"],
                          skills: SkillsLaunch(folder: "/tmp/s")),
        ]
    }

    func expectSameSpec(_ a: LaunchSpec, _ b: LaunchSpec, _ note: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(b.command == a.command, "\(note) command", sourceLocation: sourceLocation)
        #expect(b.args == a.args, "\(note) args", sourceLocation: sourceLocation)
        #expect(b.cwd == a.cwd, "\(note) cwd", sourceLocation: sourceLocation)
        #expect(b.env == a.env, "\(note) env", sourceLocation: sourceLocation)
        #expect(b.keepStdinOpen == a.keepStdinOpen, "\(note) keepStdinOpen", sourceLocation: sourceLocation)
        #expect(b.stdinInitial == a.stdinInitial, "\(note) stdin", sourceLocation: sourceLocation)
    }

    @Test(arguments: PermissionPolicy.allCases)
    func launchesTheSame(_ policy: PermissionPolicy) throws {
        let plugin = try Self.plugin()
        for (index, ctx) in Self.contexts(policy).enumerated() {
            expectSameSpec(swift.buildLaunch(ctx), plugin.buildLaunch(ctx), "launch \(index) \(policy)")
            for resumeId in ["thread-1", "-dash", ""] {
                expectSameSpec(swift.buildResume(ctx, resumeId: resumeId), plugin.buildResume(ctx, resumeId: resumeId),
                               "resume \(index) \(policy) \(resumeId)")
            }
        }
        #expect(plugin.permissionDetail(policy) == swift.permissionDetail(policy))
    }

    @Test func helpersMatchTheSwiftOnes() throws {
        let plugin = try Self.plugin()
        let texts = ["", "plain", "a\"b\\c/d", String((0..<32).map { Character(UnicodeScalar($0)!) }) + "\u{7f}\u{85}\u{2028}\u{2029}é😀\u{feff}"]
        for text in texts {
            #expect(plugin.script.evaluate("CodexAgent.tomlString(\(Self.js(text)))")?.string == CodexProvider.tomlString(text))
        }
        #expect(plugin.script.evaluate("CodexAgent.tomlArray([\(texts.map(Self.js).joined(separator: ","))])")?.string == CodexProvider.tomlArray(texts))
        let branch = BranchToolLaunch(command: "/bin/abstract", chatId: "chat")
        let args = plugin.script.evaluate("CodexAgent.branchArgs({ serverCommand: \(JSONValue.array(branch.serverCommand.map(JSONValue.string)).compact()) })")
        #expect(args?.array?.compactMap(\.string) == CodexProvider.branchArgs(branch))
        let history = HistoryToolLaunch(command: "/bin/abstract", chatId: "c")
        #expect(plugin.script.evaluate("CodexAgent.historyArgs({ serverCommand: \(JSONValue.array(history.serverCommand.map(JSONValue.string)).compact()) })")?
            .array?.compactMap(\.string) == CodexProvider.historyArgs(history))
        let tools = PluginToolsLaunch(command: "/bin/abstract", chatId: "c")
        #expect(plugin.script.evaluate("CodexAgent.pluginArgs({ serverCommand: \(JSONValue.array(tools.serverCommand.map(JSONValue.string)).compact()) })")?
            .array?.compactMap(\.string) == CodexProvider.pluginArgs(tools))
        #expect(plugin.script.evaluate("CodexAgent.skillEnv({ folder: '/s' })") == .object(["CODEX_HOME": .string("/s")]))
        for (name, key) in [("linear", "Authorization"), ("über srv-ß", "e\u{301}-x"), ("a.b", "😀"), ("x\u{301}-", "ﬁ")] {
            let server = MCPServerLaunch(name: name, connection: .command([], env: [:]))
            #expect(plugin.script.evaluate("CodexAgent.secretVariable(\(Self.js(name)), \(Self.js(key)))")?.string == server.secretVariable(key),
                    "\(name) \(key)")
        }
    }

    // MARK: The agent and its settings

    @Test func describesTheSameAgent() throws {
        let plugin = try Self.plugin()
        #expect(plugin.id == swift.id)
        #expect(plugin.name == swift.name)
        #expect(plugin.logoAsset == swift.logoAsset)
        #expect(plugin.binary == swift.binary)
        #expect(plugin.detectArgs == swift.detectArgs)
        #expect(plugin.followUpMode == swift.followUpMode)
        #expect(plugin.skillDelivery == swift.skillDelivery)
        #expect(plugin.toolServerSupport == swift.toolServerSupport)
        #expect(plugin.commands == swift.commands)
        guard case .sideChannel = plugin.compaction else { Issue.record("no side channel"); return }
        #expect(plugin.fallbackModels == swift.fallbackModels)
        #expect(plugin.makeLineEnricher(executor: LocalExecutor.shared, cwd: "/tmp") != nil)
        #expect(plugin.buildUserMessage("hi") == swift.buildUserMessage("hi"))
        #expect(plugin.buildUserMessage("hi", images: [Self.picture], sessionId: "s") == swift.buildUserMessage("hi", images: [Self.picture], sessionId: "s"))
        #expect(plugin.buildPermissionResponse(requestId: "r", allow: true, input: nil) == swift.buildPermissionResponse(requestId: "r", allow: true, input: nil))
        #expect(plugin.buildInterrupt(requestId: "r") == swift.buildInterrupt(requestId: "r"))
        #expect(plugin.buildStopTask("t", requestId: "r") == swift.buildStopTask("t", requestId: "r"))
        #expect(plugin.buildBackground(toolUseId: "t", requestId: "r") == swift.buildBackground(toolUseId: "t", requestId: "r"))
        #expect(plugin.buildPermissionModeChange(.bypass, requestId: "r") == swift.buildPermissionModeChange(.bypass, requestId: "r"))
    }

    @Test func readsTheSameConfiguredModelAndEffort() throws {
        let plugin = try Self.plugin()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("codex-parity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent(".codex/config.toml")
        let configs = [
            "model = \"gpt-5\"\nmodel_reasoning_effort = \"high\"\n", "  model=\"o3\"  ", "model_provider = \"x\"\nmodel = 'single'\n",
            "[profile]\nmodel = \"inside\"", "model = \"a\"\n[x]\nmodel = \"b\"", "modelx = \"no\"\nmodel = \"yes\"", "model = \"\"",
            "model = \"\"quoted\"''", "# comment\nmodel = gpt-5 # trailing", "model = \"x\"\r\nmodel_reasoning_effort = \"y\"\r\n",
            "\u{feff}model = \"bom\"", "\tmodel\t=\t\"tabs\"\t", "model", "model = \"é\"", "", "\u{a0}model = \"nbsp\"\u{3000}", "model =",
            "\nmodel_reasoning_effort='low'\n\n", "model\u{301} = \"accent\"\nmodel = \"plain\"", " [table]\nmodel = \"x\"",
            "model = \"a\" = \"b\"", "model_reasoning_effort = high\nmodel_reasoning_effort = \"second\"", "model\n= \"split\"",
        ]
        for contents in configs {
            try contents.write(to: file, atomically: true, encoding: .utf8)
            #expect(plugin.configuredDefaultModel(home: home.path) == swift.configuredDefaultModel(home: home.path), "\(contents.debugDescription)")
            #expect(plugin.configuredDefaultEffort(home: home.path) == swift.configuredDefaultEffort(home: home.path), "\(contents.debugDescription)")
        }
        #expect(plugin.configuredDefaultModel(home: home.path + "/missing") == swift.configuredDefaultModel(home: home.path + "/missing"))
        #expect(plugin.configuredDefaultEffort(home: home.path + "/missing") == swift.configuredDefaultEffort(home: home.path + "/missing"))
    }

    // MARK: Models

    static let cache = #"""
    {"fetched_at":"2026-09-22T12:00:00Z","etag":"W/\"abc\"","client_version":"0.153.4","models":[
     {"slug":"gpt-5.5","display_name":"GPT-5.5","description":"Proven previous-generation model.","default_reasoning_level":"medium","supported_reasoning_levels":[{"effort":"low","description":"x"},{"effort":"medium","description":"x"},{"effort":"high","description":"x"},{"effort":"xhigh","description":"x"}],"visibility":"list","priority":12,"upgrade":{"model":"gpt-5.6-sol","migration_markdown":"GPT-5.5 retires on October 14, 2026.","retirement_at":"2026-10-14T19:00:00Z"}},
     {"slug":"gpt-6-astra","display_name":"GPT-6-Astra","description":"Our most capable model for complex, demanding work.","default_reasoning_level":"low","supported_reasoning_levels":[{"effort":"low","description":"x"},{"effort":"medium","description":"x"},{"effort":"high","description":"x"},{"effort":"xhigh","description":"x"},{"effort":"max","description":"x"},{"effort":"ultra","description":"x"}],"visibility":"list","priority":1,"upgrade":null},
     {"slug":"gpt-reserve","display_name":"GPT-Reserve","description":"Fast and affordable agentic coding model.","default_reasoning_level":"medium","supported_reasoning_levels":[{"effort":"low","description":"x"}],"visibility":"hide","priority":3,"upgrade":null},
     {"slug":"gpt-6-sol","display_name":"GPT-6-Sol","description":"Balanced.","default_reasoning_level":"medium","supported_reasoning_levels":[{"effort":"low","description":"x"},{"effort":"medium","description":"x"}],"visibility":"list","priority":2,"upgrade":null}
    ]}
    """#

    static let caches: [String] = [
        cache, "{}", #"{"models":[]}"#, "garbage", "", "[]", #"{"models":{}}"#, #"{"models":null}"#, #"{"models":[1,null,"x",[]],}"#,
        #"{"models":[{"slug":"a","priority":2},{"slug":"b"},{"slug":"c","priority":-1.5},{"slug":"d","priority":"1"},{"slug":"e","priority":2},{"slug":"f","priority":1e308}]}"#,
        #"{"models":[{"slug":""},{"slug":7},{"display_name":"no slug"},{"slug":"v","visibility":7},{"slug":"w","visibility":null},{"slug":"x","visibility":"List"}]}"#,
        #"{"models":[{"slug":"s","display_name":null,"description":null,"default_reasoning_level":5,"supported_reasoning_levels":[{"effort":"low"},{"effort":7},"high",null,{}]}]}"#,
        #"{"models":[{"slug":"s","supported_reasoning_levels":"low"},{"slug":"t","supported_reasoning_levels":null}]}"#,
        #"{"models":[{"slug":"u1","upgrade":{}},{"slug":"u2","upgrade":"soon"},{"slug":"u3","upgrade":{"retirement_at":7}},{"slug":"u4","upgrade":[]}]}"#,
        #"{"models":[{"slug":"d","upgrade":{"retirement_at":"2026-10-14T19:00:00.000Z"}},{"slug":"d2","upgrade":{"retirement_at":"2026-10-14T23:30:00+02:00"}},{"slug":"d3","upgrade":{"retirement_at":"2026-10-14T01:30:00-0800"}},{"slug":"d4","upgrade":{"retirement_at":"2026-02-30T19:00:00Z"}},{"slug":"d5","upgrade":{"retirement_at":"2026-10-14"}},{"slug":"d6","upgrade":{"retirement_at":"2026-12-31T24:00:00Z"}},{"slug":"d7","upgrade":{"retirement_at":"2026-09-22T12:00:00Z"}},{"slug":"d8","upgrade":{"retirement_at":"2026-09-22T12:00:01Z"}}]}"#,
        #"{"models":[{"slug":"dup","slug":"second","priority":1,"priority":0}],"models":[]}"#,
        #"{"models":[{"slug":"big","priority":1e400}]}"#,
    ]

    @Test func modelCataloguesAreTheSame() throws {
        let plugin = try Self.plugin()
        let now = ISO8601DateFormatter().date(from: "2026-09-22T12:00:00Z")!
        for zone in ["UTC", "America/Los_Angeles", "Asia/Tokyo", "Pacific/Kiritimati"] {
            for when in [now, now.addingTimeInterval(86_400 * 60), now.addingTimeInterval(-86_400 * 400)] {
                for text in Self.caches {
                    let expected = CodexProvider.modelCatalog(modelsCache: text, now: when, timeZone: TimeZone(identifier: zone)!)
                    let answer = plugin.script.evaluate("CodexAgent.modelCatalog(\(Self.js(text)), \(when.timeIntervalSince1970 * 1000), \(Self.js(zone)))")
                    let actual = answer.flatMap { AgentEventJSON.decodeCodable(ModelCatalog.self, $0) }
                    #expect(actual == expected, "\(zone) \(when) \(text.prefix(200))")
                    #expect((answer == nil) == (expected == nil), "\(text.prefix(200))")
                }
            }
        }
    }

    @Test func readsDatesAsTheFormatterDoes() throws {
        let plugin = try Self.plugin()
        let dates = ["2026-10-14T19:00:00Z", "2026-10-14T19:00:00.000Z", "2026-10-14T19:00:00+02:00", "2026-10-14T19:00:00+0200",
                     "2026-10-14T19:00:00+02", "2026-10-14T19:00:00-08:30", "2026-10-14T19:00:00z", "2026-10-14t19:00:00Z",
                     "2026-10-14 19:00:00Z", "2026-13-14T19:00:00Z", "2026-02-30T19:00:00Z", "2026-10-14T25:00:00Z", "2026-10-14T24:00:00Z",
                     "2026-10-14", "2026-10-14T19:00Z", " 2026-10-14T19:00:00Z", "\n2026-10-14T19:00:00Z", "2026-10-14T19:00:00Z ",
                     "2026-10-14T19:00:60Z", "2026-10-14T19:60:00Z", "2026-10-32T19:00:00Z", "2026-10-00T19:00:00Z", "2026-1-14T19:00:00Z",
                     "2026-10-14T19:00:00GMT", "2026-10-14T19:00:00UTC", "2026-10-14T19:00:00 Z", "2026-10-14T19:00:00Zx",
                     "1969-12-31T23:59:59Z", "2026-10-14T19:00:00-00:00", "2026-10-14T19:00:00+14:00", "", "garbage"]
        for text in dates {
            let expected = ISO8601DateFormatter().date(from: text).map { $0.timeIntervalSince1970 * 1000 }
            let actual = plugin.script.evaluate("CodexAgent.parseDate(\(Self.js(text)))")?.double
            #expect(actual == expected, "\(text.debugDescription)")
        }
    }

    /// Both read ~/.codex/models_cache.json on the executor's Mac; the
    /// plugin gets it from the host as one of its `config` files.
    @Test func discoveryFindsTheSameModels() async throws {
        let plugin = try Self.plugin()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("codex-parity-models-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: home + "/.codex", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        let executor = ParityHomeExecutor(homeDirectory: home)

        #expect(await swift.discoverModels(executor: executor, binary: nil) == nil)
        #expect(await plugin.discoverModels(executor: executor, binary: nil) == nil)
        for text in [Self.cache, "garbage", #"{"models":[{"slug":"only"}]}"#] {
            try text.write(toFile: home + "/.codex/models_cache.json", atomically: true, encoding: .utf8)
            let expected = await swift.discoverModels(executor: executor, binary: nil)
            let actual = await plugin.discoverModels(executor: executor, binary: nil)
            #expect(actual == expected, "\(text.prefix(100))")
        }
    }

    // MARK: Naming

    @Test func namingIsTheSame() throws {
        let plugin = try Self.plugin()
        let namings: [(String, String, String?, String?)] = [("Name this chat", "/tmp/h", "/opt/codex", "gpt-6-astra"),
                                                             ("-starts with a dash", "/tmp/h t", nil, nil), ("", "/tmp/h", nil, "")]
        for (prompt, home, binary, model) in namings {
            let a = try #require(swift.namingLaunch(prompt: prompt, home: home, binary: binary, model: model))
            let b = try #require(plugin.namingLaunch(prompt: prompt, home: home, binary: binary, model: model))
            expectSameSpec(a, b, "naming \(prompt)")
            #expect(plugin.namingCheck(home: home, binary: binary) == swift.namingCheck(home: home, binary: binary))
        }
        func message(_ text: String) -> String { #"{"type":"item.completed","item":{"id":"m","type":"agent_message","text":\#(Self.js(text))}}"# }
        var outputs = try (Self.fixtures + ["codex-app-server-compact"]).map(Self.text)
        outputs += ["", "\n\n", "not json", Self.oddLines.joined(separator: "\n"),
                    message("one") + "\n" + message("two"), message("a") + "\r\n" + message("b"), message("a") + "\n\r\n" + message("b") + "\n",
                    #"{"type":"item.completed","item":{"type":"agent_message","text":7}}"#,
                    #"{"type":"item.completed","item":{"type":"agent_message"}}"# + "\n" + message(""),
                    #"{"type":"item.completed","item":"x"}"#, #"{"type":"item.started","item":{"type":"agent_message","text":"early"}}"#,
                    message("x") + ",", #"{"type":"item.completed","item":{"type":"agent_message","text":"first","text":"second"},}"#,
                    #"{"type":"error","message":"Reconnecting"}"# + "\n" + #"{"type":"turn.failed","error":{"message":"final"}}"#,
                    #"{"type":"turn.failed","error":{"message":"final"}}"# + "\n" + #"{"type":"error","message":7}"#,
                    #"{"type":"error","message":"{\"error\":{\"message\":\"inner\",\"type\":\"invalid_request_error\"}}"}"#,
                    #"{"type":"error","message":"{\"error\":{\"message\":7}}"}"#, #"{"type":"error","message":"{\"error\":\"flat\"}"}"#,
                    #"{"type":"error","message":"{\"error\":{\"message\":\"a\"},}"}"#, #"{"type":"error","message":"[1]"}"#,
                    #"{"type":"turn.failed","error":"flat"}"#, #"{"type":"error","message":""}"#]
        for output in outputs {
            #expect(plugin.namingAnswer(output) == swift.namingAnswer(output), "\(output.prefix(200))")
            #expect(plugin.namingError(output) == swift.namingError(output), "\(output.prefix(200))")
            #expect(plugin.namingCheckPasses(output) == swift.namingCheckPasses(output))
        }
    }

    // MARK: Compaction

    static func step(_ value: JSONValue?) -> SideStep<CompactionResult> {
        if let send = value?["send"]?.array { return .send(send.compactMap(\.string)) }
        if let done = value?["done"] { return .finish(result(done)) }
        if let fail = value?["fail"]?.string { return .fail(fail) }
        return .wait
    }

    /// As `ScriptedCompactor` reads the job's answer.
    static func result(_ answer: JSONValue) -> CompactionResult {
        CompactionResult(tokensBefore: answer["tokensBefore"]?.int, tokensAfter: answer["tokensAfter"]?.int,
                         contextWindow: answer["contextWindow"]?.int, summary: answer["summary"]?.string)
    }

    /// The fixture through the plugin's own `compact` job, as Abstract runs it.
    @Test func compactsTheSameThroughTheJob() throws {
        let plugin = try Self.plugin()
        let request: JSONValue = .object(["sessionId": .string("t-1"), "cwd": .string("/tmp/work"), "model": .null, "defaultModel": .null])
        let generator = try #require(plugin.script.make(plugin.id, ["compact"], [request]))
        let first = plugin.script.step(generator, .null)
        #expect(!first.done && first.error == nil)
        let converse = try #require(first.value["converse"])
        #expect(converse["args"] == .array([.string("app-server")]))
        #expect(converse["cwd"]?.string == "/tmp/work")
        #expect(converse["keepStdinOpen"]?.bool == true)
        #expect(converse["timeout"]?.int == 300)
        var reference = CodexCompaction(threadId: "t-1")
        #expect(ScriptedProvider.strings(converse["opening"]) == reference.opening)
        let receive = try #require(first.receive)
        var finished: JSONValue?
        for line in try Self.lines("codex-app-server-compact") where !line.isEmpty {
            let (answer, failed) = plugin.script.callReceive(receive, line)
            #expect(!failed)
            #expect(Self.step(answer) == reference.receive(line), "\(line)")
            if let done = answer?["done"], finished == nil { finished = done }
        }
        let done = try #require(finished)
        let last = plugin.script.step(generator, done)
        #expect(last.done && last.error == nil)
        #expect(Self.result(last.value) == CompactionResult(tokensBefore: 17251, tokensAfter: 5546, contextWindow: 258_400))
    }

    @Test func compactionConversationsAreTheSame() throws {
        let plugin = try Self.plugin()
        let fixture = try Self.lines("codex-app-server-compact").filter { !$0.isEmpty }
        let odd = [
            "WARN something", "", "null", "[]", #"{"error":"flat"}"#, #"{"error":null}"#, #"{"id":1.5,"result":{}}"#, #"{"id":"1","result":{}}"#,
            #"{"id":2,"result":{},}"#, "\u{feff}{\"id\":1,\"result\":{}}", #"{"id":1,"id":2,"result":{}}"#, #"{"id":-0.5}"#,
            #"{"method":"thread/tokenUsage/updated","params":{"tokenUsage":{"last":{"totalTokens":12.9},"modelContextWindow":"big"}}}"#,
            #"{"method":"thread/tokenUsage/updated","params":{"tokenUsage":{"modelContextWindow":100}}}"#,
            #"{"method":"thread/tokenUsage/updated","params":null}"#, #"{"method":"thread/tokenUsage/updated","params":{"tokenUsage":{"last":{"totalTokens":-3}}}}"#,
            #"{"method":"item/started","params":{"item":{"type":"reasoning"}}}"#, #"{"method":"item/completed","params":{"item":{"type":"agentMessage"}}}"#,
            #"{"method":"item/started","params":{"item":{"type":"contextCompaction"}}}"#,
            #"{"method":"thread/tokenUsage/updated","params":{"tokenUsage":{"last":{"totalTokens":99}}}}"#,
            #"{"method":"turn/started","params":{}}"#, #"{"method":7}"#,
        ]
        let endings = [
            #"{"method":"item/completed","params":{"item":{"type":"contextCompaction","id":"i-1"}}}"#,
            #"{"method":"turn/completed","params":{"turn":{"status":"completed"}}}"#,
            #"{"method":"turn/completed","params":{"turn":{"status":"interrupted"}}}"#,
            #"{"method":"turn/completed","params":{"turn":{"status":"failed","error":{"message":"boom"}}}}"#,
            #"{"method":"turn/completed","params":{"error":{"message":"outer"},"turn":{}}}"#,
            #"{"method":"turn/completed"}"#,
            #"{"method":"turn/failed","params":{"turn":{"error":{"message":"boom"}}}}"#, #"{"method":"turn/failed"}"#,
            #"{"error":{"code":-32600,"message":"invalid thread id"},"id":2}"#, #"{"error":{"message":7}}"#, #"{"error":{}}"#,
        ]
        var conversations: [[String]] = [fixture, [fixture[0], fixture[0], fixture[1], fixture[2], fixture[2]] + Array(fixture[3...]),
                                         Array(fixture.reversed()), odd, fixture + odd, odd + fixture]
        for ending in endings {
            conversations.append(Array(fixture.prefix(3)) + [ending])
            conversations.append(Array(fixture.prefix(7)) + [ending] + fixture.suffix(3))
            conversations.append(odd + [ending])
        }
        for threadId in ["t-1", "nope", "weird \"id\" / \\ \u{1}\t é😀\u{2028}"] {
            for (index, lines) in conversations.enumerated() {
                var reference = CodexCompaction(threadId: threadId)
                let opening = plugin.script.evaluate("var parityCompaction = CodexAgent.compaction(\(Self.js(threadId))); parityCompaction.opening")
                #expect(opening == .array(reference.opening.map(JSONValue.string)), "opening \(threadId)")
                for line in lines {
                    let answer = plugin.script.evaluate("parityCompaction.receive(\(Self.js(line)))")
                    #expect(Self.step(answer) == reference.receive(line), "conversation \(index) \(threadId): \(line)")
                }
            }
        }
    }

    // MARK: Edit diffs

    private func repo() async throws -> String {
        let exec = LocalExecutor.shared
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("abstract-codex-parity-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir + "/sub", withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@abstract.local"], ["config", "user.name", "T"],
                     ["config", "commit.gpgsign", "false"]] {
            _ = try await exec.run("git", args, cwd: dir)
        }
        try (1...20).map { "line \($0)\n" }.joined().write(toFile: dir + "/app.txt", atomically: true, encoding: .utf8)
        try "one\ntwo\n".write(toFile: dir + "/sub/inner.txt", atomically: true, encoding: .utf8)
        try "gone\n".write(toFile: dir + "/gone.txt", atomically: true, encoding: .utf8)
        _ = try await exec.run("git", ["add", "-A"], cwd: dir)
        _ = try await exec.run("git", ["commit", "-qm", "init"], cwd: dir)
        return dir
    }

    private static func completed(_ changes: String, type: String = "file_change", event: String = "item.completed") -> String {
        #"{"type":"\#(event)","item":{"id":"i","type":"\#(type)","changes":\#(changes),"status":"completed","exit_code":0,"flag":true,"n":1.5,"none":null}}"#
    }

    private static func change(_ path: String, kind: String = "update") -> String {
        #"{"path":\#(js(path)),"kind":"\#(kind)"}"#
    }

    @Test func editDiffsAreTheSame() async throws {
        let plugin = try Self.plugin()
        let dir = try await repo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let exec = LocalExecutor.shared
        for cwd in [dir, dir + "/"] {
            try (1...20).map { "line \($0)\n" }.joined().write(toFile: dir + "/app.txt", atomically: true, encoding: .utf8)
            let a = try #require(swift.makeLineEnricher(executor: exec, cwd: cwd))
            let b = try #require(plugin.makeLineEnricher(executor: exec, cwd: cwd))
            func expectSame(_ line: OutputLine, _ note: String, changed: Bool? = nil) -> OutputLine {
                let expected = a.enrich(line), actual = b.enrich(line)
                #expect(actual == expected, "\(note) in \(cwd)")
                if let changed { #expect((expected != line) == changed, "\(note) changed in \(cwd)") }
                return expected
            }
            func stdout(_ text: String) -> OutputLine { OutputLine(stream: .stdout, line: text) }
            func edit(_ line: OutputLine) -> EditPreview? {
                for event in swift.makeParser().feed(line.line, stream: line.stream) {
                    if case let .toolResult(_, _, _, edit) = event { return edit }
                }
                return nil
            }

            // The first edit diffs against HEAD.
            try (1...20).map { $0 == 10 ? "ten\n" : "line \($0)\n" }.joined().write(toFile: dir + "/app.txt", atomically: true, encoding: .utf8)
            let first = try #require(edit(expectSame(stdout(Self.completed("[\(Self.change(dir + "/app.txt"))]")), "first edit", changed: true)))
            #expect((first.additions, first.deletions) == (1, 1))
            #expect(first.lines.contains(EditPreview.Line(origin: .added, content: "ten", newLine: 10)))
            // The second against the first, named relative to the worktree.
            try (1...20).map { $0 == 10 ? "ten\n" : $0 == 18 ? "eighteen\n" : "line \($0)\n" }.joined()
                .write(toFile: dir + "/app.txt", atomically: true, encoding: .utf8)
            let second = try #require(edit(expectSame(stdout(Self.completed("[\(Self.change("app.txt"))]")), "second edit", changed: true)))
            #expect((second.additions, second.deletions) == (1, 1))
            #expect(!second.lines.contains { $0.content == "ten" && $0.origin != .context })
            // Unchanged since: an empty diff.
            _ = expectSame(stdout(Self.completed("[\(Self.change("app.txt"))]", type: "patch_apply")), "no change", changed: true)

            try "a\nb\nc\n".write(toFile: dir + "/new.txt", atomically: true, encoding: .utf8)
            _ = expectSame(stdout(Self.completed("[\(Self.change("new.txt", kind: "add"))]")), "new file", changed: true)
            try "x\n".write(toFile: dir + "/untracked.txt", atomically: true, encoding: .utf8)
            _ = expectSame(stdout(Self.completed("[\(Self.change(dir + "/untracked.txt"))]")), "untracked", changed: true)
            try "one\n2\n".write(toFile: dir + "/sub/inner.txt", atomically: true, encoding: .utf8)
            _ = expectSame(stdout(Self.completed("[\(Self.change("sub/inner.txt"))]")), "in a folder", changed: true)
            try? FileManager.default.removeItem(atPath: dir + "/gone.txt")
            _ = expectSame(stdout(Self.completed("[\(Self.change("gone.txt", kind: "delete"))]")), "deleted", changed: true)
            _ = expectSame(stdout(Self.completed("[\(Self.change("missing.txt"))]")), "missing", changed: true)
            try "a\nB\nc\nd\n".write(toFile: dir + "/new.txt", atomically: true, encoding: .utf8)
            _ = expectSame(stdout(Self.completed(#"[\#(Self.change("new.txt")),{"path":"app.txt","diff":"kept"},null,5,{"path":7},{"kind":"add"},\#(Self.change("new.txt")),{"path":"sub/inner.txt","diff":null}]"#)),
                           "mixed", changed: true)

            // Lines left as they are.
            _ = expectSame(stdout(Self.completed(#"[{"path":"app.txt","diff":"kept"}]"#)), "already diffed", changed: false)
            _ = expectSame(stdout(Self.completed(#"[null,5,{"kind":"add"}]"#)), "no paths", changed: false)
            _ = expectSame(stdout(Self.completed("[]")), "no changes", changed: false)
            _ = expectSame(stdout(Self.completed(#""x""#)), "changes not a list", changed: false)
            _ = expectSame(stdout(Self.completed("[\(Self.change("app.txt"))]", event: "item.started")), "started", changed: false)
            _ = expectSame(stdout(Self.completed("[\(Self.change("app.txt"))]", type: "command_execution")), "not an edit", changed: false)
            _ = expectSame(OutputLine(stream: .stderr, line: Self.completed("[\(Self.change("app.txt"))]")), "stderr", changed: false)
            _ = expectSame(stdout(#"{"type":"item.completed","item":{"id":"m","type":"agent_message","text":"hi"}}"#), "message", changed: false)
            _ = expectSame(stdout(#"{"type":"item.completed","item":{"id":"m","type":"agent_message","text":"file_change"}}"#), "mention", changed: false)
            _ = expectSame(stdout(#"{"type":"item.completed","item":{"type":"file_change","changes":[{"path":"a"}"#), "broken", changed: false)
            _ = expectSame(stdout(#"{"type":"item.completed","item":"file_change"}"#), "flat item", changed: false)

            // Foundation's own reading of the JSON.
            try "z\n".write(toFile: dir + "/app.txt", atomically: true, encoding: .utf8)
            _ = expectSame(stdout(#"{"type":"item.completed","item":{"type":"file_change","changes":[{"path":"app.txt"},],},"type":"ignored"}"#),
                           "trailing commas and a repeated key", changed: true)
            _ = expectSame(stdout("\u{feff}" + Self.completed("[\(Self.change("app.txt"))]")), "byte-order mark", changed: true)
            _ = expectSame(stdout(Self.completed(#"[{"path":"app.txt","n":1e400}]"#)), "out of range", changed: false)
            _ = expectSame(stdout(Self.completed(#"[{"path":"app.txt","s":"\udc00"}]"#)), "lone surrogate", changed: false)
            _ = expectSame(stdout(Self.completed(#"[{"path":"app.txt","u":"\u00e9 \/ \ud83d\ude00","big":123456789012345678901234567890,"tiny":1e-320,"neg":-0}]"#)),
                           "escapes and numbers", changed: true)
        }
    }
}

/// The real executor with another home directory.
private struct ParityHomeExecutor: Executor {
    let homeDirectory: String
    let base = LocalExecutor.shared
    func run(_ command: String, _ args: [String], cwd: String?, stdin: Data?) async throws -> ExecResult { try await base.run(command, args, cwd: cwd, stdin: stdin) }
    func spawn(_ spec: LaunchSpec, onLine: @escaping @Sendable (OutputLine) -> Void,
               onExit: @escaping @Sendable (Int32?) -> Void) throws -> RunningProcess {
        try base.spawn(spec, onLine: onLine, onExit: onExit)
    }
    func fileExists(_ path: String) -> Bool { base.fileExists(path) }
    func readFile(_ path: String) throws -> String { try base.readFile(path) }
    func createDirectory(_ path: String) throws { try base.createDirectory(path) }
    func removeItem(_ path: String) throws { try base.removeItem(path) }
    func which(_ binary: String) async -> String? { await base.which(binary) }
}
