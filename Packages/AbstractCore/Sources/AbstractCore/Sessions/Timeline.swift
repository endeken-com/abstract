import Foundation

/// One normalised event in a chat, with a stable identity for the UI.
public struct TimelineEntry: Sendable, Identifiable, Hashable {
    public let id: Int
    public var event: AgentEvent
    /// When its line was logged (the latest, for text that streamed in); nil
    /// in logs from before times were kept.
    public var at: Date?

    public init(id: Int, event: AgentEvent, at: Date? = nil) { self.id = id; self.event = event; self.at = at }
}

/// A chat's events, assembled for reading.
public struct Timeline: Sendable {
    public private(set) var entries: [TimelineEntry] = []
    private var nextId = 0
    private var textEntries: [String: Int] = [:]
    private var thinkingEntries: [String: Int] = [:]

    public init() {}

    /// Streaming text arrives as chunks sharing a block id, then once more
    /// complete. Both collapse into one entry, so the chat reads like a
    /// document rather than a stutter.
    /// `at`: when the event's line was logged.
    public mutating func append(_ event: AgentEvent, at: Date? = nil) {
        // An edit's diff is worked out once, as it arrives, not on every read.
        var event = event
        if case let .toolUse(id, name, input, nil) = event {
            event = .toolUse(id: id, name: name, input: input, edit: EditPreview.fromToolInput(name: name, input: input))
        }
        let previous: Int? = switch event {
        case let .text(_, _, blockId?, _): textEntries[blockId]
        case let .thinking(_, blockId?, _): thinkingEntries[blockId]
        default: nil
        }
        if let index = previous {
            entries[index].event = entries[index].event.merged(with: event)
            entries[index].at = at ?? entries[index].at
            return
        }
        nextId += 1
        entries.append(TimelineEntry(id: nextId, event: event, at: at))
        switch event {
        case let .text(_, _, blockId?, _): textEntries[blockId] = entries.count - 1
        case let .thinking(_, blockId?, _): thinkingEntries[blockId] = entries.count - 1
        default: break
        }
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
    /// The end of a turn: how it ended and how long it took.
    case turn(id: Int, TurnInfo)
    case error(id: Int, message: String)
    /// A retry, a usage limit or a warning, on one line.
    case notice(id: Int, AgentNotice)
    case raw(id: Int, lines: [OutputLine])
    case gitOperation(id: Int, GitOperation)
    /// The chat passed to another agent here.
    case handoff(id: Int, from: String, to: String, summary: String?, source: HandoffSource?)
    /// The agent's context was compacted here, or is being.
    case compaction(id: Int, trigger: CompactionTrigger, state: CompactionState)

    public var id: Int {
        switch self {
        case .user(let id, _), .assistant(let id, _, _, _), .thinking(let id, _), .tools(let id, _),
             .system(let id, _, _), .turn(let id, _), .error(let id, _), .notice(let id, _), .raw(let id, _),
             .handoff(let id, _, _, _, _), .gitOperation(let id, _), .compaction(let id, _, _): id
        }
    }
}

public enum CompactionState: Sendable, Hashable {
    case running
    case done(CompactionResult, durationMs: Int?)
    case failed(String)

    /// A compaction the turn ended, or an error cut short.
    public static let stoppedEarly = "The agent stopped before compacting finished."
}

public struct ToolCall: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var input: JSONValue
    public var edit: EditPreview?
    public var fileChanges: ToolFileChanges?
    public var result: ToolResult?

    public init(id: String, name: String, input: JSONValue, edit: EditPreview? = nil,
                fileChanges: ToolFileChanges? = nil, result: ToolResult? = nil) {
        self.id = id; self.name = name; self.input = input; self.edit = edit
        self.fileChanges = fileChanges; self.result = result
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
        var fileChanges: [String: ToolFileChanges] = [:]
        var images: [String: [ToolImage]] = [:]
        var errors: Set<String> = []
        for e in entries {
            switch e.event {
            case let .toolResult(toolUseId, output, isError, edit): results[toolUseId] = (output, isError, edit)
            case let .toolFileChanges(toolUseId, changes): fileChanges[toolUseId] = changes
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
        var turns = TurnTracker()
        var runningCompaction: Int?
        var afterCompaction = false
        var pendingCallId: Int?
        var pendingCalls: [ToolCall] = []
        var pendingRawId: Int?
        var pendingRaw: [OutputLine] = []

        func flushGroups() {
            if let id = pendingCallId {
                out.append(.tools(id: id, calls: pendingCalls))
                pendingCallId = nil
                pendingCalls = []
            }
            if let id = pendingRawId {
                out.append(.raw(id: id, lines: pendingRaw))
                pendingRawId = nil
                pendingRaw = []
            }
        }

        func emit(_ block: TimelineBlock) {
            flushGroups()
            out.append(block)
        }

        /// Ends the compaction under way, or adds one that ended unseen.
        func closeCompaction(_ state: CompactionState, trigger: CompactionTrigger?, entryId: Int) {
            if let i = runningCompaction, case let .compaction(id, started, _) = out[i] {
                out[i] = .compaction(id: id, trigger: trigger ?? started, state: state)
            } else {
                emit(.compaction(id: entryId, trigger: trigger ?? .manual, state: state))
            }
            runningCompaction = nil
            afterCompaction = true
        }

        for entry in entries {
            // A turn that ends, an error or your message mid-compaction ended it too.
            switch entry.event {
            case .turnEnd, .usage, .error, .text(.user, _, _, _):
                if runningCompaction != nil {
                    closeCompaction(.failed(CompactionState.stoppedEarly), trigger: nil, entryId: entry.id)
                    afterCompaction = false
                }
            default: break
            }
            if let line = turns.read(entry) {
                // Claude ends a compaction with an empty turn: no line under the compaction's.
                if !afterCompaction { emit(line) }
                assistantOpen = false
            }
            if afterCompaction {
                switch entry.event {
                case .system, .status, .sessionId, .launch, .commands, .promptSuggestion, .task, .subagent,
                     .toolResult, .toolFileChanges, .toolImages, .permissionRequest, .turnEnd, .usage, .compaction: break
                default: afterCompaction = false
                }
            }
            switch entry.event {
            case let .text(role, text, _, partial):
                if role == .user {
                    emit(.user(id: entry.id, text: text))
                    assistantOpen = false
                } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    emit(.assistant(id: entry.id, text: text, streaming: partial, opensTurn: !assistantOpen))
                    assistantOpen = true
                }
            case let .thinking(text, _, _):
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { emit(.thinking(id: entry.id, text: text)) }
            case let .toolUse(id, name, input, edit):
                let r = results[id]
                // The tool's own result diff wins (it has line numbers); until
                // then the diff comes from the input, so it shows straight away.
                let call = ToolCall(id: id, name: name, input: input,
                                    edit: r?.2 ?? edit,
                                    fileChanges: fileChanges[id],
                                    result: r.map { ToolResult(output: $0.0, isError: $0.1, images: images[id] ?? []) })
                if pendingRawId != nil { flushGroups() }
                if pendingCallId == nil { pendingCallId = entry.id }
                pendingCalls.append(call)
                assistantOpen = true
            case let .system(model, _, mode, _):
                emit(.system(id: entry.id, model: model, permissionMode: mode))
            case let .error(message):
                emit(.error(id: entry.id, message: message))
            case let .notice(notice):
                switch notice {
                case .retrying: if entry.id != liveRetry { continue }
                // A warning the turn then failed over is said once, as the error.
                case let .warning(message): if errors.contains(message) { continue }
                case .nearLimit, .limitReached, .info: break
                }
                emit(.notice(id: entry.id, notice))
            case let .raw(line, stream):
                if pendingCallId != nil { flushGroups() }
                if pendingRawId == nil { pendingRawId = entry.id }
                pendingRaw.append(OutputLine(stream: stream, line: line))
            case let .gitOperation(operation):
                switch operation {
                case .commit, .push: emit(.gitOperation(id: entry.id, operation))
                case .pullRequest: break
                }
            case let .handoff(from, to, summary, source):
                emit(.handoff(id: entry.id, from: from, to: to, summary: summary, source: source))
                assistantOpen = false
            case let .compaction(event):
                switch event {
                case let .started(trigger):
                    if runningCompaction == nil {
                        emit(.compaction(id: entry.id, trigger: trigger ?? .auto, state: .running))
                        runningCompaction = out.count - 1
                    }
                case let .finished(result, trigger, durationMs):
                    closeCompaction(.done(result, durationMs: durationMs), trigger: trigger, entryId: entry.id)
                case let .failed(message):
                    closeCompaction(.failed(message), trigger: nil, entryId: entry.id)
                }
                assistantOpen = false
            // Tasks and what subagents did are listed apart from the conversation;
            // a turn's end and usage make its line, above.
            case .status, .sessionId, .launch, .toolResult, .toolFileChanges, .toolImages, .permissionRequest, .promptSuggestion, .commands, .task, .subagent,
                 .turnEnd, .usage:
                break
            }
        }
        if !afterCompaction, let line = turns.pendingLine { emit(line) }
        flushGroups()
        return out
    }

    /// A compaction started and hasn't ended, e.g. the app quit during it.
    public var hasRunningCompaction: Bool {
        blocks.contains { if case .compaction(_, _, .running) = $0 { true } else { false } }
    }

    /// When the turn under way started, read from the log, so a relaunch or
    /// another Mac knows it too. nil between turns, or when the log doesn't say.
    public var turnStartedAt: Date? {
        var turns = TurnTracker()
        for entry in entries { _ = turns.read(entry) }
        return turns.active ? turns.startedAt : nil
    }
}
