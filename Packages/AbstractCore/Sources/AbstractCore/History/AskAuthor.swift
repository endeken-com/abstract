import Foundation

/// Asking about some lines of code: who to ask (the chat that wrote them,
/// when it can still be opened, or a new chat), what the reply box or the
/// new chat's first message says, and the words Review and Chat use for
/// where a change came from and where a turn's work went.
public enum AskAuthor {
    /// Who gets the question about the lines.
    public enum Target: Sendable, Equatable {
        /// The chat whose turn wrote them. `canEdit` is false when its
        /// worktree is gone: it can still answer questions.
        case originalChat(turn: TurnRecord, archived: Bool, canEdit: Bool)
        /// No chat that can be opened wrote them.
        case newChat

        public var menuTitle: String {
            switch self {
            case .originalChat: "Ask the chat that wrote this…"
            case .newChat: "Ask a new chat about this…"
            }
        }
    }

    /// The chat to ask for turns that changed the lines (last last, as
    /// `TurnHistory.blame` returns them). `archived` says whether that
    /// chat is archived; nil means there is no such chat any more — it
    /// was deleted, or no turn is known — so a new chat is asked instead.
    public static func target(turns: [TurnRecord], archived: Bool?, worktreeExists: Bool) -> Target {
        guard let turn = turns.last, let archived else { return .newChat }
        return .originalChat(turn: turn, archived: archived, canEdit: worktreeExists)
    }

    /// What the reply box of the chat that wrote the lines starts with:
    /// the file, the lines quoted, the commit, and which turn wrote them.
    /// You add your question after it.
    public static func quote(path: String, lines: ClosedRange<Int>, code: [String],
                             commit: String?, turn: TurnRecord) -> String {
        var head = "About \(path) \(lineWords(lines))"
        if let commit { head += " (commit \(short(commit)))" }
        head += " — you wrote this in turn \(turn.number):"
        return head + "\n\n" + fenced(code) + "\n\n"
    }

    /// A new chat's first message about lines no openable chat wrote: the
    /// lines quoted, then what history knows about them.
    public static func newChatMessage(path: String, lines: ClosedRange<Int>, code: [String],
                                      origin: CommitOrigin?, deletedTurn: TurnRecord?) -> String {
        var parts = ["About \(path) \(lineWords(lines)):", fenced(code)]
        var history: [String] = []
        if let origin {
            history.append("Commit \(short(origin.sha)) by \(origin.author) — “\(origin.subject)”")
            if let pr = origin.pullRequest ?? deletedTurn?.pullRequest { history.append("pull request #\(pr)") }
        } else if let pr = deletedTurn?.pullRequest {
            history.append("Pull request #\(pr)")
        }
        if let deletedTurn {
            history.append("written in the chat “\(deletedTurn.chatName)”, turn \(deletedTurn.number), which has been deleted")
        }
        parts.append(history.isEmpty
            ? "No chat in Abstract wrote these lines, and they may not be committed yet."
            : "History: " + history.joined(separator: " · ") + ".")
        return parts.joined(separator: "\n\n") + "\n\n"
    }

    /// Each file's turns, from the origins of the commits a review shows:
    /// the turns that say they touched the file, in the order they ended,
    /// each once. Files no turn touched are left out.
    public static func fileTurns(origins: [CommitOrigin]) -> [String: [TurnRecord]] {
        var out: [String: [TurnRecord]] = [:]
        for origin in origins {
            for turn in origin.turns {
                for file in turn.files where !(out[file]?.contains { $0.id == turn.id } ?? false) {
                    out[file, default: []].append(turn)
                }
            }
        }
        return out
    }

    /// "Changed in <chat>, turn 3"; a file changed by more than one chat
    /// (or in more than one turn) lists each one.
    public static func changedIn(_ turns: [TurnRecord]) -> [String] {
        turns.map { "Changed in \($0.chatName), turn \($0.number)" }
    }

    /// The record of the turn a transcript's turn line ends: the one that
    /// started when it did, or, when the counts line up, the `ordinal`-th
    /// (0-based). The two can disagree for chats recorded before times
    /// were kept, so the start wins when both are known.
    public static func record(startedAt: Date?, ordinal: Int, in records: [TurnRecord], turnCount: Int) -> TurnRecord? {
        if let startedAt, let match = records.first(where: { $0.startedAt == startedAt }) { return match }
        if turnCount == records.count, records.indices.contains(ordinal) { return records[ordinal] }
        return nil
    }

    /// "Merged into main in #43", once the chat's pull request has merged.
    public static func mergedLine(_ pr: PullRequest?) -> String? {
        guard let pr, pr.state == .merged else { return nil }
        return "Merged into \(pr.base) in #\(pr.number)"
    }

    public static func short(_ sha: String) -> String { String(sha.prefix(7)) }

    private static func lineWords(_ lines: ClosedRange<Int>) -> String {
        lines.count == 1 ? "line \(lines.lowerBound)" : "lines \(lines.lowerBound)–\(lines.upperBound)"
    }

    private static func fenced(_ code: [String]) -> String {
        // A fence longer than any run of backticks in the code itself.
        let longest = code.map { line in line.split(separator: "`", omittingEmptySubsequences: false).count - 1 }.max() ?? 0
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return fence + "\n" + code.joined(separator: "\n") + "\n" + fence
    }
}
