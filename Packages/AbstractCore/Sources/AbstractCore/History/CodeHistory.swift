import Foundation

/// The code-history tool Abstract gives each chat's agent (ABS-61): what
/// earlier chats in the same project were asked, corrected and decided
/// about the code the agent is about to change.
public enum CodeHistory {
    /// The MCP server's name, chosen so a user's own server is unlikely
    /// to collide with it.
    public static let serverName = "abstract-code-history"
    public static let historyTool = "code_history"
    public static let excerptTool = "chat_excerpt"

    /// The exact wording ABS-60 proved: a softer line let an agent read a
    /// decision and go against it anyway.
    public static let instruction = """
        Before you change existing code, call the code_history tool for each file you're about to change, \
        with the lines when you know them. It returns what earlier chats in this project were asked, what \
        the person corrected, and what was decided and why. Follow those decisions. If what you've been \
        asked to do goes against one, don't make that change yet: quote the decision, say how the request \
        conflicts with it, and ask whether to go ahead.
        """

    /// The tool name as each agent's stream spells it, Claude-style.
    public static func streamName(_ tool: String) -> String { "mcp__\(serverName)__\(tool)" }

    /// Whether a tool call in a chat is one of this server's, under any
    /// agent's spelling (`mcp__abstract-code-history__code_history`,
    /// OpenCode's `abstract-code-history_code_history`, the bare name).
    public static func tool(inStreamName name: String) -> String? {
        // A plugin's tool (ABS-97) may end the same way; it isn't ours.
        if PluginTools.toolName(inStreamName: name) != nil { return nil }
        for tool in [historyTool, excerptTool] where name == tool || name.hasSuffix("__\(tool)") || name.hasSuffix("_\(tool)") {
            return tool
        }
        return nil
    }
}

/// One earlier turn relevant to some code, as the history tool returns it.
/// Every text field is already secret-masked.
public struct HistoryEntry: Sendable, Hashable, Codable {
    public var chatId: String
    public var chatName: String
    /// The turn's number within its chat, for `chat_excerpt`.
    public var turn: Int
    public var date: Date?
    public var ticket: String?
    public var pullRequest: Int?
    /// The one line that does the work: what this turn settled.
    public var decision: String?
    public var request: String?
    public var corrections: [String]
    public var summary: String?
    /// Line and review comments tied to the turn.
    public var review: [String]
    /// Why it's here: "lines", "file" or "folder".
    public var relevance: String

    public init(chatId: String, chatName: String, turn: Int, date: Date?, ticket: String?, pullRequest: Int?,
                decision: String?, request: String?, corrections: [String], summary: String?, review: [String],
                relevance: String) {
        self.chatId = chatId; self.chatName = chatName; self.turn = turn; self.date = date; self.ticket = ticket
        self.pullRequest = pullRequest; self.decision = decision; self.request = request; self.corrections = corrections
        self.summary = summary; self.review = review; self.relevance = relevance
    }

    init(_ record: TurnRecord, review: [String], relevance: String) {
        self.init(chatId: record.sessionId, chatName: SecretMasking.mask(record.chatName), turn: record.number,
                  date: record.endedAt ?? record.startedAt, ticket: record.ticket, pullRequest: record.pullRequest,
                  decision: SecretMasking.mask(record.decision ?? Self.derivedDecision(from: record.summary)),
                  request: SecretMasking.mask(record.request), corrections: record.corrections.map(SecretMasking.mask),
                  summary: SecretMasking.mask(record.summary), review: review.map(SecretMasking.mask),
                  relevance: relevance)
    }

    /// A turn recorded before decisions were kept: its summary's first
    /// line stands in.
    static func derivedDecision(from summary: String?) -> String? {
        guard let first = summary?.split(separator: "\n").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces), !first.isEmpty else { return nil }
        return first.count > 240 ? String(first.prefix(240)) + "…" : first
    }
}

/// Looks up earlier turns for one project, for the MCP server and
/// `abstract history`. Never returns another project's turns, a deleted
/// chat's, or the asking chat's own.
public struct CodeHistoryService: Sendable {
    public let store: Store
    public let projectId: String?
    /// The chat asking; nil from the command line.
    public let askingSessionId: String?
    /// Where `git blame` runs: the asking chat's worktree, else the root.
    public let repo: String

    public init(store: Store, projectId: String?, askingSessionId: String?, repo: String) {
        self.store = store; self.projectId = projectId; self.askingSessionId = askingSessionId; self.repo = repo
    }

    /// About 500 tokens: the size ABS-60 found enough.
    public static let textBudget = 2000
    /// A single conversation, read properly.
    public static let excerptBudget = 6000

    /// `path` as the agent spelled it, made relative to the repository;
    /// nil when it points outside it.
    public func relativePath(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/") {
            let root = GitText.trimTrailingSlashes(repo) + "/"
            guard trimmed.hasPrefix(root) else { return nil }
            return clean(String(trimmed.dropFirst(root.count)))
        }
        return clean(trimmed.hasPrefix("./") ? String(trimmed.dropFirst(2)) : trimmed)
    }

    private func clean(_ path: String) -> String? {
        guard !path.isEmpty, !path.hasPrefix("/"),
              !path.split(separator: "/").contains("..") else { return nil }
        return path
    }

    /// "225", "225-235" or "225:235"; nil when it doesn't read as lines.
    public static func lineRange(_ lines: String?) -> ClosedRange<Int>? {
        guard let raw = lines?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let parts = raw.components(separatedBy: CharacterSet(charactersIn: "-:–"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = Int(parts.first ?? ""), first > 0 else { return nil }
        if parts.count == 1 { return first...first }
        guard parts.count == 2, let last = Int(parts[1]), last >= first else { return nil }
        return first...last
    }

    /// The project's visible turns: other chats', never a deleted chat's.
    private func candidates() -> [TurnRecord] {
        let live = Set(((try? store.sessions()) ?? []).map(\.id))
        return ((try? store.turnRecords(projectId: projectId)) ?? [])
            .filter { live.contains($0.sessionId) && $0.sessionId != askingSessionId }
    }

    /// The history of `path` (and `lines` of it, when given): records
    /// about those lines first, then the file, then its folder, newest
    /// first within each.
    public func history(path: String, lines: ClosedRange<Int>?, exec: any Executor) async -> [HistoryEntry] {
        guard let relative = relativePath(path) else { return [] }
        let all = candidates()
        var lineTurns: Set<String> = []
        if let lines {
            let origins = (try? await TurnHistory(store: store, projectId: projectId)
                .blame(relative, lines: lines, exec: exec, repo: repo)) ?? []
            lineTurns = Set(origins.flatMap(\.turns).map(\.id))
        }
        let folder = (relative as NSString).deletingLastPathComponent
        func relevance(_ turn: TurnRecord) -> (rank: Int, name: String)? {
            if lineTurns.contains(turn.id) { return (0, "lines") }
            if turn.files.contains(relative) { return (1, "file") }
            if !folder.isEmpty, folder != ".", turn.files.contains(where: { $0.hasPrefix(folder + "/") }) { return (2, "folder") }
            return nil
        }
        // `candidates` is newest first; a stable group-by keeps that.
        var entries: [HistoryEntry] = []
        for rank in 0...2 {
            for turn in all {
                guard let found = relevance(turn), found.rank == rank else { continue }
                entries.append(entry(turn, relevance: found.name))
            }
        }
        return entries
    }

    /// More of one conversation: turn `number` of chat `chatId`.
    public func excerpt(chatId: String, turn number: Int) -> HistoryEntry? {
        guard chatId != askingSessionId,
              let record = candidates().first(where: { $0.sessionId == chatId && $0.number == number })
        else { return nil }
        return entry(record, relevance: "excerpt")
    }

    private func entry(_ record: TurnRecord, relevance: String) -> HistoryEntry {
        HistoryEntry(record, review: ((try? store.notes(turnId: record.id)) ?? []).map(\.body), relevance: relevance)
    }

    // MARK: Rendering for an agent

    /// The entries as text within `budget` characters: every record's
    /// heading and Decided line first, then what was asked, corrected,
    /// summarised and reviewed, added while they fit. The size limit
    /// drops fields before it drops records (ABS-60).
    public static func render(_ entries: [HistoryEntry], budget: Int = textBudget) -> String {
        guard !entries.isEmpty else { return "No earlier chat in this project has touched this code." }
        var blocks = entries.map { [heading($0)] + ($0.decision.map { ["Decided: \($0)"] } ?? []) }
        func fits(_ extra: Int) -> Bool {
            blocks.reduce(0) { $0 + $1.joined(separator: "\n").count + 2 } + extra <= budget
        }
        let fields: [(String, (HistoryEntry) -> [String])] = [
            ("You asked", { $0.request.map { [$0] } ?? [] }),
            ("You corrected", { $0.corrections }),
            ("Agent's summary", { $0.summary.map { [$0] } ?? [] }),
            ("Review", { $0.review }),
        ]
        for (label, values) in fields {
            for (index, entry) in entries.enumerated() {
                for value in values(entry) {
                    let line = "\(label): \(value)"
                    // A field longer than the whole budget is cut, not skipped.
                    let kept = line.count > budget ? String(line.prefix(max(budget - 1, 0))) + "…" : line
                    guard fits(kept.count + 1) else { continue }
                    blocks[index].append(kept)
                }
            }
        }
        var out = blocks.map { $0.joined(separator: "\n") }.joined(separator: "\n\n")
        if out.count > budget { out = String(out.prefix(max(budget - 1, 0))) + "…" }
        return out
    }

    static func heading(_ entry: HistoryEntry) -> String {
        var parts: [String] = []
        if let date = entry.date { parts.append(date.formatted(.iso8601.year().month().day())) }
        parts.append(entry.chatName)
        if let ticket = entry.ticket { parts.append(ticket) }
        if let pr = entry.pullRequest { parts.append("PR #\(pr)") }
        return "## " + parts.joined(separator: " · ") + " (chat \(entry.chatId), turn \(entry.turn))"
    }
}
