import Foundation

/// OpenCode's non-interactive CLI. Each `run` is one turn; `--session` resumes
/// the same conversation on the next turn. The JSON stream shape was checked
/// against OpenCode 1.18.18.
public struct OpenCodeProvider: ProviderDefinition {
    public var id: String { "opencode" }
    public var name: String { "OpenCode" }
    public var logoAsset: String { "ProviderOpenCode" }
    public var binary: String { "opencode" }
    public var detectArgs: [String] { ["--version"] }
    public var followUpMode: FollowUpMode { .respawn }

    public init() {}

    public func buildLaunch(_ ctx: LaunchContext) -> LaunchSpec {
        launchSpec(ctx, resumeId: nil)
    }

    public func buildResume(_ ctx: LaunchContext, resumeId: String) -> LaunchSpec {
        launchSpec(ctx, resumeId: resumeId)
    }

    private func launchSpec(_ ctx: LaunchContext, resumeId: String?) -> LaunchSpec {
        let override = ctx.binaryOverride?.trimmingCharacters(in: .whitespaces)
        // `run` has no approval channel. Without --auto, OpenCode applies its
        // configured permission rules, rejecting requests that need a prompt.
        // Only Full autonomy opts into automatically approving those requests.
        let auto = ctx.permissionPolicy == .bypass ? ["--auto"] : []
        // Its built-in plan agent can't edit: Plan asks it for a plan,
        // Ask (read-only) for an answer. That keeps the one `--agent`
        // slot in those modes, so a profile's instructions then ride on
        // the prompt below instead of its agent's prompt (ABS-101).
        let agent = ctx.permissionPolicy.isReadOnly ? ["--agent", "plan"]
            : (ctx.instructions == nil ? [] : ["--agent", Self.profileAgent])
        // Without an instruction file the history instruction rides on
        // the prompt, like the output style; with one it goes in the
        // config's `instructions`, after the user's own.
        let historyInPrompt = ctx.historyTool != nil && ctx.historyTool?.instructionFile == nil
        // The servers' usage notes likewise: a file in the chat's folder
        // when it has one, else the prompt.
        let notesInPrompt = ctx.configDirectory == nil ? MCPServerLaunch.instructions(ctx.toolServers) : nil
        let prompt = (ctx.permissionPolicy.isReadOnly ? (ctx.instructions.map { $0 + "\n\n" } ?? "") : "")
            + (ctx.outputStyle.instructions.map { $0 + "\n\n" } ?? "")
            + (ctx.permissionPolicy == .readOnly ? Plan.readOnlyInstruction + "\n\n" : "")
            + (historyInPrompt ? CodeHistory.instruction + "\n\n" : "")
            + (notesInPrompt.map { $0 + "\n\n" } ?? "") + ctx.prompt
        return LaunchSpec(
            command: override.flatMap { $0.isEmpty ? nil : $0 } ?? binary,
            // OpenCode finds its project from the inherited PWD, not the
            // process's working directory, so the worktree is named outright.
            args: ["run", "--format", "json", "--thinking", "--dir", ctx.cwd] + auto + agent
                + (resumeId.map { ["--session", $0] } ?? [])
                + (ctx.model.map { ["--model", $0] } ?? [])
                + (ctx.effort.map { ["--variant", $0] } ?? [])
                + ctx.images.flatMap { ["--file", $0] }
                + ctx.extraArgs
                + (prompt.hasPrefix("-") ? ["--", prompt] : [prompt]),
            cwd: ctx.cwd,
            env: Self.configEnv(ctx),
            keepStdinOpen: false
        )
    }

    /// The agent a chat with a profile's instructions runs as (ABS-101):
    /// a primary agent whose prompt is those instructions, given through
    /// the environment the way the naming agent is, so the user's own
    /// config stays untouched.
    static let profileAgent = "abstract-profile"

    public var skillDelivery: SkillDelivery? { .skillsPath }

    /// The code-history tool (ABS-61, checked in ABS-60), a profile's
    /// agent and library skills (ABS-122) in `OPENCODE_CONFIG_CONTENT`,
    /// which OpenCode merges with the user's own config: their servers,
    /// instructions, agents and skills stay, ours are added. If the user's rules make the tool `ask`,
    /// `run` declines it and the declined call shows in the chat.
    static func configEnv(_ ctx: LaunchContext) -> [String: String] {
        var config: [String: JSONValue] = [:]
        var instructions: [JSONValue] = []
        if let tool = ctx.historyTool {
            config["mcp"] = .object([
                CodeHistory.serverName: .object([
                    "type": .string("local"),
                    "command": .array(tool.serverCommand.map(JSONValue.string)),
                    "enabled": .bool(true),
                ]),
            ])
            if let file = tool.instructionFile { instructions.append(.string(file)) }
        }
        // Library skills (ABS-122): OpenCode adds the folders in
        // `skills.paths` to the ones it already reads.
        if let skills = ctx.skills {
            config["skills"] = .object(["paths": .array([.string(skills.folder)])])
        }
        // The plugin-tools server (ABS-97), merged the same way.
        if let tools = ctx.pluginTools {
            var servers = config["mcp"]?.object ?? [:]
            servers[PluginTools.serverName] = .object([
                "type": .string("local"),
                "command": .array(tools.serverCommand.map(JSONValue.string)),
                "enabled": .bool(true),
            ])
            config["mcp"] = .object(servers)
        }
        if let branch = ctx.branchTool {
            var servers = config["mcp"]?.object ?? [:]
            servers[BranchMCPServer.serverName] = .object([
                "type": .string("local"),
                "command": .array(branch.serverCommand.map(JSONValue.string)),
                "enabled": .bool(true),
            ])
            config["mcp"] = .object(servers)
        }
        // The project's servers (ABS-123), merged the same way. `run` can't
        // ask, so an Ask first tool is turned off like an Off one.
        if !ctx.toolServers.isEmpty {
            var servers = config["mcp"]?.object ?? [:]
            var tools: [String: JSONValue] = [:]
            for server in ctx.toolServers {
                servers[server.name] = mcpEntry(server.connection)
                for tool in server.withheld { tools[toolKey(server.name, tool)] = .bool(false) }
            }
            config["mcp"] = .object(servers)
            if !tools.isEmpty { config["tools"] = .object(tools) }
            if let notes = MCPServerLaunch.instructions(ctx.toolServers), let directory = ctx.configDirectory,
               let file = ChatConfigFiles.write(notes + "\n", named: "opencode-tool-notes.md", in: directory) {
                instructions.append(.string(file))
            }
        }
        if !instructions.isEmpty { config["instructions"] = .array(instructions) }
        if let instructions = ctx.instructions {
            config["agent"] = .object([profileAgent: .object([
                "mode": .string("primary"),
                "prompt": .string(instructions),
            ])])
        }
        return config.isEmpty ? [:] : ["OPENCODE_CONFIG_CONTENT": JSONValue.object(config).compact()]
    }

    /// Allowed and Off tools are honoured; `run` can't ask Abstract.
    public var toolServerSupport: ToolServerSupport { .allowOrOff }

    /// One server in OpenCode's `mcp` block.
    static func mcpEntry(_ connection: ProjectToolServer.Connection) -> JSONValue {
        switch connection {
        case let .url(url, headers):
            var entry: [String: JSONValue] = ["type": .string("remote"), "url": .string(url), "enabled": .bool(true)]
            if !headers.isEmpty { entry["headers"] = .object(headers.mapValues(JSONValue.string)) }
            return .object(entry)
        case let .command(argv, env):
            var entry: [String: JSONValue] = ["type": .string("local"), "command": .array(argv.map(JSONValue.string)),
                                              "enabled": .bool(true)]
            if !env.isEmpty { entry["environment"] = .object(env.mapValues(JSONValue.string)) }
            return .object(entry)
        }
    }

    /// How OpenCode names an MCP tool: server and tool, each with anything
    /// but letters, digits, `_` and `-` made `_` (checked in OpenCode 1.18.18).
    static func toolKey(_ server: String, _ tool: String) -> String {
        let clean = { (s: String) in String(s.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") ? $0 : "_" }) }
        return clean(server) + "_" + clean(tool)
    }

    /// The code-history tool alone, as `configEnv` writes it.
    static func historyEnv(_ tool: HistoryToolLaunch?) -> [String: String] {
        configEnv(LaunchContext(cwd: "", prompt: "", permissionPolicy: .ask, historyTool: tool))
    }

    /// `run` can't ask Abstract, so a request OpenCode's own rules would ask
    /// about is declined, unless Full autonomy approves it.
    public func permissionDetail(_ policy: PermissionPolicy) -> String {
        switch policy {
        case .bypass: "OpenCode approves anything its own rules don't deny. Only for trusted tasks."
        case .plan: "OpenCode's plan agent explores and writes a plan. Nothing changes until you approve it."
        case .readOnly: "OpenCode's plan agent answers without changing anything."
        default: "OpenCode's own permission rules apply; anything they would ask about is declined."
        }
    }

    public func makeParser() -> OutputParser { OpenCodeParser() }
    public func buildUserMessage(_ text: String) -> String? { nil }
    public func buildPermissionResponse(requestId: String, allow: Bool, input: JSONValue?) -> String? { nil }
    public func configuredDefaultModel(home: String) -> String? {
        guard let data = FileManager.default.contents(atPath: home + "/.config/opencode/opencode.json"),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return json["model"]?.string
    }

    /// `small_model` in its config, the model OpenCode itself names sessions with.
    func configuredSmallModel(home: String) -> String? {
        guard let data = FileManager.default.contents(atPath: home + "/.config/opencode/opencode.json"),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return json["small_model"]?.string
    }

    /// The agent naming runs as: no tools at all, and every permission
    /// denied. The task it names may carry instructions (from an agent's
    /// reply, or a repository), so it must not read, fetch or run anything.
    static let namingAgent = "abstract-naming"
    static let namingConfig = #"{"agent":{"abstract-naming":{"mode":"primary","tools":{"*":false},"permission":{"*":"deny"}}}}"#
    static let namingEnv = ["OPENCODE_CONFIG_CONTENT": namingConfig, "OPENCODE_PERMISSION": #"{"*":"deny"}"#]

    /// Its small model when one is set, else the chat's, as `namingAgent`,
    /// given through the environment so the user's own config stays untouched.
    public func namingLaunch(prompt: String, home: String, binary: String?, model: String?) -> LaunchSpec? {
        let model = configuredSmallModel(home: home) ?? model
        return LaunchSpec(command: binary ?? self.binary,
                          args: ["run", "--format", "json", "--agent", Self.namingAgent, "--dir", home]
                              + (model.map { ["--model", $0] } ?? []) + (prompt.hasPrefix("-") ? ["--", prompt] : [prompt]),
                          cwd: home, env: Self.namingEnv, keepStdinOpen: false)
    }

    /// `run` falls back to its default agent, every tool on, when it doesn't
    /// find the one asked for; an OpenCode that ignores the config above
    /// would do just that. So how it resolves `namingAgent` is read first.
    public func namingCheck(home: String, binary: String?) -> LaunchSpec? {
        LaunchSpec(command: binary ?? self.binary, args: ["debug", "agent", Self.namingAgent], cwd: home,
                   env: Self.namingEnv, keepStdinOpen: false)
    }

    /// Every tool off, and a rule denying everything that only rules about
    /// folders outside the project's follow (OpenCode adds its own there;
    /// with no tools, nothing can use them). The last matching rule wins.
    public func namingCheckPasses(_ output: String) -> Bool {
        guard let object = ChatNaming.firstObject(in: output),
              let agent = try? JSONDecoder().decode(JSONValue.self, from: Data(object.utf8)),
              agent["name"]?.string == Self.namingAgent,
              let tools = agent["tools"]?.object, !tools.isEmpty,
              tools.values.allSatisfy({ $0 == .bool(false) }),
              let rules = agent["permission"]?.array,
              let deny = rules.lastIndex(where: { $0["permission"]?.string == "*" && $0["pattern"]?.string == "*"
                                                     && $0["action"]?.string == "deny" }) else { return false }
        return rules[(deny + 1)...].allSatisfy { $0["permission"]?.string == "external_directory" }
    }

    /// Every text part, in order. An error event means no answer.
    public func namingAnswer(_ output: String) -> String? {
        var texts: [String] = []
        for line in output.split(separator: "\n") {
            guard let event = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else { continue }
            switch event["type"]?.string {
            case "text": if let text = event["part"]?["text"]?.string { texts.append(text) }
            case "error": return nil
            default: continue
            }
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    public func namingError(_ output: String) -> String? {
        output.split(separator: "\n").compactMap { line -> String? in
            guard let event = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
                  event["type"]?.string == "error" else { return nil }
            return event["error"]?["data"]?["message"]?.string ?? event["error"]?["message"]?.string ?? event["message"]?.string
        }.last
    }

    public var fallbackModels: ModelCatalog { .empty }

    public func discoverModels(executor: any Executor, binary: String?) async -> ModelCatalog? {
        let command = binary.flatMap { $0.isEmpty ? nil : $0 } ?? self.binary
        guard let result = try? await executor.run(command, ["models", "--verbose"], cwd: nil), result.ok else { return nil }
        return Self.modelCatalog(from: result.stdout)
    }

    /// `opencode models --verbose` prints an ID line followed by a pretty JSON
    /// object for each model. Variants become the effort choices shown by the UI.
    static func modelCatalog(from output: String) -> ModelCatalog? {
        var models: [ModelOption] = []
        var id: String?
        var jsonLines: [String] = []
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if id == nil {
                let candidate = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if candidate.contains("/"), !candidate.contains(" "), !candidate.hasPrefix("{") { id = candidate }
                continue
            }
            jsonLines.append(line)
            guard let object = try? JSONDecoder().decode(JSONValue.self, from: Data(jsonLines.joined(separator: "\n").utf8)),
                  object.object != nil, let modelId = id else { continue }
            let variants = object["variants"]?.object ?? [:]
            let efforts = variants.compactMap { key, value in
                value["reasoningEffort"]?.string != nil ? key : nil
            }.sorted { (effortOrder($0), $0) < (effortOrder($1), $1) }
            models.append(ModelOption(id: modelId, label: object["name"]?.string ?? modelId,
                                      efforts: efforts))
            id = nil
            jsonLines = []
        }
        return models.isEmpty ? nil : ModelCatalog(models: models)
    }

    private static func effortOrder(_ value: String) -> Int {
        ["none", "minimal", "low", "medium", "high", "xhigh", "max"].firstIndex(of: value) ?? 100
    }
}

/// OpenCode `run --format json` events contain complete parts. Unknown lines
/// remain in the log so a newer CLI can still be inspected after a relaunch.
final class OpenCodeParser: OutputParser {
    private var sessionId: String?
    private var seenTools: Set<String> = []
    private var finishedTools: Set<String> = []

    func feed(_ line: String, stream: OutputStreamKind) -> [AgentEvent] {
        guard stream == .stdout,
              let object = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
              let type = object["type"]?.string else { return [.raw(line: line, stream: stream)] }
        var events: [AgentEvent] = []
        if let id = object["sessionID"]?.string, id != sessionId {
            sessionId = id
            events.append(.sessionId(id))
        }
        let part = object["part"]
        switch type {
        case "step_start":
            events.append(.status(.running, detail: nil))
        case "text":
            if let text = part?["text"]?.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                events.append(.text(role: .assistant, text: text, blockId: part?["id"]?.string, partial: false))
            }
        case "reasoning":
            if let text = part?["text"]?.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                events.append(.thinking(text: text, blockId: part?["id"]?.string, partial: false))
            }
        case "tool_use":
            guard let tool = part?["tool"]?.string, let id = part?["callID"]?.string else {
                return events + [.raw(line: line, stream: stream)]
            }
            let state = part?["state"]
            let input = state?["input"] ?? .object([:])
            let status = state?["status"]?.string
            // OpenCode's edit and write name their fields in camelCase; the
            // shared preview reads both spellings.
            let edit = EditPreview.fromToolInput(name: tool, input: input)
            if seenTools.insert(id).inserted {
                events.append(.toolUse(id: id, name: tool, input: input, edit: edit))
            }
            // The full input may only come with the result, so a completed
            // edit carries its diff there too.
            if let status, status == "completed" || status == "error", finishedTools.insert(id).inserted {
                events.append(.toolResult(toolUseId: id, output: state?["output"]?.string
                                          ?? state?["error"]?.string ?? "", isError: status == "error",
                                          edit: status == "completed" ? edit : nil))
            }
        case "step_finish":
            let tokens = part?["tokens"]
            events.append(.usage(UsageTotals(inputTokens: tokens?["input"]?.int ?? 0,
                                             outputTokens: tokens?["output"]?.int ?? 0,
                                             cacheRead: tokens?["cache"]?["read"]?.int ?? 0,
                                             cacheWrite: tokens?["cache"]?["write"]?.int ?? 0),
                                 costUsd: part?["cost"]?.double, durationMs: nil, turns: nil))
        case "error":
            events.append(.error(object["error"]?["message"]?.string ?? object["message"]?.string ?? "OpenCode reported an error"))
            events.append(.status(.errored, detail: nil))
        default:
            events.append(.raw(line: line, stream: stream))
        }
        return events
    }

    func onExit(code: Int32?) -> [AgentEvent] {
        if code == 0 { return [.status(.finished, detail: nil)] }
        return [.error("opencode exited with code \(code.map(String.init) ?? "null")"), .status(.errored, detail: nil)]
    }
}
