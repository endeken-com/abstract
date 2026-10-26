import Foundation

/// Where in a chat's transcript a match is.
public enum TranscriptField: Hashable, Sendable {
    /// What you wrote, without the attachments under it.
    case user
    case reply
    case thinking
    /// A tool call's title: its command, file path or the like.
    case toolTitle(callId: String)
    case toolOutput(callId: String)
}

/// One place the words you're finding appear in a chat.
public struct TranscriptMatch: Hashable, Sendable {
    /// The timeline block it's in.
    public let block: Int
    public let field: TranscriptField
    /// Which appearance of the words in that field, from 0.
    public let occurrence: Int
    /// Where it starts in the field's text, in UTF-16 units.
    public let location: Int

    public init(block: Int, field: TranscriptField, occurrence: Int, location: Int) {
        self.block = block; self.field = field; self.occurrence = occurrence; self.location = location
    }

    /// The same match after the chat grows, wherever its text moves.
    var key: Key { Key(block: block, field: field, occurrence: occurrence) }
    struct Key: Hashable { let block: Int; let field: TranscriptField; let occurrence: Int }
}

/// What finding in a chat looks through: your messages, the agent's replies,
/// its thinking when it's shown, and each tool call's title and output.
public struct TranscriptSearch: Sendable {
    public var includesThinking: Bool
    /// A call's searchable text, title first, in the order it reads.
    public var toolFields: @Sendable (ToolCall) -> [(TranscriptField, String)]

    public init(includesThinking: Bool = true,
                toolFields: @escaping @Sendable (ToolCall) -> [(TranscriptField, String)] = TranscriptSearch.defaultToolFields) {
        self.includesThinking = includesThinking
        self.toolFields = toolFields
    }

    /// The command or the file a call works on, then what it returned.
    public static func defaultToolFields(_ call: ToolCall) -> [(TranscriptField, String)] {
        let o = call.input.object ?? [:]
        let title = ["command", "file_path", "filePath", "notebook_path", "path", "pattern", "query", "url", "description"]
            .lazy.compactMap { o[$0]?.string }.first { !$0.isEmpty }
        return [title.map { (.toolTitle(callId: call.id), $0) }, call.result.map { (.toolOutput(callId: call.id), $0.output) }]
            .compactMap { $0 }
    }

    /// Every match, in reading order.
    public func matches(of query: String, in blocks: [TimelineBlock]) -> [TranscriptMatch] {
        guard !query.isEmpty else { return [] }
        var out: [TranscriptMatch] = []
        func add(_ block: Int, _ field: TranscriptField, _ text: String) {
            for (i, range) in Self.ranges(of: query, in: text).enumerated() {
                out.append(TranscriptMatch(block: block, field: field, occurrence: i, location: range.lowerBound.utf16Offset(in: text)))
            }
        }
        for block in blocks {
            switch block {
            case let .user(id, text): add(id, .user, PromptAttachments.split(text).text)
            case let .assistant(id, text, _, _): add(id, .reply, text)
            case let .thinking(id, text) where includesThinking: add(id, .thinking, text)
            case let .tools(id, calls):
                for call in calls { for (field, text) in toolFields(call) { add(id, field, text) } }
            default: break
            }
        }
        return out
    }

    /// Where `query` appears in `text`, ignoring case and accents, without overlaps.
    public static func ranges(of query: String, in text: String) -> [Range<String.Index>] {
        guard !query.isEmpty else { return [] }
        var out: [Range<String.Index>] = []
        var start = text.startIndex
        while start < text.endIndex,
              let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: start..<text.endIndex) {
            out.append(range)
            start = range.upperBound
        }
        return out
    }
}

/// Finding in one chat: the matches, which one you're on, and whether the
/// transcript has been taken to it yet.
public struct TranscriptFind: Sendable, Equatable {
    public private(set) var query = ""
    public private(set) var matches: [TranscriptMatch] = []
    public private(set) var current: Int?
    /// Whether the transcript has been taken to the current match. Until it
    /// has, the next match is that one.
    public private(set) var shown = false

    public init() {}

    public var currentMatch: TranscriptMatch? { current.map { matches[$0] } }

    /// "4 of 23", "No results", or nothing before you type.
    public var label: String {
        guard !query.isEmpty else { return "" }
        guard let current else { return "No results" }
        return "\(current + 1) of \(matches.count)"
    }

    /// Finds `query` afresh. The first match is the first at or after block
    /// `from` (the top of what's on screen), or the first of all.
    public mutating func search(_ query: String, in blocks: [TimelineBlock], using search: TranscriptSearch, from block: Int? = nil) {
        self.query = query
        matches = search.matches(of: query, in: blocks)
        shown = false
        guard !matches.isEmpty else { current = nil; return }
        current = block.flatMap { b in matches.firstIndex { $0.block >= b } } ?? 0
    }

    /// The chat grew: new matches join in, and you stay on the one you were on.
    public mutating func refresh(_ blocks: [TimelineBlock], using search: TranscriptSearch) {
        guard !query.isEmpty else { return }
        let was = currentMatch
        let old = current
        matches = search.matches(of: query, in: blocks)
        guard !matches.isEmpty else { current = nil; shown = false; return }
        if let was, let same = matches.firstIndex(where: { $0.key == was.key }) {
            current = same
        } else {
            // What you were on is gone: the nearest takes its place, not yet shown.
            current = min(old ?? 0, matches.count - 1)
            shown = false
        }
    }

    /// The match to show next: the current one if it hasn't been shown yet,
    /// otherwise the one after it, round to the first.
    @discardableResult
    public mutating func next() -> TranscriptMatch? {
        guard let current else { return nil }
        if shown { self.current = (current + 1) % matches.count }
        shown = true
        return currentMatch
    }

    /// The match before the current one, round to the last.
    @discardableResult
    public mutating func previous() -> TranscriptMatch? {
        guard let current else { return nil }
        self.current = (current - 1 + matches.count) % matches.count
        shown = true
        return currentMatch
    }
}
