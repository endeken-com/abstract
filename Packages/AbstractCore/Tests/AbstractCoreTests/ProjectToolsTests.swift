import Foundation
import Testing
@testable import AbstractCore

/// A project's MCP servers (ABS-123): how each agent is given them for one
/// chat, which tools it gets, Ask first in Claude, and that no other
/// project's chats see them.
@Suite struct ProjectToolsTests {
    static let created = Date(timeIntervalSince1970: 1_790_000_000)

    /// Linear over HTTP with a key: listing reads, creating asks, deleting is off.
    static func linear(project: String = "p1", agents: [String] = ["claude", "codex", "opencode", "muse"]) -> ProjectToolServer {
        ProjectToolServer(
            id: "linear-\(project)", projectId: project, name: "linear",
            connection: .url("https://mcp.linear.app/mcp", headers: ["Authorization": "Bearer lin_test"]),
            agents: agents, notes: "File bugs in team ABS.",
            tools: [.init(name: "list_issues", readOnly: true), .init(name: "create_issue"), .init(name: "delete_issue")],
            access: ["delete_issue": .off], createdAt: created)
    }

    static func launch(_ server: ProjectToolServer, _ provider: any ProviderDefinition) throws -> MCPServerLaunch {
        try #require(server.launch(for: provider))
    }

    static func context(_ servers: [MCPServerLaunch], policy: PermissionPolicy = .ask, directory: String? = nil) -> LaunchContext {
        LaunchContext(cwd: "/w", prompt: "hi", permissionPolicy: policy, toolServers: servers, configDirectory: directory)
    }

    static func value(after flag: String, in args: [String]) -> String? {
        args.firstIndex(of: flag).map { args[$0 + 1] }
    }

    // MARK: - Tool filtering

    @Test func aToolThatOnlyReadsIsAllowedAndTheRestAskFirst() throws {
        let server = Self.linear()
        #expect(server.access(server.tools[0]) == .allowed)
        #expect(server.access(server.tools[1]) == .askFirst)
        #expect(server.access(server.tools[2]) == .off)
        let launch = try Self.launch(server, ClaudeProvider())
        #expect(launch.allowed == ["list_issues"])
        #expect(launch.askFirst == ["create_issue"])
        #expect(launch.off == ["delete_issue"])
        #expect(launch.withheld == ["delete_issue", "create_issue"])
    }

    @Test func anOddToolNameStaysOneRuleForThatTool() throws {
        let listed = MCPToolList.tools(in: .object(["tools": .array([
            .object(["name": .string("list_issues")]), .object(["name": .string("x,Bash")]),
        ])]))
        #expect(listed.tools.map(\.name) == ["list_issues", "x,Bash"])
        var server = Self.linear()
        server.tools.append(.init(name: "y,Bash", readOnly: true))
        server.tools.append(.init(name: "z,Read"))
        server.access["z,Read"] = .off
        let args = ClaudeProvider().buildLaunch(Self.context([try Self.launch(server, ClaudeProvider())])).args
        let allowed = try #require(Self.value(after: "--allowedTools", in: args)).split(separator: ",")
        #expect(allowed == ["mcp__linear__list_issues", "mcp__linear__y_Bash"])
        let off = try #require(Self.value(after: "--disallowedTools", in: args)).split(separator: ",")
        #expect(off == ["mcp__linear__delete_issue", "mcp__linear__z_Read"])
    }

    @Test func onlyTheChosenAgentsThatCanTakeItGetTheServer() {
        let server = Self.linear(agents: ["claude", "muse"])
        #expect(server.launch(for: ClaudeProvider()) != nil)
        #expect(server.launch(for: CodexProvider()) == nil)
        // Muse can't keep a tool out, so it gets none, even when chosen.
        #expect(server.launch(for: MuseProvider()) == nil)
        #expect(MuseProvider().toolServerSupport == .none)
        #expect(ClaudeProvider().toolServerSupport == .askFirst)
        #expect(CodexProvider().toolServerSupport == .allowOrOff)
        #expect(OpenCodeProvider().toolServerSupport == .allowOrOff)
    }

    // MARK: - Per-agent config rendering

    @Test func claudeGetsOneConfigFileOnlyTheUserCanRead() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tools-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let history = HistoryToolLaunch(command: "/bin/abstract", chatId: "chat-1")
        var ctx = Self.context([try Self.launch(Self.linear(), ClaudeProvider())], directory: directory)
        ctx.historyTool = history
        let args = ClaudeProvider().buildLaunch(ctx).args
        let path = try #require(Self.value(after: "--mcp-config", in: args))
        #expect(path == directory + "/claude-mcp.json")
        // The key stays out of argv.
        #expect(!args.contains { $0.contains("lin_test") })
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        let config = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        #expect(config["mcpServers"]?["linear"]?["type"]?.string == "http")
        #expect(config["mcpServers"]?["linear"]?["url"]?.string == "https://mcp.linear.app/mcp")
        #expect(config["mcpServers"]?["linear"]?["headers"]?["Authorization"]?.string == "Bearer lin_test")
        // The code-history server shares the file.
        #expect(config["mcpServers"]?[CodeHistory.serverName]?["args"]?.array?.count == 3)
        let allowed = try #require(Self.value(after: "--allowedTools", in: args)).split(separator: ",").map(String.init)
        #expect(allowed.contains("mcp__linear__list_issues"))
        #expect(allowed.contains(CodeHistory.streamName(CodeHistory.historyTool)))
        #expect(!allowed.contains("mcp__linear__create_issue"))
        #expect(Self.value(after: "--disallowedTools", in: args) == "mcp__linear__delete_issue")
        let prompt = try #require(Self.value(after: "--append-system-prompt", in: args))
        #expect(prompt.contains("File bugs in team ABS."))
    }

    @Test func claudeGetsAStdioServerWithItsEnvironment() throws {
        let server = ProjectToolServer(projectId: "p1", name: "sentry",
                                       connection: .command(["npx", "-y", "@sentry/mcp-server"], env: ["SENTRY_TOKEN": "t"]),
                                       tools: [.init(name: "find_errors", readOnly: true)])
        let args = ClaudeProvider().buildLaunch(Self.context([try Self.launch(server, ClaudeProvider())])).args
        let config = try JSONDecoder().decode(JSONValue.self, from: Data(try #require(Self.value(after: "--mcp-config", in: args)).utf8))
        let entry = config["mcpServers"]?["sentry"]
        #expect(entry?["command"]?.string == "npx")
        #expect(entry?["args"]?.array?.compactMap(\.string) == ["-y", "@sentry/mcp-server"])
        #expect(entry?["env"]?["SENTRY_TOKEN"]?.string == "t")
    }

    @Test func codexGetsConfigOverridesWithSecretsInItsEnvironment() throws {
        let linear = try Self.launch(Self.linear(), CodexProvider())
        let sentry = try Self.launch(ProjectToolServer(projectId: "p1", name: "sentry",
                                                       connection: .command(["sentry-mcp", "--stdio"], env: ["SENTRY_TOKEN": "t"])),
                                     CodexProvider())
        for spec in [CodexProvider().buildLaunch(Self.context([linear, sentry])),
                     CodexProvider().buildResume(Self.context([linear, sentry]), resumeId: "thread")] {
            let args = spec.args
            #expect(args.contains(#"mcp_servers.linear.url="https://mcp.linear.app/mcp""#))
            #expect(args.contains(#"mcp_servers.linear.env_http_headers={ "Authorization" = "ABSTRACT_MCP_LINEAR_AUTHORIZATION" }"#))
            #expect(args.contains(#"mcp_servers.linear.tools={ "list_issues" = { approval_mode = "approve" } }"#))
            // `exec` can't ask, so Ask first is left out with Off.
            #expect(args.contains(#"mcp_servers.linear.disabled_tools=["delete_issue", "create_issue"]"#))
            #expect(args.contains(#"mcp_servers.sentry.command="sentry-mcp""#))
            #expect(args.contains(#"mcp_servers.sentry.args=["--stdio"]"#))
            #expect(args.contains(#"mcp_servers.sentry.env_vars=["SENTRY_TOKEN"]"#))
            #expect(!args.contains { $0.contains("lin_test") || $0.contains("SENTRY_TOKEN=") })
            #expect(spec.env["ABSTRACT_MCP_LINEAR_AUTHORIZATION"] == "Bearer lin_test")
            #expect(spec.env["SENTRY_TOKEN"] == "t")
            #expect(args.contains { $0.hasPrefix("developer_instructions=") && $0.contains("File bugs in team ABS.") })
        }
    }

    @Test func openCodeGetsTheServersInItsConfigEnvironment() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tools-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let linear = try Self.launch(Self.linear(), OpenCodeProvider())
        let local = try Self.launch(ProjectToolServer(projectId: "p1", name: "db", connection: .command(["db-mcp"], env: ["DB_URL": "x"]),
                                                      tools: [.init(name: "run.query")], access: ["run.query": .off]),
                                    OpenCodeProvider())
        let spec = OpenCodeProvider().buildLaunch(Self.context([linear, local], directory: directory))
        let config = try JSONDecoder().decode(JSONValue.self, from: Data(try #require(spec.env["OPENCODE_CONFIG_CONTENT"]).utf8))
        #expect(config["mcp"]?["linear"]?["type"]?.string == "remote")
        #expect(config["mcp"]?["linear"]?["headers"]?["Authorization"]?.string == "Bearer lin_test")
        #expect(config["mcp"]?["db"]?["type"]?.string == "local")
        #expect(config["mcp"]?["db"]?["command"]?.array?.compactMap(\.string) == ["db-mcp"])
        #expect(config["mcp"]?["db"]?["environment"]?["DB_URL"]?.string == "x")
        #expect(config["tools"]?["linear_delete_issue"]?.bool == false)
        #expect(config["tools"]?["linear_create_issue"]?.bool == false)
        #expect(config["tools"]?["linear_list_issues"] == nil)
        #expect(config["tools"]?["db_run_query"]?.bool == false)
        // The notes ride in an instructions file, not the prompt.
        let notes = try #require(config["instructions"]?.array?.first?.string)
        #expect(try String(contentsOfFile: notes, encoding: .utf8).contains("File bugs in team ABS."))
        #expect(!(spec.args.last ?? "").contains("File bugs"))
        #expect(!spec.args.contains { $0.contains("lin_test") })
    }

    @Test func museIsGivenNothing() {
        let settings = LaunchSettings(providerOverrides: [:], outputStyle: .default, claudeProfile: nil,
                                      attachmentsDirectory: "/a", toolServers: [Self.linear()])
        let session = Session(projectId: "p1", name: "Chat", providerId: "muse", worktreePath: "/w")
        #expect(settings.toolServers(for: session, provider: MuseProvider()).isEmpty)
    }

    // MARK: - Ask first in Claude

    @Test func askFirstGivesClaudeAnAskRuleInEveryMode() throws {
        let launch = try Self.launch(Self.linear(), ClaudeProvider())
        for policy in PermissionPolicy.autonomyCases {
            var ctx = Self.context([launch], policy: policy)
            ctx.outputStyle = .concise
            let args = ClaudeProvider().buildLaunch(ctx).args
            // Claude's ask rules ask even under full autonomy, through the
            // permission prompt tool every mode keeps.
            #expect(args.contains("--permission-prompt-tool"))
            let settings = try JSONDecoder().decode(JSONValue.self, from: Data(try #require(Self.value(after: "--settings", in: args)).utf8))
            #expect(settings["permissions"]?["ask"]?.array?.compactMap(\.string) == ["mcp__linear__create_issue"])
            #expect(settings["outputStyle"]?.string == "Concise")
            #expect(args.filter { $0 == "--settings" }.count == 1)
        }
    }

    @Test func anAskFirstCallReachesTheChatAsAPermissionRequest() {
        // As claude 2.1.283 sends it for a tool under an ask rule.
        let parser = ClaudeProvider().makeParser()
        let events = parser.feed(#"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"mcp__linear__create_issue","mcp_server":{"name":"linear","source":"dynamic"},"display_name":"Create Issue","input":{"title":"x"},"decision_reason_type":"rule","tool_use_id":"toolu_1"}}"#, stream: .stdout)
        #expect(events.contains(.permissionRequest(requestId: "r1", toolName: "mcp__linear__create_issue",
                                                   input: .object(["title": .string("x")]))))
    }

    // MARK: - Project isolation

    @Test func aChatGetsOnlyItsOwnProjectsServers() throws {
        var other = Self.linear(project: "p2")
        other.name = "sentry"
        let settings = LaunchSettings(providerOverrides: [:], outputStyle: .default, claudeProfile: nil,
                                      attachmentsDirectory: "/a", toolServers: [Self.linear(), other])
        let mine = Session(projectId: "p1", name: "Chat", providerId: "claude", worktreePath: "/w")
        #expect(settings.toolServers(for: mine, provider: ClaudeProvider()).map(\.name) == ["linear"])
        let theirs = Session(projectId: "p2", name: "Chat", providerId: "claude", worktreePath: "/w")
        #expect(settings.toolServers(for: theirs, provider: ClaudeProvider()).map(\.name) == ["sentry"])
        let standalone = Session(projectId: nil, name: "Chat", providerId: "claude", worktreePath: "/w")
        #expect(settings.toolServers(for: standalone, provider: ClaudeProvider()).isEmpty)
        let spec = AgentLaunch.spec(for: standalone, provider: ClaudeProvider(), prompt: "hi", resumeId: nil,
                                    settings: settings, home: "/h")
        #expect(!spec.args.contains("--mcp-config"))
        let own = AgentLaunch.spec(for: mine, provider: ClaudeProvider(), prompt: "hi", resumeId: nil,
                                   settings: settings, home: "/h")
        let config = try #require(Self.value(after: "--mcp-config", in: own.args))
        #expect(config.contains("mcp.linear.app") && !config.contains("sentry"))
    }

    @Test func aServerCantTakeAbstractsOwnNameOrAnEarlierOnes() {
        var shadow = Self.linear()
        shadow.id = "shadow"; shadow.name = CodeHistory.serverName
        var twin = Self.linear()
        twin.id = "twin"
        let settings = LaunchSettings(providerOverrides: [:], outputStyle: .default, claudeProfile: nil,
                                      attachmentsDirectory: "/a", toolServers: [shadow, Self.linear(), twin])
        let session = Session(projectId: "p1", name: "Chat", providerId: "claude", worktreePath: "/w")
        #expect(settings.toolServers(for: session, provider: ClaudeProvider()).map(\.name) == ["linear"])
    }

    // MARK: - Store

    @Test func serversRoundTripAndGoWithTheirProject() throws {
        let store = try Store.inMemory()
        try store.save(Project(id: "p1", name: "api", rootPath: "/r/api"))
        try store.save(Project(id: "p2", name: "web", rootPath: "/r/web"))
        var server = Self.linear()
        server.listedAt = Self.created
        try store.save(server)
        try store.save(Self.linear(project: "p2"))
        #expect(try store.toolServers(projectId: "p1") == [server])
        server.access["create_issue"] = .allowed
        server.listError = "The server didn't answer within 20 seconds."
        try store.save(server)
        #expect(try store.toolServers(projectId: "p1") == [server])
        try store.deleteProject("p1")
        #expect(try store.toolServers(projectId: "p1").isEmpty)
        #expect(try store.toolServers(projectId: "p2").count == 1)
        try store.deleteToolServer("linear-p2")
        #expect(try store.toolServers(projectId: "p2").isEmpty)
    }

    // MARK: - Listing tools

    @Test func listsAStdioServersToolsPageByPage() async throws {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("fake-mcp-\(UUID().uuidString).sh").path
        defer { try? FileManager.default.removeItem(atPath: script) }
        try #"""
        #!/bin/sh
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
          case "$line" in
            *'"initialize"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"fake","version":"1"}}}\n' "$id" ;;
            *'"cursor"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"create_issue","description":"Create an issue","inputSchema":{"type":"object"}}]}}\n' "$id" ;;
            *'"tools/list"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"list_issues","inputSchema":{"type":"object"},"annotations":{"readOnlyHint":true}}],"nextCursor":"2"}}\n' "$id" ;;
          esac
        done
        """#.write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        let tools = try await MCPToolList.list(.command([script], env: [:]))
        #expect(tools == [.init(name: "list_issues", readOnly: true), .init(name: "create_issue", detail: "Create an issue")])
    }

    @Test func aCommandThatEndsSaysWhatItPrinted() async {
        await #expect(throws: MCPToolList.Failure.server("no key set")) {
            try await MCPToolList.list(.command(["/bin/sh", "-c", "echo 'no key set' >&2"], env: [:]))
        }
    }

    @Test func readsAnswersSentAsEvents() throws {
        let body = "event: message\r\ndata: {\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[{\"name\":\"a\"}]}}\r\n\r\n"
        let messages = MCPToolList.messages(inBody: body, eventStream: true)
        let message = try #require(messages.first)
        let result = try #require(try MCPToolList.result(of: message, id: 2))
        #expect(MCPToolList.tools(in: result).tools.map(\.name) == ["a"])
        #expect(throws: MCPToolList.Failure.server("Unauthorized")) {
            try MCPToolList.result(of: .object(["id": .number(3), "error": .object(["message": .string("Unauthorized")])]), id: 3)
        }
    }

    // MARK: - What was pasted

    @Test func aPastedCommandSplitsLikeAShell() {
        #expect(ShellWords.split(#"npx -y "@scope/mcp server" --flag='a b' x\ y"#) == ["npx", "-y", "@scope/mcp server", "--flag=a b", "x y"])
        #expect(ShellWords.join(["npx", "@scope/mcp server", "it's"]) == #"npx '@scope/mcp server' 'it'\''s'"#)
        #expect(ShellWords.pairs("A=1\n\nB = two=2\nnot a pair", separator: "=") == ["A": "1", "B": "two=2"])
        #expect(ShellWords.pairs("Authorization: Bearer x", separator: ":") == ["Authorization": "Bearer x"])
    }

    @Test func aNameIsSuggestedFromWhatWasPasted() {
        #expect(ProjectToolServer.suggestedName(for: .url("https://mcp.linear.app/mcp", headers: [:])) == "linear")
        #expect(ProjectToolServer.suggestedName(for: .url("https://mcp.sentry.dev/mcp", headers: [:])) == "sentry")
        #expect(ProjectToolServer.suggestedName(for: .command(["npx", "-y", "@modelcontextprotocol/server-postgres"], env: [:])) == "postgres")
        #expect(ProjectToolServer.suggestedName(for: .command(["npx", "-y", "@sentry/mcp-server@latest"], env: [:])) == "sentry")
        #expect(ProjectToolServer.suggestedName(for: .command(["/usr/local/bin/github-mcp-server", "stdio"], env: [:])) == "github")
        #expect(ProjectToolServer.cleanName("My Server.v2") == "my-server-v2")
        #expect(ProjectToolServer(projectId: "p", name: "n", connection: .url("u", headers: [:]),
                                  notes: String(repeating: "x", count: 3_000)).notes.count == ProjectToolServer.notesLimit)
    }
}
