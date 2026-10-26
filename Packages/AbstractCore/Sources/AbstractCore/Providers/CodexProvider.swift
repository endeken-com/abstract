import Foundation

/// Codex CLI.
///
/// Wire format: `codex exec --json`. Every stdout line is one JSON object.
/// Verified shapes come from `Tests/AbstractCoreTests/Fixtures/codex-stream.jsonl`
/// (codex-cli 0.153.4), which only exercises `thread.started`, `turn.started`,
/// `agent_message`, `command_execution` and `turn.completed`. Every other branch
/// is best-effort and marked `NOTE: unverified`.
///
/// `codex exec` runs one turn and exits; follow-ups respawn with `exec resume`.
public struct CodexProvider: ProviderDefinition {
    public var id: String { "codex" }
    public var name: String { "Codex" }
    public var logoAsset: String { "ProviderOpenAI" }
    public var binary: String { "codex" }
    public var detectArgs: [String] { ["--version"] }
    public var followUpMode: FollowUpMode { .respawn }
    /// `exec` can't compact (it sends `/compact` to the model); its app server can.
    public var commands: ProviderCommands { ProviderCommands(extra: [.compact]) }
    public var compaction: Compaction? { .sideChannel(CodexCompactor()) }

    public init() {}

    /// `exec resume` has no `-s`, so a follow-up sets the sandbox as config.
    private static func sandboxArgs(_ policy: PermissionPolicy, resuming: Bool) -> [String] {
        let mode = switch policy {
        case .ask, .autoEdits: "workspace-write"
        case .bypass: "danger-full-access"
        case .plan, .readOnly: "read-only"
        }
        return resuming ? ["-c", "sandbox_mode=\"\(mode)\""] : ["-s", mode]
    }

    // Models: see CodexModels.swift.

    /// Top-level `model = "…"` in ~/.codex/config.toml.
    public func configuredDefaultModel(home: String) -> String? {
        Self.topLevelConfigValue("model", home: home)
    }

    /// Top-level `model_reasoning_effort = "…"` in ~/.codex/config.toml.
    public func configuredDefaultEffort(home: String) -> String? {
        Self.topLevelConfigValue("model_reasoning_effort", home: home)
    }

    /// A top-level string key of ~/.codex/config.toml, i.e. one before the first `[table]`.
    private static func topLevelConfigValue(_ key: String, home: String) -> String? {
        guard let text = try? String(contentsOfFile: home + "/.codex/config.toml", encoding: .utf8) else { return nil }
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { break }
            guard line.hasPrefix(key), let eq = line.firstIndex(of: "=") else { continue }
            guard line[..<eq].trimmingCharacters(in: .whitespaces) == key else { continue }
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            return value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }

    /// The chat's model at low effort, in a read-only sandbox.
    public func namingLaunch(prompt: String, home: String, binary: String?, model: String?) -> LaunchSpec? {
        LaunchSpec(command: binary ?? self.binary,
                   args: ["exec", "--json", "-C", home, "--skip-git-repo-check", "-s", "read-only",
                          "-c", "model_reasoning_effort=\"low\""] + (model.map { ["-m", $0] } ?? []) + ["--", prompt],
                   cwd: home, keepStdinOpen: false)
    }

    /// Every agent message, in order: earlier ones may be commentary, and
    /// the answer comes last.
    public func namingAnswer(_ output: String) -> String? {
        let messages = output.split(separator: "\n").compactMap { line -> String? in
            guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  event["type"] as? String == "item.completed",
                  let item = event["item"] as? [String: Any], item["type"] as? String == "agent_message" else { return nil }
            return item["text"] as? String
        }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    /// The last error event's message; the API's own, when it wraps one as JSON.
    public func namingError(_ output: String) -> String? {
        var message: String?
        for line in output.split(separator: "\n") {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            switch event["type"] as? String {
            case "error": message = event["message"] as? String ?? message
            case "turn.failed": message = (event["error"] as? [String: Any])?["message"] as? String ?? message
            default: continue
            }
        }
        guard let message else { return nil }
        let inner = (try? JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any])?["error"] as? [String: Any]
        return inner?["message"] as? String ?? message
    }

    public func buildLaunch(_ ctx: LaunchContext) -> LaunchSpec {
        launchSpec(ctx, head: ["exec"], resuming: false)
    }

    public func buildResume(_ ctx: LaunchContext, resumeId: String) -> LaunchSpec {
        launchSpec(ctx, head: ["exec", "resume", resumeId], resuming: true)
    }

    private func launchSpec(_ ctx: LaunchContext, head: [String], resuming: Bool) -> LaunchSpec {
        let override = ctx.binaryOverride?.trimmingCharacters(in: .whitespaces)
        return LaunchSpec(
            command: override.flatMap { $0.isEmpty ? nil : $0 } ?? binary,
            // `exec resume` has no `-C` either; the process cwd stands in for it.
            args: head + ["--json"] + (resuming ? [] : ["-C", ctx.cwd]) + ["--skip-git-repo-check"]
                + Self.sandboxArgs(ctx.permissionPolicy, resuming: resuming) + (ctx.model.map { ["-m", $0] } ?? [])
                // A config override; the value is TOML, so the level is quoted.
                + (ctx.effort.map { ["-c", "model_reasoning_effort=\"\($0)\""] } ?? [])
                + Self.developerInstructions(ctx) + Self.historyArgs(ctx.historyTool) + Self.pluginArgs(ctx.pluginTools)
                + Self.branchArgs(ctx.branchTool)
                + Self.toolServerArgs(ctx.toolServers).args + ctx.extraArgs
                + ctx.images.flatMap { ["--image", $0] }
                // A prompt like "- fix the parser" would otherwise parse as a flag,
                // and `--image` takes every value up to the next flag.
                + (ctx.prompt.hasPrefix("-") || !ctx.images.isEmpty ? ["--", ctx.prompt] : [ctx.prompt]),
            cwd: ctx.cwd,
            env: Self.toolServerArgs(ctx.toolServers).env.merging(Self.skillEnv(ctx.skills)) { $1 },
            stdinInitial: nil,
            // `codex exec` waits on an open stdin forever.
            keepStdinOpen: false
        )
    }

    /// Library skills (ABS-122): Codex reads skills only from its home,
    /// so the chat's agent gets a stand-in for `~/.codex` whose `skills`
    /// adds them to the user's own, and whose every other entry is the
    /// real one (sign-in, settings, sessions to resume).
    static func skillEnv(_ skills: SkillsLaunch?) -> [String: String] {
        skills.map { ["CODEX_HOME": $0.folder] } ?? [:]
    }

    public var skillDelivery: SkillDelivery? { .codexHome }

    /// The profile's instructions (ABS-101), the output style and, when
    /// the chat gets it, the code-history instruction, joined as
    /// developer instructions.
    static func developerInstructions(_ ctx: LaunchContext) -> [String] {
        // Plan mode is read-only above; this is what makes the turn a plan.
        let mode = switch ctx.permissionPolicy {
        case .plan: Plan.instruction
        case .readOnly: Plan.readOnlyInstruction
        default: nil as String?
        }
        let parts = [ctx.instructions, ctx.outputStyle.instructions, mode, ctx.historyTool == nil ? nil : CodeHistory.instruction,
                     MCPServerLaunch.instructions(ctx.toolServers)]
            .compactMap { $0 }
        return parts.isEmpty ? [] : ["-c", "developer_instructions=\(tomlString(parts.joined(separator: "\n\n")))"]
    }

    /// The code-history tool (ABS-61, checked in ABS-60) as config
    /// overrides, on `exec` and `exec resume` alike; the user's own
    /// config file is never touched. The tool must declare itself
    /// read-only, or `exec` (approval policy "never") refuses the call.
    static func historyArgs(_ tool: HistoryToolLaunch?) -> [String] {
        guard let tool else { return [] }
        let server = "mcp_servers.\(CodeHistory.serverName)"
        let args = "[" + tool.serverArgs.map(tomlString).joined(separator: ", ") + "]"
        return ["-c", "\(server).command=\(tomlString(tool.command))", "-c", "\(server).args=\(args)"]
    }

    /// `exec` can't stop and ask Abstract, so a tool set to Ask first is
    /// left out like an Off one.
    public var toolServerSupport: ToolServerSupport { .allowOrOff }

    /// The project's MCP servers (ABS-123) as config overrides beside the
    /// code-history one, on `exec` and `exec resume` alike. Allowed tools
    /// are approved outright (`exec` never asks, so it would refuse one
    /// that doesn't say it only reads); Off and Ask first ones are disabled.
    /// Header and environment values travel in the environment, named
    /// here, never in argv (checked against codex-cli 0.156.1's config).
    static func toolServerArgs(_ servers: [MCPServerLaunch]) -> (args: [String], env: [String: String]) {
        var args: [String] = []
        var env: [String: String] = [:]
        for server in servers {
            let key = "mcp_servers.\(server.name)"
            switch server.connection {
            case let .url(url, headers):
                args += ["-c", "\(key).url=\(tomlString(url))"]
                if !headers.isEmpty {
                    let names = headers.keys.sorted().map { header -> String in
                        env[server.secretVariable(header)] = headers[header]
                        return "\(tomlString(header)) = \(tomlString(server.secretVariable(header)))"
                    }
                    args += ["-c", "\(key).env_http_headers={ \(names.joined(separator: ", ")) }"]
                }
            case let .command(argv, vars):
                args += ["-c", "\(key).command=\(tomlString(argv.first ?? ""))",
                         "-c", "\(key).args=\(tomlArray(Array(argv.dropFirst())))"]
                if !vars.isEmpty {
                    for (name, value) in vars { env[name] = value }
                    args += ["-c", "\(key).env_vars=\(tomlArray(vars.keys.sorted()))"]
                }
            }
            if !server.allowed.isEmpty {
                let tools = server.allowed.map { "\(tomlString($0)) = { approval_mode = \"approve\" }" }
                args += ["-c", "\(key).tools={ \(tools.joined(separator: ", ")) }"]
            }
            if !server.withheld.isEmpty { args += ["-c", "\(key).disabled_tools=\(tomlArray(server.withheld))"] }
        }
        return (args, env)
    }

    static func branchArgs(_ branch: BranchToolLaunch?) -> [String] {
        guard let branch else { return [] }
        let key = "mcp_servers.\(BranchMCPServer.serverName)"
        let argv = tomlArray(["mcp", "--chat", branch.chatId, "--branch"])
        return ["-c", "\(key).command=\(tomlString(branch.command))",
                "-c", "\(key).args=\(argv)",
                "-c", "\(key).tools={ \"name_branch\" = { approval_mode = \"approve\" } }"]
    }

    static func tomlArray(_ items: [String]) -> String {
        "[" + items.map(tomlString).joined(separator: ", ") + "]"
    }

    /// The plugin-tools server (ABS-97), the same way. Its tools say
    /// they're read-only so `exec` runs them, and a call may wait for
    /// you to answer Ask first, so Codex waits as long as Abstract does.
    static func pluginArgs(_ tools: PluginToolsLaunch?) -> [String] {
        guard let tools else { return [] }
        let server = "mcp_servers.\(PluginTools.serverName)"
        let args = "[" + tools.serverArgs.map(tomlString).joined(separator: ", ") + "]"
        let wait = Int(PluginTools.askTimeout + PluginTools.timeout + 30)
        return ["-c", "\(server).command=\(tomlString(tools.command))", "-c", "\(server).args=\(args)",
                "-c", "\(server).tool_timeout_sec=\(wait)"]
    }

    /// A TOML basic string; its escapes match JSON's, all but `\/`, which
    /// TOML doesn't have (so slashes stay as they are).
    static func tomlString(_ text: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return (try? encoder.encode(text)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }

    public func makeParser() -> OutputParser { CodexParser() }
    public func makeLineEnricher(executor: any Executor, cwd: String) -> (any LineEnricher)? { CodexEditDiffs(executor: executor, cwd: cwd) }

    public func buildUserMessage(_ text: String) -> String? { nil }

    public func buildPermissionResponse(requestId: String, allow: Bool, input: JSONValue?) -> String? { nil }
}

/// Stateful `codex exec --json` parser. One instance per process.
final class CodexParser: OutputParser {
    private enum Phase { case started, updated, completed }

    private let decoder = JSONDecoder()
    /// Item ids for which a `toolUse` has already been emitted.
    private var openTools: Set<String> = []

    func feed(_ line: String, stream: OutputStreamKind) -> [AgentEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        let raw: [AgentEvent] = [.raw(line: line, stream: stream)]
        guard stream == .stdout,
              let obj = CodexWire.decode(trimmed, decoder), obj.object != nil,
              let events = dispatch(obj)
        else { return raw }
        return events
    }

    func onExit(code: Int32?) -> [AgentEvent] {
        if code == 0 { return [.status(.finished, detail: nil)] }
        return [
            .error("codex exited with code \(code.map { String($0) } ?? "null")"),
            .status(.errored, detail: nil),
        ]
    }

    // MARK: - dispatch (nil = not understood, surfaced as a raw line)

    private func dispatch(_ obj: JSONValue) -> [AgentEvent]? {
        switch obj["type"]?.string {
        case "thread.started":
            return obj["thread_id"]?.string.map { [.sessionId($0)] }
        case "turn.started":
            openTools.removeAll()
            return [.status(.running, detail: nil)]
        case "turn.completed":
            let usage = obj["usage"]
            return [
                .usage(
                    UsageTotals(
                        inputTokens: CodexWire.int(usage?["input_tokens"]) ?? 0,
                        outputTokens: CodexWire.int(usage?["output_tokens"]) ?? 0,
                        cacheRead: CodexWire.int(usage?["cached_input_tokens"]) ?? 0,
                        cacheWrite: CodexWire.int(usage?["cache_write_input_tokens"]) ?? 0
                    ),
                    costUsd: nil, durationMs: nil, turns: nil
                ),
                .status(.finished, detail: nil),
            ]
        // NOTE: unverified: no failing turn appears in the recorded fixture.
        case "turn.failed":
            return [.error(CodexWire.message(obj) ?? "Codex reported an error"), .status(.errored, detail: nil)]
        // Codex carries on after an `error`: when the turn fails over it,
        // `turn.failed` follows with the same message (codex-rs exec's
        // jsonl processor, 0.156).
        case "error":
            return CodexWire.message(obj).map { [.notice(.warning($0))] } ?? []
        case "item.started": return onItem(obj, .started)
        case "item.updated": return onItem(obj, .updated)
        case "item.completed": return onItem(obj, .completed)
        default: return nil
        }
    }

    private func onItem(_ obj: JSONValue, _ phase: Phase) -> [AgentEvent]? {
        guard let item = obj["item"], item.object != nil, let itemType = item["type"]?.string else { return nil }
        let id = item["id"]?.string ?? ""
        switch itemType {
        case "agent_message":
            return [.text(role: .assistant, text: item["text"]?.string ?? "", blockId: id, partial: phase != .completed)]
        // NOTE: unverified: no reasoning item appears in the recorded fixture.
        case "reasoning":
            return [.thinking(text: item["text"]?.string ?? item["summary"]?.string ?? "",
                              blockId: id, partial: phase != .completed)]
        case "command_execution":
            return onCommandExecution(item, id: id, phase: phase)
        // Warnings: a deprecated setting, a model rerouted, anything Codex
        // carries on past (openai/codex#27415). They come completed.
        case "error":
            guard phase == .completed, let message = item["message"]?.string, !message.isEmpty else { return [] }
            return [.notice(.warning(message))]
        case "file_change", "patch_apply":
            return onFileChange(item, id: id, itemType: itemType, phase: phase)
        // Verified against codex-cli 0.156.1 (ABS-60; fixture
        // `codex-mcp.jsonl`): `server`, `tool`, `arguments`, and on
        // completion `result.content[]` or `error.message`, plus `status`.
        case "mcp_tool_call":
            return onMCPTool(item, id: id, phase: phase)
        // NOTE: unverified: these item types do not appear in the recorded fixture.
        case "todo_list", "web_search":
            return onGenericTool(item, id: id, itemType: itemType, phase: phase, edit: nil)
        default:
            return nil
        }
    }

    private func onCommandExecution(_ item: JSONValue, id: String, phase: Phase) -> [AgentEvent] {
        var events: [AgentEvent] = []
        if !openTools.contains(id) {
            openTools.insert(id)
            events.append(.toolUse(id: id, name: "Bash",
                                   input: .object(["command": .string(item["command"]?.string ?? "")]), edit: nil))
        }
        if phase == .completed {
            openTools.remove(id)
            let exitCode = CodexWire.double(item["exit_code"])
            events.append(.toolResult(toolUseId: id, output: item["aggregated_output"]?.string ?? "",
                                      isError: exitCode.map { $0 != 0 } ?? false, edit: nil))
        }
        return events
    }

    /// One call per file, the way Claude's edits read. codex-cli 0.153.4 sends
    /// `changes: [{path, kind}]` (no diff) and batches a patch's files into one
    /// item; each change becomes a call whose `file_path` the chat reads.
    private func onFileChange(_ item: JSONValue, id: String, itemType: String, phase: Phase) -> [AgentEvent] {
        let changes = (item["changes"]?.array ?? []).filter { $0["path"]?.string != nil }
        guard !changes.isEmpty else { return onGenericTool(item, id: id, itemType: itemType, phase: phase, edit: CodexWire.editPreview(item)) }
        var uses: [AgentEvent] = [], results: [AgentEvent] = []
        for (i, change) in changes.enumerated() {
            var call: [String: JSONValue] = ["type": .string(itemType), "file_path": change["path"] ?? .null]
            call["kind"] = change["kind"]
            call["status"] = item["status"]
            for event in onGenericTool(.object(call), id: i == 0 ? id : "\(id)#\(i)", itemType: itemType, phase: phase,
                                       edit: CodexWire.editPreview(change)) {
                if case .toolUse = event { uses.append(event) } else { results.append(event) }
            }
        }
        return uses + results
    }

    /// An MCP call, named the way Claude's stream names it
    /// (`mcp__<server>__<tool>`) so the chat reads the same for every
    /// agent, with the call's own arguments as its input.
    private func onMCPTool(_ item: JSONValue, id: String, phase: Phase) -> [AgentEvent] {
        var events: [AgentEvent] = []
        if !openTools.contains(id) {
            openTools.insert(id)
            let server = item["server"]?.string ?? ""
            let tool = item["tool"]?.string ?? "McpToolCall"
            events.append(.toolUse(id: id, name: server.isEmpty ? tool : "mcp__\(server)__\(tool)",
                                   input: item["arguments"] ?? .object([:]), edit: nil))
        }
        if phase == .completed {
            openTools.remove(id)
            let status = item["status"]?.string
            let error = item["error"]?["message"]?.string ?? item["error"]?.string
            let content = (item["result"]?["content"]?.array ?? [])
                .compactMap { $0["text"]?.string }.joined(separator: "\n")
            events.append(.toolResult(toolUseId: id, output: error ?? (content.isEmpty ? CodexWire.output(item) : content),
                                      isError: error != nil || status == "failed" || status == "error", edit: nil))
        }
        return events
    }

    private func onGenericTool(_ item: JSONValue, id: String, itemType: String, phase: Phase,
                               edit: EditPreview?) -> [AgentEvent] {
        var events: [AgentEvent] = []
        if !openTools.contains(id) {
            openTools.insert(id)
            events.append(.toolUse(id: id, name: CodexWire.toolName(item, itemType), input: item, edit: edit))
        }
        if phase == .completed {
            openTools.remove(id)
            let status = item["status"]?.string
            events.append(.toolResult(toolUseId: id, output: CodexWire.output(item),
                                      isError: status == "failed" || status == "error", edit: edit))
        }
        return events
    }
}

/// Wire helpers private to the Codex provider.
private enum CodexWire {
    static let maxPreviewLines = 200

    /// Decoded with `JSONDecoder` rather than `JSONValue.parse`: the latter goes
    /// through `JSONSerialization`, whose NSNumbers `JSONValue(any:)` reads as
    /// Bool for 0 and 1 (so `"exit_code": 1` would become `true`).
    static func decode(_ text: String, _ decoder: JSONDecoder) -> JSONValue? {
        try? decoder.decode(JSONValue.self, from: Data(text.utf8))
    }

    static func double(_ value: JSONValue?) -> Double? {
        guard let d = value?.double, d.isFinite else { return nil }
        return d
    }

    /// Never traps: out-of-range numbers yield nil instead of crashing `Int(_:)`.
    static func int(_ value: JSONValue?) -> Int? {
        double(value).flatMap { Int(exactly: $0.rounded(.towardZero)) }
    }

    /// An `error` or `turn.failed` line's message, wherever it sits.
    static func message(_ obj: JSONValue) -> String? {
        (obj["error"]?["message"]?.string ?? obj["message"]?.string ?? obj["error"]?.string)
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Display name for a generic (non-command) item type.
    static func toolName(_ item: JSONValue, _ itemType: String) -> String {
        switch itemType {
        case "command_execution": "Bash"
        // A new file reads "Created", as Claude's Write does.
        case "file_change", "patch_apply": item["kind"]?.string == "add" ? "Write" : "ApplyPatch"
        case "todo_list": "TodoList"
        case "web_search": "WebSearch"
        case "mcp_tool_call": item["tool"]?.string ?? item["name"]?.string ?? "McpToolCall"
        default: itemType
        }
    }

    /// Best-effort textual output for a completed generic item.
    static func output(_ item: JSONValue) -> String {
        item["aggregated_output"]?.string ?? item["output"]?.string ?? item["result"]?.string
            ?? item["text"]?.string ?? ""
    }

    /// EditPreview for a `file_change` / `patch_apply` item or one of its
    /// changes. Codex sends no diff; `CodexEditDiffs` writes one in before the
    /// line is logged. A few other plausible field names are accepted too.
    static func editPreview(_ item: JSONValue) -> EditPreview? {
        let first = item["changes"]?.array?.first.flatMap { $0.object == nil ? nil : $0 } ?? item
        let filePath = first["path"]?.string ?? first["file_path"]?.string
            ?? item["path"]?.string ?? item["file_path"]?.string ?? ""
        guard let diff = first["diff"]?.string ?? first["unified_diff"]?.string
            ?? item["diff"]?.string ?? item["unified_diff"]?.string
        else { return nil }

        var lines: [EditPreview.Line] = []
        var additions = 0, deletions = 0
        // Line numbers once a hunk header gives them; the first hunk needs no gap.
        var old: Int?, new: Int?, gap = false
        for piece in diff.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false) {
            let raw = String(Substring(piece))
            if raw.hasPrefix("@@") {
                let (oldStart, _, newStart, _) = Diff.parseHunkHeader(raw)
                old = oldStart; new = newStart; gap = !lines.isEmpty
                continue
            }
            // File headers and "\ No newline at end of file" are noise in a mini-diff.
            if raw.hasPrefix("+++") || raw.hasPrefix("---") || raw.hasPrefix("\\") || raw.isEmpty { continue }
            let rest = String(Substring(piece.dropFirst()))
            var line: EditPreview.Line
            switch piece.first {
            case "+": additions += 1; line = .init(origin: .added, content: rest, newLine: new); new = new.map { $0 + 1 }
            case "-": deletions += 1; line = .init(origin: .removed, content: rest, oldLine: old); old = old.map { $0 + 1 }
            case " ": line = .init(origin: .context, content: rest, oldLine: old, newLine: new); old = old.map { $0 + 1 }; new = new.map { $0 + 1 }
            default: line = .init(origin: .context, content: raw)
            }
            // The counts cover the whole change; the preview stops at its cap.
            guard lines.count < maxPreviewLines else { continue }
            if gap { line.startsHunk = true; gap = false }
            lines.append(line)
        }
        if lines.isEmpty { return nil }
        return EditPreview(filePath: filePath, additions: additions, deletions: deletions, lines: lines)
    }
}
