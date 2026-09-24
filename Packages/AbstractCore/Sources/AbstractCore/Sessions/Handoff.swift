import Foundation

/// Who wrote the summary a chat was handed over with.
public enum HandoffSource: String, Sendable, Codable, Hashable {
    /// The agent handing over, asked for a note in a hidden turn.
    case agent
    /// Backtick, from the transcript: the agent couldn't or didn't answer.
    case app
}

/// A chat passing from one agent to another, kept in its log as a `.handoff`
/// line so a replay knows whose output follows.
public struct HandoffMarker: Sendable, Codable, Hashable {
    public enum Phase: String, Sendable, Codable {
        /// The agent handing over starts its hidden summary turn.
        case summarize
        /// The chat is the incoming agent's from here.
        case handoff
    }

    public var phase: Phase
    public var from: String
    public var to: String
    public var summary: String?
    public var source: HandoffSource?
    public var transcriptPath: String?

    public init(phase: Phase, from: String, to: String, summary: String? = nil, source: HandoffSource? = nil,
                transcriptPath: String? = nil) {
        self.phase = phase; self.from = from; self.to = to
        self.summary = summary; self.source = source; self.transcriptPath = transcriptPath
    }

    public init?(_ line: OutputLine) {
        guard line.stream == .handoff, let marker = try? JSONDecoder().decode(Self.self, from: Data(line.line.utf8)) else { return nil }
        self = marker
    }

    public var line: OutputLine {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        return OutputLine(stream: .handoff, line: String(decoding: data, as: UTF8.self))
    }
}

/// A chat's log lines as events, for whichever agent wrote them: a handoff
/// switches to the incoming agent's parser, and the outgoing agent's hidden
/// summary turn is read but not shown. Used live, on replay and by mirrors.
public final class ChatStream {
    public private(set) var providerId: String
    private var parser: (any OutputParser)?
    private let makeParser: (String) -> (any OutputParser)?

    /// Between a `summarize` marker and the handoff that follows it.
    public private(set) var isSummarizing = false
    /// The summary turn ended: a result, an error or the process exiting.
    public private(set) var summaryFinished = false
    public private(set) var summaryFailed = false
    private var summaryTurn = Timeline()

    public init(providerId: String,
                makeParser: @escaping (String) -> (any OutputParser)? = { ProviderRegistry.provider($0)?.makeParser() }) {
        self.providerId = providerId
        self.makeParser = makeParser
        parser = makeParser(providerId)
    }

    /// A fresh parser, as for a newly launched process.
    public func restart(providerId: String) {
        self.providerId = providerId
        parser = makeParser(providerId)
    }

    /// What the summary turn said, its replies joined.
    public var capturedSummary: String {
        summaryTurn.blocks.compactMap { block -> String? in
            if case let .assistant(_, text, _, _) = block { text } else { nil }
        }.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func feed(_ line: OutputLine) -> [AgentEvent] {
        switch line.stream {
        case .handoff:
            guard let marker = HandoffMarker(line) else { return [] }
            switch marker.phase {
            case .summarize:
                isSummarizing = true
                summaryFinished = false
                summaryFailed = false
                summaryTurn = Timeline()
                return []
            case .handoff:
                isSummarizing = false
                restart(providerId: marker.to)
                return [.handoff(from: marker.from, to: marker.to, summary: marker.summary, source: marker.source)]
            }
        case .user:
            // A message of yours means any hidden turn is over, even one whose
            // handoff never got logged.
            isSummarizing = false
            return [.text(role: .user, text: line.line, blockId: nil, partial: false)]
        case .stdout, .stderr:
            let events = parser?.feed(line.line, stream: line.stream) ?? [.raw(line: line.line, stream: line.stream)]
            return isSummarizing ? summarizing(events) : events
        }
    }

    public func onExit(code: Int32?) -> [AgentEvent] {
        guard isSummarizing else { return parser?.onExit(code: code) ?? [] }
        summaryFinished = true
        if code != 0, capturedSummary.isEmpty { summaryFailed = true }
        return []
    }

    /// Keeps the summary turn to itself: only what the app must act on passes.
    private func summarizing(_ events: [AgentEvent]) -> [AgentEvent] {
        var passed: [AgentEvent] = []
        for event in events {
            switch event {
            case .text(.assistant, _, _, _):
                summaryTurn.append(event)
            case .usage, .sessionId, .permissionRequest:
                passed.append(event)
            case .status(.idle, _), .status(.finished, _), .turnEnd:
                summaryFinished = true
            case .status(.errored, _), .error:
                summaryFinished = true
                summaryFailed = true
            default:
                break
            }
        }
        return passed
    }

    /// The events of `lines`, as read back into a chat.
    public func replay(_ lines: [OutputLine]) -> Timeline {
        var timeline = Timeline()
        for line in lines {
            for event in feed(line) {
                // A question from before is either answered or gone.
                if case .permissionRequest = event { continue }
                timeline.append(event)
            }
        }
        return timeline
    }

    public static func timeline(_ lines: [OutputLine], currentProvider: String) -> Timeline {
        ChatStream(providerId: firstProvider(in: lines, current: currentProvider)).replay(lines)
    }

    /// Who wrote a log's first lines: the agent its first handoff came from.
    public static func firstProvider(in lines: [OutputLine], current: String) -> String {
        lines.lazy.compactMap(HandoffMarker.init).first?.from ?? current
    }
}

/// A chat as markdown, for the agent taking it over to read.
public enum HandoffTranscript {
    public static func render(blocks: [TimelineBlock], agentName: String,
                              name: (String) -> String = { ProviderRegistry.provider($0)?.name ?? $0 }) -> String {
        var out = "# Chat transcript\n\nEarlier work in this chat, oldest first.\n"
        var agent = agentName
        var speaker: String?
        func says(_ who: String) {
            if speaker != who { out += "\n## \(who)\n\n" } else { out += "\n" }
            speaker = who
        }
        for block in blocks {
            switch block {
            case let .user(_, text):
                says("You")
                out += PromptAttachments.split(text).text + "\n"
            case let .assistant(_, text, _, _):
                says(agent)
                out += text + "\n"
            case let .tools(_, calls):
                says(agent)
                out += calls.map { "- " + toolLine($0) }.joined(separator: "\n") + "\n"
            case let .error(_, message):
                says(agent)
                out += "> Error: \(message)\n"
            case let .handoff(_, from, to, _, _):
                agent = name(to)
                speaker = nil
                out += "\n---\n\n_Handed over from \(name(from)) to \(agent)._\n"
            case .thinking, .system, .turn, .raw:
                continue
            }
        }
        return out
    }

    /// "Edit `/path`", "Bash `swift test`".
    static func toolLine(_ call: ToolCall) -> String {
        let keys = ["file_path", "path", "notebook_path", "command", "pattern", "url", "query"]
        let target = call.edit?.filePath ?? keys.lazy.compactMap { call.input[$0]?.string }.first
        guard let target else { return call.name }
        let line = target.replacingOccurrences(of: "\n", with: " ")
        return "\(call.name) `\(line.count > 200 ? String(line.prefix(200)) + "…" : line)`"
    }
}

/// A summary Backtick writes itself, when the agent handing over can't.
public enum HandoffDigest {
    public static let maxLength = 4_000

    public static func build(blocks: [TimelineBlock]) -> String {
        var exchanges: [(ask: String, answer: String?)] = []
        var files: [String] = []
        var lastError: String?
        for block in blocks {
            switch block {
            case let .user(_, text):
                exchanges.append((PromptAttachments.split(text).text, nil))
            case let .assistant(_, text, _, _):
                if exchanges.isEmpty { exchanges.append(("", nil)) }
                exchanges[exchanges.count - 1].answer = text
            case let .tools(_, calls):
                for call in calls {
                    guard let path = call.edit?.filePath ?? (editing(call.name) ? call.input["file_path"]?.string : nil),
                          !files.contains(path) else { continue }
                    files.append(path)
                }
            case let .error(_, message):
                lastError = message
            case .handoff:
                lastError = nil
            default:
                continue
            }
        }
        var parts: [String] = []
        if let first = exchanges.first(where: { !$0.ask.isEmpty }) {
            parts.append("The user first asked: \(clip(first.ask, 800))")
        }
        let recent = exchanges.suffix(3)
        if !recent.isEmpty {
            parts.append("Latest exchanges:\n" + recent.map { e in
                var s = "- User: \(clip(e.ask.isEmpty ? "(no message)" : e.ask, 400))"
                if let answer = e.answer { s += "\n  Agent: \(clip(answer, 600))" }
                return s
            }.joined(separator: "\n"))
        }
        if !files.isEmpty { parts.append("Files touched: " + files.suffix(30).joined(separator: ", ")) }
        if let lastError { parts.append("It stopped on an error: \(clip(lastError, 300))") }
        return clip(parts.joined(separator: "\n\n"), maxLength)
    }

    private static func editing(_ tool: String) -> Bool {
        ["Edit", "Write", "MultiEdit", "NotebookEdit"].contains(tool)
    }

    static func clip(_ text: String, _ max: Int) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count <= max ? text : String(text.prefix(max - 1)) + "…"
    }
}

/// What the incoming agent reads before your message. It isn't shown in the chat.
public enum HandoffPreamble {
    public static func compose(from agent: String, summary: String, transcriptPath: String?, resuming: Bool,
                               message: String) -> String {
        var lines = [
            resuming
                ? "While you were away, \(agent) (another coding agent) worked on this chat in the same worktree. Here is what happened since:"
                : "You're taking over this chat from \(agent), another coding agent that worked in this same worktree. Its handover note:",
            "",
            HandoffDigest.clip(summary, HandoffDigest.maxLength),
            "",
        ]
        if let transcriptPath {
            lines.append("The full transcript is at \(transcriptPath). Read it when you need detail the note leaves out.")
        }
        lines.append("Carry on from where it left off; don't redo finished work. The user's message follows.")
        return "<handoff>\n" + lines.joined(separator: "\n") + "\n</handoff>\n\n" + message
    }
}

public enum HandoffPrompt {
    /// The outgoing agent's hidden turn.
    public static let summaryRequest = """
    The user is handing this chat to another coding agent, which will continue in this same worktree. \
    Without using any tools, reply only with a handover note for it: the goal, decisions made and why, \
    the current state (what's done, what's verified), open todos and the next step, and the files touched. \
    Be specific and brief, under 400 words.
    """
}
