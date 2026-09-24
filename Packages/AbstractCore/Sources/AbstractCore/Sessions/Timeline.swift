import Foundation

/// One normalised event in a chat, with a stable identity for the UI.
public struct TimelineEntry: Sendable, Identifiable, Hashable {
    public let id: Int
    public var event: AgentEvent
}

/// A chat's events, assembled for reading.
public struct Timeline: Sendable {
    public private(set) var entries: [TimelineEntry] = []
    private var nextId = 0

    public init() {}

    /// Streaming text arrives as chunks sharing a block id, then once more
    /// complete. Both collapse into one entry, so the chat reads like a
    /// document rather than a stutter.
    public mutating func append(_ event: AgentEvent) {
        // An edit's diff is worked out once, as it arrives, not on every read.
        var event = event
        if case let .toolUse(id, name, input, nil) = event {
            event = .toolUse(id: id, name: name, input: input, edit: EditPreview.fromToolInput(name: name, input: input))
        }
        if let blockId = event.blockId, let index = entries.lastIndex(where: { $0.event.blockId == blockId && $0.event.sameKind(as: event) }) {
            entries[index].event = entries[index].event.merged(with: event)
            return
        }
        nextId += 1
        entries.append(TimelineEntry(id: nextId, event: event))
    }

    public mutating func append(contentsOf events: [AgentEvent]) {
        for e in events { append(e) }
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// The agent's suggested next message, until you send one yourself.
    public var pendingSuggestion: String? {
        for entry in entries.reversed() {
            switch entry.event {
            case .promptSuggestion(let text): return text
            case .text(.user, _, _, _): return nil
            default: continue
            }
        }
        return nil
    }

    public var last: AgentEvent? { entries.last?.event }
}

extension AgentEvent {
    var blockId: String? {
        switch self {
        case .text(_, _, let id, _), .thinking(_, let id, _): id
        default: nil
        }
    }

    func sameKind(as other: AgentEvent) -> Bool {
        switch (self, other) {
        case (.text, .text), (.thinking, .thinking): true
        default: false
        }
    }

    func merged(with incoming: AgentEvent) -> AgentEvent {
        switch (self, incoming) {
        case let (.text(role, old, id, _), .text(_, new, _, partial)):
            .text(role: role, text: partial ? old + new : new, blockId: id, partial: partial)
        case let (.thinking(old, id, _), .thinking(new, _, partial)):
            .thinking(text: partial ? old + new : new, blockId: id, partial: partial)
        default:
            incoming
        }
    }
}

/// What the reader sees: the flat event list folded into prose, grouped tool
/// activity, turn summaries and errors.
public enum TimelineBlock: Sendable, Identifiable, Hashable {
    case user(id: Int, text: String)
    case assistant(id: Int, text: String, streaming: Bool, opensTurn: Bool)
    case thinking(id: Int, text: String)
    case tools(id: Int, calls: [ToolCall])
    case system(id: Int, model: String?, permissionMode: String?)
    case turn(id: Int, summary: String?, durationMs: Int?, usage: UsageTotals?, costUsd: Double?)
    case error(id: Int, message: String)
    case raw(id: Int, lines: [OutputLine])

    public var id: Int {
        switch self {
        case .user(let id, _), .assistant(let id, _, _, _), .thinking(let id, _), .tools(let id, _),
             .system(let id, _, _), .turn(let id, _, _, _, _), .error(let id, _), .raw(let id, _): id
        }
    }
}

public struct ToolCall: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var input: JSONValue
    public var edit: EditPreview?
    public var result: ToolResult?

    public init(id: String, name: String, input: JSONValue, edit: EditPreview? = nil, result: ToolResult? = nil) {
        self.id = id; self.name = name; self.input = input; self.edit = edit; self.result = result
    }
}

public struct ToolResult: Sendable, Hashable {
    public var output: String
    public var isError: Bool
    public init(output: String, isError: Bool) { self.output = output; self.isError = isError }
}

extension Timeline {
    public var blocks: [TimelineBlock] {
        var results: [String: (String, Bool, EditPreview?)] = [:]
        for e in entries {
            if case let .toolResult(toolUseId, output, isError, edit) = e.event { results[toolUseId] = (output, isError, edit) }
        }

        var out: [TimelineBlock] = []
        var assistantOpen = false
        var pendingTurn: Int?

        for entry in entries {
            switch entry.event {
            case let .text(role, text, _, partial):
                if role == .user {
                    out.append(.user(id: entry.id, text: text))
                    assistantOpen = false
                } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    out.append(.assistant(id: entry.id, text: text, streaming: partial, opensTurn: !assistantOpen))
                    assistantOpen = true
                }
            case let .thinking(text, _, _):
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(.thinking(id: entry.id, text: text)) }
            case let .toolUse(id, name, input, edit):
                let r = results[id]
                // The tool's own result diff wins (it has line numbers); until
                // then the diff comes from the input, so it shows straight away.
                let call = ToolCall(id: id, name: name, input: input,
                                    edit: r?.2 ?? edit,
                                    result: r.map { ToolResult(output: $0.0, isError: $0.1) })
                if case let .tools(groupId, calls)? = out.last {
                    out[out.count - 1] = .tools(id: groupId, calls: calls + [call])
                } else {
                    out.append(.tools(id: entry.id, calls: [call]))
                }
                assistantOpen = true
            case let .system(model, _, mode, _):
                out.append(.system(id: entry.id, model: model, permissionMode: mode))
            case let .turnEnd(duration, cost, usage, summary):
                out.append(.turn(id: entry.id, summary: summary, durationMs: duration, usage: usage, costUsd: cost))
                pendingTurn = out.count - 1
                assistantOpen = false
            case let .usage(usage, cost, duration, _):
                // Usage lands right after the turn summary: fold it into that rule.
                if let i = pendingTurn, case let .turn(id, summary, d, u, c) = out[i], u == nil {
                    out[i] = .turn(id: id, summary: summary, durationMs: d ?? duration, usage: usage, costUsd: c ?? cost)
                } else {
                    out.append(.turn(id: entry.id, summary: nil, durationMs: duration, usage: usage, costUsd: cost))
                }
                pendingTurn = nil
                assistantOpen = false
            case let .error(message):
                out.append(.error(id: entry.id, message: message))
            case let .raw(line, stream):
                if case let .raw(groupId, lines)? = out.last {
                    out[out.count - 1] = .raw(id: groupId, lines: lines + [OutputLine(stream: stream, line: line)])
                } else {
                    out.append(.raw(id: entry.id, lines: [OutputLine(stream: stream, line: line)]))
                }
            case .status, .sessionId, .toolResult, .permissionRequest, .promptSuggestion:
                break
            }
        }
        return out
    }
}
