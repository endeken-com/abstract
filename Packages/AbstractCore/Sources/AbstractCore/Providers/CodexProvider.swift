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

    public init() {}

    /// `exec resume` has no `-s`, so a follow-up sets the sandbox as config.
    private static func sandboxArgs(_ policy: PermissionPolicy, resuming: Bool) -> [String] {
        let mode = switch policy {
        case .ask, .autoEdits: "workspace-write"
        case .bypass: "danger-full-access"
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
                + (ctx.outputStyle.instructions.map { ["-c", "developer_instructions=\(Self.tomlString($0))"] } ?? []) + ctx.extraArgs
                + ctx.images.flatMap { ["--image", $0] }
                // A prompt like "- fix the parser" would otherwise parse as a flag,
                // and `--image` takes every value up to the next flag.
                + (ctx.prompt.hasPrefix("-") || !ctx.images.isEmpty ? ["--", ctx.prompt] : [ctx.prompt]),
            cwd: ctx.cwd,
            stdinInitial: nil,
            // `codex exec` waits on an open stdin forever.
            keepStdinOpen: false
        )
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
        case "turn.failed", "error":
            let message = obj["error"]?["message"]?.string
                ?? obj["message"]?.string
                ?? obj["error"]?.string
                ?? "Codex reported an error"
            return [.error(message), .status(.errored, detail: nil)]
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
        case "file_change", "patch_apply":
            return onFileChange(item, id: id, itemType: itemType, phase: phase)
        // NOTE: unverified: these item types do not appear in the recorded fixture.
        case "todo_list", "web_search", "mcp_tool_call":
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
