import Foundation

/// Claude Code.
///
/// Wire format: `claude -p --output-format stream-json --input-format stream-json
/// --verbose --include-partial-messages`. Every stdout line is one JSON object.
/// Shapes come from `Tests/BacktickCoreTests/Fixtures/claude-stream.jsonl`
/// (claude CLI 2.1.274). The prompt is never an argv argument: it is written to
/// stdin as a stream-json user turn, and so is every follow-up.
public struct ClaudeProvider: ProviderDefinition {
    public var id: String { "claude" }
    public var name: String { "Claude Code" }
    public var logoAsset: String { "ProviderClaude" }
    public var binary: String { "claude" }
    public var detectArgs: [String] { ["--version"] }
    public var followUpMode: FollowUpMode { .stdin }

    public init() {}

    private static let baseArgs = [
        "-p",
        "--output-format", "stream-json",
        "--input-format", "stream-json",
        "--verbose",
        "--include-partial-messages",
    ]

    private static func policyArgs(_ policy: PermissionPolicy) -> [String] {
        switch policy {
        case .ask: ["--permission-prompts", "host"]
        case .autoEdits: ["--permission-mode", "acceptEdits"]
        case .bypass: ["--permission-mode", "bypassPermissions"]
        }
    }

    public var models: [ModelOption] {
        [ModelOption(id: "fable", label: "Fable"), ModelOption(id: "opus", label: "Opus"),
         ModelOption(id: "sonnet", label: "Sonnet"), ModelOption(id: "haiku", label: "Haiku")]
    }

    /// `model` in ~/.claude/settings.json, e.g. "opus[1m]".
    public func configuredDefaultModel(home: String) -> String? {
        guard let data = FileManager.default.contents(atPath: home + "/.claude/settings.json"),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return json["model"]?.string
    }

    public func buildLaunch(_ ctx: LaunchContext) -> LaunchSpec {
        launchSpec(ctx, resumeArgs: [])
    }

    public func buildResume(_ ctx: LaunchContext, resumeId: String) -> LaunchSpec {
        launchSpec(ctx, resumeArgs: ["--resume", resumeId])
    }

    private func launchSpec(_ ctx: LaunchContext, resumeArgs: [String]) -> LaunchSpec {
        let override = ctx.binaryOverride?.trimmingCharacters(in: .whitespaces)
        return LaunchSpec(
            command: override.flatMap { $0.isEmpty ? nil : $0 } ?? binary,
            args: Self.baseArgs + Self.policyArgs(ctx.permissionPolicy) + (ctx.model.map { ["--model", $0] } ?? [])
                + resumeArgs + ctx.extraArgs,
            cwd: ctx.cwd,
            stdinInitial: Self.userMessageLine(ctx.prompt),
            keepStdinOpen: true
        )
    }

    public func makeParser() -> OutputParser { ClaudeParser() }

    public func buildUserMessage(_ text: String) -> String? { Self.userMessageLine(text) }

    // NOTE: unverified against a live permission prompt: the control_response
    // shape is implemented from the documented protocol, not a recorded fixture.
    public func buildPermissionResponse(requestId: String, allow: Bool, input: JSONValue?) -> String? {
        let response: String
        if allow {
            let updated = input.flatMap { $0 == .null ? nil : $0.compact() }.flatMap { $0.isEmpty ? nil : $0 } ?? "{}"
            response = #"{"behavior":"allow","updatedInput":"# + updated + "}"
        } else {
            response = #"{"behavior":"deny","message":"Denied by user"}"#
        }
        return #"{"type":"control_response","response":{"subtype":"success","request_id":"#
            + ClaudeWire.quoted(requestId) + #","response":"# + response + "}}\n"
    }

    /// One stream-json user turn. Keys are written in a fixed order so the line
    /// is byte-identical to what the CLI's own SDK sends.
    static func userMessageLine(_ text: String) -> String {
        #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"#
            + ClaudeWire.quoted(text) + "}]}}\n"
    }
}

/// Stateful stream-json parser. One instance per process.
///
/// Block ids are `messageId:index`, where index is the content block's index in
/// the streamed message, so the final text from an `assistant` frame replaces
/// the partial deltas that preceded it.
final class ClaudeParser: OutputParser {
    private enum BlockKind { case text, toolUse, thinking, other }

    private struct Block {
        var kind: BlockKind
        var toolId: String?
        /// Concatenated `input_json_delta` chunks of a tool_use block.
        var jsonBuffer = ""
        /// An `assistant` frame has already delivered this block's final form.
        var delivered = false
    }

    private let decoder = JSONDecoder()
    private var messageId = ""
    /// Blocks of the message currently streaming, by stream index. Kept until
    /// the next `message_start` (not dropped at `content_block_stop`) because
    /// the CLI may send the complete `assistant` frame after the stop.
    private var blocks: [Int: Block] = [:]

    func feed(_ line: String, stream: OutputStreamKind) -> [AgentEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        let raw: [AgentEvent] = [.raw(line: line, stream: stream)]
        guard stream == .stdout,
              let obj = ClaudeWire.decode(trimmed, decoder), obj.object != nil,
              let events = dispatch(obj)
        else { return raw }
        return events
    }

    func onExit(code: Int32?) -> [AgentEvent] {
        if code == 0 { return [.status(.finished, detail: nil)] }
        return [
            .error("claude exited with code \(code.map { String($0) } ?? "null")"),
            .status(.errored, detail: nil),
        ]
    }

    // MARK: - dispatch (nil = not understood, surfaced as a raw line)

    private func dispatch(_ obj: JSONValue) -> [AgentEvent]? {
        switch obj["type"]?.string {
        case "system": onSystem(obj)
        case "stream_event": onStreamEvent(obj)
        case "assistant": onAssistant(obj)
        case "user": onUser(obj)
        case "result": onResult(obj)
        case "control_request": onControlRequest(obj)
        // Housekeeping the UI has no use for.
        case "rate_limit_event": []
        default: nil
        }
    }

    private func onSystem(_ obj: JSONValue) -> [AgentEvent]? {
        switch obj["subtype"]?.string {
        case "init":
            let sessionId = obj["session_id"]?.string
            var events: [AgentEvent] = []
            if let sessionId { events.append(.sessionId(sessionId)) }
            events.append(.system(model: obj["model"]?.string, cwd: obj["cwd"]?.string,
                                  permissionMode: obj["permissionMode"]?.string, sessionId: sessionId))
            return events
        case "post_turn_summary":
            var events: [AgentEvent] = [
                .turnEnd(durationMs: nil, costUsd: nil, usage: nil, summary: obj["status_detail"]?.string),
            ]
            if let needsAction = obj["needs_action"]?.string, !needsAction.isEmpty {
                events.append(.status(.waitingInput, detail: needsAction))
            }
            return events
        // Transient chrome: not surfaced.
        case "status", "hook_started", "hook_response", "commands_changed", "task_summary":
            return []
        default:
            return nil
        }
    }

    private func blockId(_ index: Int) -> String { "\(messageId):\(index)" }

    private func onStreamEvent(_ obj: JSONValue) -> [AgentEvent]? {
        guard let event = obj["event"], event.object != nil else { return nil }
        let index = ClaudeWire.int(event["index"]) ?? 0
        switch event["type"]?.string {
        case "message_start":
            messageId = event["message"]?["id"]?.string ?? ""
            blocks.removeAll()
            return [.status(.running, detail: nil)]
        case "content_block_start":
            let block = event["content_block"]
            let kind: BlockKind = switch block?["type"]?.string {
            case "text": .text
            case "tool_use": .toolUse
            case "thinking": .thinking
            default: .other
            }
            blocks[index] = Block(kind: kind, toolId: block?["id"]?.string)
            // The complete block arrives on the `assistant` frame; emitting here
            // too would duplicate it in the transcript.
            return []
        case "content_block_delta":
            guard let delta = event["delta"], delta.object != nil else { return [] }
            switch delta["type"]?.string {
            case "text_delta":
                return [.text(role: .assistant, text: delta["text"]?.string ?? "", blockId: blockId(index), partial: true)]
            case "thinking_delta":
                return [.thinking(text: delta["thinking"]?.string ?? "", blockId: blockId(index), partial: true)]
            case "input_json_delta":
                blocks[index]?.jsonBuffer += delta["partial_json"]?.string ?? ""
                return []
            default:
                return []
            }
        case "content_block_stop", "message_delta", "message_stop":
            return []
        default:
            return nil
        }
    }

    private func onAssistant(_ obj: JSONValue) -> [AgentEvent]? {
        guard let message = obj["message"], message.object != nil else { return [] }
        let id = message["id"]?.string ?? messageId
        // `blocks` describes this message only if it is the one that streamed.
        let streamed = id == messageId
        var events: [AgentEvent] = []
        for (position, block) in (message["content"]?.array ?? []).enumerated() {
            switch block["type"]?.string {
            case "text":
                // The CLI may split one message into several frames (one block
                // each), so the array position is not the stream index.
                let index = (streamed ? claimStreamedText() : nil) ?? position
                events.append(.text(role: .assistant, text: block["text"]?.string ?? "",
                                    blockId: "\(id):\(index)", partial: false))
            case "tool_use":
                let toolId = block["id"]?.string ?? ""
                var input = block["input"]
                if input == nil || input == .null, streamed { input = streamedInput(toolId) }
                events.append(.toolUse(id: toolId, name: block["name"]?.string ?? "",
                                       input: input ?? .object([:]), edit: nil))
            default:
                break
            }
        }
        return events
    }

    /// Lowest-index streamed text block not yet delivered by an `assistant` frame.
    private func claimStreamedText() -> Int? {
        guard let index = blocks.filter({ $0.value.kind == .text && !$0.value.delivered }).keys.min() else { return nil }
        blocks[index]?.delivered = true
        return index
    }

    /// The tool input assembled from `input_json_delta` chunks, used when the
    /// `assistant` frame carries none.
    private func streamedInput(_ toolId: String) -> JSONValue? {
        guard let block = blocks.values.first(where: { $0.kind == .toolUse && $0.toolId == toolId }),
              !block.jsonBuffer.isEmpty else { return nil }
        return ClaudeWire.decode(block.jsonBuffer, decoder)
    }

    private func onUser(_ obj: JSONValue) -> [AgentEvent]? {
        guard let message = obj["message"], message.object != nil else { return [] }
        let edit = ClaudeWire.editPreview(toolUseResult: obj["tool_use_result"])
        var events: [AgentEvent] = []
        for block in message["content"]?.array ?? [] {
            switch block["type"]?.string {
            case "tool_result":
                events.append(.toolResult(toolUseId: block["tool_use_id"]?.string ?? "",
                                          output: ClaudeWire.flatten(block["content"]),
                                          isError: block["is_error"]?.bool == true, edit: edit))
            case "text":
                events.append(.text(role: .user, text: block["text"]?.string ?? "", blockId: nil, partial: false))
            default:
                break
            }
        }
        return events
    }

    private func onResult(_ obj: JSONValue) -> [AgentEvent]? {
        let usage = obj["usage"]
        var events: [AgentEvent] = [
            .usage(
                UsageTotals(
                    inputTokens: ClaudeWire.int(usage?["input_tokens"]) ?? 0,
                    outputTokens: ClaudeWire.int(usage?["output_tokens"]) ?? 0,
                    cacheRead: ClaudeWire.int(usage?["cache_read_input_tokens"]) ?? 0,
                    cacheWrite: ClaudeWire.int(usage?["cache_creation_input_tokens"]) ?? 0
                ),
                costUsd: ClaudeWire.double(obj["total_cost_usd"]),
                durationMs: ClaudeWire.int(obj["duration_ms"]),
                turns: ClaudeWire.int(obj["num_turns"])
            ),
        ]
        if obj["is_error"]?.bool == true {
            events.append(.error(obj["result"]?.string ?? obj["subtype"]?.string ?? "Agent reported an error"))
            events.append(.status(.errored, detail: nil))
        } else {
            // The process stays alive after a result, awaiting the next stdin turn.
            events.append(.status(.idle, detail: nil))
        }
        return events
    }

    // NOTE: unverified against a live permission prompt: no control_request
    // frame appears in the recorded fixture.
    private func onControlRequest(_ obj: JSONValue) -> [AgentEvent]? {
        guard let request = obj["request"], request.object != nil,
              let requestId = obj["request_id"]?.string,
              request["subtype"]?.string == "can_use_tool"
        else { return nil }
        let toolName = request["tool_name"]?.string ?? ""
        return [
            .permissionRequest(requestId: requestId, toolName: toolName, input: request["input"] ?? .object([:])),
            .status(.waitingInput, detail: toolName.isEmpty ? "Permission needed" : "Permission needed: \(toolName)"),
        ]
    }
}

/// Wire helpers private to the Claude provider.
private enum ClaudeWire {
    /// Max diff lines kept in an EditPreview; the UI only renders a mini-diff.
    static let maxPreviewLines = 200

    /// Decoded with `JSONDecoder` rather than `JSONValue.parse`: the latter goes
    /// through `JSONSerialization`, whose NSNumbers `JSONValue(any:)` reads as
    /// Bool for 0 and 1 (so `"index": 1` would become `true`).
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

    /// A JSON string literal, escaped exactly like `JSON.stringify`.
    static func quoted(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case _ where scalar.value < 0x20:
                out += (scalar.value < 0x10 ? "\\u000" : "\\u00") + String(scalar.value, radix: 16)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    /// A tool_result `content` field: a string, or an array of content blocks.
    static func flatten(_ content: JSONValue?) -> String {
        if let s = content?.string { return s }
        return (content?.array ?? []).compactMap { $0["text"]?.string }.joined()
    }

    static func editPreview(toolUseResult result: JSONValue?) -> EditPreview? {
        guard let result, result.object != nil else { return nil }
        let filePath = result["filePath"]?.string ?? result["file_path"]?.string ?? ""
        let patch = result["structuredPatch"]?.array ?? []
        if !patch.isEmpty { return preview(structuredPatch: patch, filePath: filePath) }
        if result["type"]?.string == "create", let content = result["content"]?.string {
            return preview(createdFile: filePath, content: content)
        }
        return nil
    }

    private static func preview(structuredPatch patch: [JSONValue], filePath: String) -> EditPreview? {
        var lines: [EditPreview.Line] = []
        var additions = 0, deletions = 0
        for hunk in patch {
            for entry in hunk["lines"]?.array ?? [] {
                guard let raw = entry.string else { continue }
                if lines.count >= maxPreviewLines { break }
                let scalars = raw.unicodeScalars
                let rest = String(Substring(scalars.dropFirst()))
                switch scalars.first {
                case "+": additions += 1; lines.append(.init(origin: .added, content: rest))
                case "-": deletions += 1; lines.append(.init(origin: .removed, content: rest))
                case " ": lines.append(.init(origin: .context, content: rest))
                default: lines.append(.init(origin: .context, content: raw))
                }
            }
        }
        if lines.isEmpty { return nil }
        return EditPreview(filePath: filePath, additions: additions, deletions: deletions, lines: lines)
    }

    /// A freshly created file: every line is an addition.
    private static func preview(createdFile filePath: String, content: String) -> EditPreview {
        var all = content.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String(Substring($0)) }
        if all.last == "" { all.removeLast() }
        return EditPreview(filePath: filePath, additions: all.count, deletions: 0,
                           lines: all.prefix(maxPreviewLines).map { .init(origin: .added, content: $0) })
    }
}
