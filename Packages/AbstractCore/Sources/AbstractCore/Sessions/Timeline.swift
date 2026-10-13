import Foundation

/// One normalised event in a chat, with a stable identity for the UI.
public struct TimelineEntry: Sendable, Identifiable, Hashable {
    public let id: Int
    public var event: AgentEvent
    /// When the line it came from was logged; nil in logs from before lines
    /// carried a time. Streamed text keeps the time it started.
    public var at: Date?

    public init(id: Int, event: AgentEvent, at: Date? = nil) {
        self.id = id; self.event = event; self.at = at
    }
}

/// A chat's events, assembled for reading.
public struct Timeline: Sendable {
    public private(set) var entries: [TimelineEntry] = []
    private var nextId = 0

    public init() {}

    /// Streaming text arrives as chunks sharing a block id, then once more
    /// complete. Both collapse into one entry, so the chat reads like a
    /// document rather than a stutter.
    public mutating func append(_ event: AgentEvent, at: Date? = nil) {
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
        entries.append(TimelineEntry(id: nextId, event: event, at: at))
    }

    public mutating func append(contentsOf events: [AgentEvent], at: Date? = nil) {
        for e in events { append(e, at: at) }
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

    /// The commands the agent last reported, since the chat last changed agent.
    public var latestCommands: AgentCommandList? {
        for entry in entries.reversed() {
            switch entry.event {
            case .commands(let list): return list
            case .handoff: return nil
            default: continue
            }
        }
        return nil
    }

    public var last: AgentEvent? { entries.last?.event }

    /// When the turn under way began: your message, or what the agent did
    /// first after its last turn ended. Nil once it has ended, and for a log
    /// from before lines had times.
    public var turnStart: Date? {
        var first: Date?
        for entry in entries.reversed() {
            switch entry.event {
            case .text(.user, _, _, _): return entry.at
            case .status(.idle, _), .status(.finished, _), .status(.errored, _), .handoff: return first
            case .text, .thinking, .toolUse: first = entry.at ?? first
            default: continue
            }
        }
        return first
    }

    /// When the chat started: its first line with a time.
    public var startedAt: Date? { entries.first { $0.at != nil }?.at }

    /// The agent's latest reply with something in it.
    public var lastReply: String? {
        for entry in entries.reversed() {
            if case let .text(.assistant, text, _, _) = entry.event,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        }
        return nil
    }
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
    /// The end of a turn: one per turn, for every agent.
    case turn(id: Int, TurnRecap)
    case error(id: Int, message: String)
    /// A retry, a usage limit or a warning, on one line.
    case notice(id: Int, AgentNotice)
    case raw(id: Int, lines: [OutputLine])
    /// The chat passed to another agent here.
    case handoff(id: Int, from: String, to: String, summary: String?, source: HandoffSource?)

    public var id: Int {
        switch self {
        case .user(let id, _), .assistant(let id, _, _, _), .thinking(let id, _), .tools(let id, _),
             .system(let id, _, _), .turn(let id, _), .error(let id, _), .notice(let id, _), .raw(let id, _),
             .handoff(let id, _, _, _, _): id
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
    /// Pictures the result carried besides its text.
    public var images: [ToolImage]
    public init(output: String, isError: Bool, images: [ToolImage] = []) {
        self.output = output; self.isError = isError; self.images = images
    }
}

extension Timeline {
    public var blocks: [TimelineBlock] {
        var results: [String: (String, Bool, EditPreview?)] = [:]
        var images: [String: [ToolImage]] = [:]
        var errors: Set<String> = []
        for e in entries {
            switch e.event {
            case let .toolResult(toolUseId, output, isError, edit): results[toolUseId] = (output, isError, edit)
            case let .toolImages(toolUseId, pictures): images[toolUseId, default: []] += pictures
            case let .error(message): errors.insert(message)
            default: break
            }
        }
        // A retry shows only while nothing has come since; stray raw lines
        // aren't the agent carrying on.
        let liveRetry = entries.last { if case .raw = $0.event { false } else { true } }
            .flatMap { if case .notice(.retrying) = $0.event { $0.id } else { nil } }

        var out: [TimelineBlock] = []
        var assistantOpen = false

        // The turn under way: when it began, whether it has ended, and its
        // line once it has one. A turn's line sits below everything the turn
        // did, so it moves down as the agent carries on (OpenCode reports
        // usage after every step).
        var turnStart: Date?
        var turnEnded = false
        var recap: (index: Int, id: Int, value: TurnRecap)?
        func startTurn(at: Date?) {
            recap = nil
            turnEnded = false
            turnStart = at
        }
        /// What the agent did, opening the next turn if the last one ended.
        func working(_ entry: TimelineEntry) {
            if turnEnded { startTurn(at: entry.at) } else if turnStart == nil { turnStart = entry.at }
        }
        func updateTurn(_ entry: TimelineEntry, ends: Bool, _ change: (inout TurnRecap) -> Void) {
            var value = recap?.value ?? TurnRecap(start: turnStart)
            let id = recap?.id ?? entry.id
            if let recap { out.remove(at: recap.index) }
            change(&value)
            // A turn ends once; what comes after only adds to its line.
            if !turnEnded { value.end = entry.at ?? value.end }
            if ends { turnEnded = true }
            out.append(.turn(id: id, value))
            recap = (out.count - 1, id, value)
        }

        for entry in entries {
            switch entry.event {
            case let .text(role, text, _, partial):
                if role == .user {
                    out.append(.user(id: entry.id, text: text))
                    assistantOpen = false
                    startTurn(at: entry.at)
                } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    working(entry)
                    out.append(.assistant(id: entry.id, text: text, streaming: partial, opensTurn: !assistantOpen))
                    assistantOpen = true
                }
            case let .thinking(text, _, _):
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    working(entry)
                    out.append(.thinking(id: entry.id, text: text))
                }
            case let .toolUse(id, name, input, edit):
                working(entry)
                let r = results[id]
                // The tool's own result diff wins (it has line numbers); until
                // then the diff comes from the input, so it shows straight away.
                let call = ToolCall(id: id, name: name, input: input,
                                    edit: r?.2 ?? edit,
                                    result: r.map { ToolResult(output: $0.0, isError: $0.1, images: images[id] ?? []) })
                if case let .tools(groupId, calls)? = out.last {
                    out[out.count - 1] = .tools(id: groupId, calls: calls + [call])
                } else {
                    out.append(.tools(id: entry.id, calls: [call]))
                }
                assistantOpen = true
            case let .system(model, _, mode, _):
                out.append(.system(id: entry.id, model: model, permissionMode: mode))
            case let .turnEnd(duration, cost, usage, summary):
                let stopped = entry.event == TurnStop.rule
                updateTurn(entry, ends: false) { turn in
                    if stopped { turn.outcome = .stopped } else { turn.summary = summary ?? turn.summary }
                    turn.add(usage: usage, costUsd: cost, reportedMs: duration)
                }
                assistantOpen = false
            case let .usage(usage, cost, duration, _):
                updateTurn(entry, ends: false) { $0.add(usage: usage, costUsd: cost, reportedMs: duration) }
                assistantOpen = false
            case let .status(status, _) where status == .idle || status == .finished || status == .errored:
                // Only a turn under way ends; a status after it has nothing to add.
                guard !turnEnded, recap != nil || turnStart != nil else { continue }
                updateTurn(entry, ends: true) { if status == .errored { $0.outcome = .failed } }
                assistantOpen = false
            case let .error(message):
                out.append(.error(id: entry.id, message: message))
            case let .notice(notice):
                switch notice {
                case .retrying: if entry.id != liveRetry { continue }
                // A warning the turn then failed over is said once, as the error.
                case let .warning(message): if errors.contains(message) { continue }
                case .nearLimit, .limitReached, .info: break
                }
                out.append(.notice(id: entry.id, notice))
            case let .raw(line, stream):
                if case let .raw(groupId, lines)? = out.last {
                    out[out.count - 1] = .raw(id: groupId, lines: lines + [OutputLine(stream: stream, line: line)])
                } else {
                    out.append(.raw(id: entry.id, lines: [OutputLine(stream: stream, line: line)]))
                }
            case let .handoff(from, to, summary, source):
                out.append(.handoff(id: entry.id, from: from, to: to, summary: summary, source: source))
                assistantOpen = false
                startTurn(at: nil)
            // Tasks and what subagents did are listed apart from the conversation.
            case .status, .sessionId, .toolResult, .toolImages, .permissionRequest, .promptSuggestion, .commands, .task, .subagent:
                break
            }
        }
        return out
    }
}

extension TurnRecap {
    /// Several reports in one turn (OpenCode's steps) add up.
    mutating func add(usage: UsageTotals?, costUsd: Double?, reportedMs: Int?) {
        if let usage { self.usage = (self.usage ?? .zero) + usage }
        if let costUsd { self.costUsd = (self.costUsd ?? 0) + costUsd }
        if let reportedMs { self.reportedMs = (self.reportedMs ?? 0) + reportedMs }
    }
}
