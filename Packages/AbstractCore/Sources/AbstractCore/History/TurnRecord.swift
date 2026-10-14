import Foundation
import GRDB

/// What one turn of a chat changed and why, kept after the chat is deleted,
/// so a commit or a line of code can be traced back to the conversation
/// that produced it. Saved by `TurnRecorder` as each turn ends.
public struct TurnRecord: Sendable, Hashable, Identifiable, Codable {
    public var id: String
    public var projectId: String?
    public var sessionId: String
    /// The chat's name when the turn ended.
    public var chatName: String
    public var providerId: String
    /// 1 for the chat's first recorded turn.
    public var number: Int
    public var startedAt: Date?
    public var endedAt: Date?
    /// Your message that started the turn; nil for one the agent took on its own.
    public var request: String?
    /// What you sent while it worked: usually corrections.
    public var corrections: [String]
    /// What the agent says it did: its turn summary, or its last reply cut short.
    public var summary: String?
    /// Paths relative to the worktree, sorted.
    public var files: [String]
    /// Those of `files` it left uncommitted, for the Commit button to claim.
    public var uncommitted: [String]
    /// `HEAD` when the turn started and ended: its commits are `headBefore..headAfter`.
    public var headBefore: String?
    public var headAfter: String?
    public var branch: String?
    public var pullRequest: Int?
    /// A ticket ID from the pull request (`Fixes ABS-62`) or the branch.
    public var ticket: String?
    /// The turn's lines in the chat's log, numbered from 1.
    public var logStart: Int
    public var logEnd: Int

    public init(id: String = UUID().uuidString, projectId: String?, sessionId: String, chatName: String, providerId: String,
                number: Int, startedAt: Date? = nil, endedAt: Date? = nil, request: String? = nil, corrections: [String] = [],
                summary: String? = nil, files: [String] = [], uncommitted: [String] = [], headBefore: String? = nil, headAfter: String? = nil,
                branch: String? = nil, pullRequest: Int? = nil, ticket: String? = nil, logStart: Int = 0, logEnd: Int = 0) {
        self.id = id; self.projectId = projectId; self.sessionId = sessionId; self.chatName = chatName
        self.providerId = providerId; self.number = number; self.startedAt = startedAt; self.endedAt = endedAt
        self.request = request; self.corrections = corrections; self.summary = summary; self.files = files
        self.uncommitted = uncommitted
        self.headBefore = headBefore; self.headAfter = headAfter; self.branch = branch; self.pullRequest = pullRequest
        self.ticket = ticket; self.logStart = logStart; self.logEnd = logEnd
    }
}

/// How a commit was tied to a turn.
public enum CommitLink: String, Sendable, Hashable, Codable, CaseIterable {
    /// Made during the turn: it's in `headBefore..headAfter`.
    case turn
    /// Made afterwards with the Commit button, holding files the turn touched.
    case commitButton = "commit_button"
    /// The merge of the chat's pull request, on its base branch.
    case merge
    /// A squash merge, found by the pull request number in its message.
    case squash
    /// A rebased or cherry-picked copy, found by its content (`git patch-id`).
    case patch
}

/// A commit tied to a turn.
public struct TurnCommit: Sendable, Hashable {
    public var sha: String
    public var turnId: String
    public var link: CommitLink
    /// `git patch-id --stable`, so a rebased copy finds its way back; nil for merges.
    public var patchId: String?

    public init(sha: String, turnId: String, link: CommitLink, patchId: String? = nil) {
        self.sha = sha; self.turnId = turnId; self.link = link; self.patchId = patchId
    }
}

/// A note about a line of code that went to an agent: a line comment from
/// Review or Files, or a pull request review comment. Tied to the turn it
/// led to once that turn is recorded.
public struct CodeNote: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable, Codable {
        case lineComment = "line_comment"
        case reviewComment = "review_comment"
    }

    public var id: String
    public var sessionId: String
    public var turnId: String?
    public var kind: Kind
    /// Relative to the repository.
    public var path: String
    public var line: Int?
    /// The commit the line was read at.
    public var commit: String?
    public var body: String
    public var author: String?
    public var createdAt: Date

    public init(id: String = UUID().uuidString, sessionId: String, turnId: String? = nil, kind: Kind, path: String,
                line: Int?, commit: String?, body: String, author: String? = nil, createdAt: Date = Date()) {
        self.id = id; self.sessionId = sessionId; self.turnId = turnId; self.kind = kind; self.path = path
        self.line = line; self.commit = commit; self.body = body; self.author = author; self.createdAt = createdAt
    }
}

// MARK: - Storing them

extension Store {
    /// Adds the record, or replaces the one with its id.
    public func save(_ turn: TurnRecord) throws {
        try writer.write { db in try TurnRow(turn).save(db) }
    }

    public func turnRecord(_ id: String) throws -> TurnRecord? {
        try writer.read { db in
            try TurnRow.fetchOne(db, sql: "SELECT * FROM turn_records WHERE id = ?", arguments: [id])?.value
        }
    }

    /// A chat's turns, first first.
    public func turnRecords(sessionId: String) throws -> [TurnRecord] {
        try writer.read { db in
            try TurnRow.fetchAll(db, sql: "SELECT * FROM turn_records WHERE session_id = ? ORDER BY number",
                                 arguments: [sessionId]).map(\.value)
        }
    }

    public func lastTurnRecord(sessionId: String) throws -> TurnRecord? {
        try writer.read { db in
            try TurnRow.fetchOne(db, sql: "SELECT * FROM turn_records WHERE session_id = ? ORDER BY number DESC LIMIT 1",
                                 arguments: [sessionId])?.value
        }
    }

    /// The turns of a project's chats that belong to pull request `number`.
    public func turnRecords(projectId: String?, pullRequest number: Int) throws -> [TurnRecord] {
        try writer.read { db in
            try TurnRow.fetchAll(db, sql: "SELECT * FROM turn_records WHERE project_id IS ? AND pull_request = ? ORDER BY ended_at, number",
                                 arguments: [projectId, number]).map(\.value)
        }
    }

    /// The turns of a project's chats on `branch`.
    public func turnRecords(projectId: String?, branch: String) throws -> [TurnRecord] {
        try writer.read { db in
            try TurnRow.fetchAll(db, sql: "SELECT * FROM turn_records WHERE project_id IS ? AND branch = ? ORDER BY ended_at, number",
                                 arguments: [projectId, branch]).map(\.value)
        }
    }

    /// Ties commits to turns; a pair already tied keeps its first link.
    public func link(_ commits: [TurnCommit]) throws {
        guard !commits.isEmpty else { return }
        try writer.write { db in
            for c in commits {
                try db.execute(sql: "INSERT OR IGNORE INTO turn_commits (sha, turn_id, link, patch_id) VALUES (?, ?, ?, ?)",
                               arguments: [c.sha, c.turnId, c.link.rawValue, c.patchId])
            }
        }
    }

    /// The commits tied to a turn.
    public func commits(turnId: String) throws -> [TurnCommit] {
        try writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM turn_commits WHERE turn_id = ? ORDER BY rowid", arguments: [turnId])
                .map(Self.turnCommit)
        }
    }

    /// The turns `sha` is tied to, and how, in the order they ended.
    public func turns(commit sha: String) throws -> [(turn: TurnRecord, link: CommitLink)] {
        try turns(where: "c.sha = ?", sha)
    }

    /// The turns of commits with this content, as `git patch-id` sees it.
    public func turns(patchId: String) throws -> [(turn: TurnRecord, link: CommitLink)] {
        try turns(where: "c.patch_id = ?", patchId)
    }

    private func turns(where clause: String, _ value: String) throws -> [(turn: TurnRecord, link: CommitLink)] {
        try writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT t.*, c.link AS commit_link FROM turn_commits c JOIN turn_records t ON t.id = c.turn_id
                WHERE \(clause) ORDER BY t.ended_at, t.number
                """, arguments: [value])
            var seen: Set<String> = []
            return try rows.compactMap { row in
                let turn = try TurnRow(row: row).value
                guard seen.insert(turn.id).inserted else { return nil }
                return (turn, CommitLink(rawValue: row["commit_link"]) ?? .turn)
            }
        }
    }

    /// Fills in the pull request (and the ticket, where none is known) of a
    /// chat's turns that don't have one yet. Returns how many changed.
    @discardableResult
    public func setPullRequest(_ number: Int, ticket: String?, sessionId: String) throws -> Int {
        try writer.write { db in
            try db.execute(sql: """
                UPDATE turn_records SET pull_request = ?, ticket = COALESCE(ticket, ?)
                WHERE session_id = ? AND pull_request IS NULL
                """, arguments: [number, ticket, sessionId])
            return db.changesCount
        }
    }

    // MARK: Notes

    public func save(_ note: CodeNote) throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO code_notes (id, session_id, turn_id, kind, path, line, commit_sha, body, author, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [note.id, note.sessionId, note.turnId, note.kind.rawValue, note.path, note.line, note.commit,
                                 note.body, note.author, note.createdAt])
        }
    }

    /// A chat's notes, oldest first.
    public func notes(sessionId: String) throws -> [CodeNote] {
        try notes(where: "session_id = ?", sessionId)
    }

    public func notes(turnId: String) throws -> [CodeNote] {
        try notes(where: "turn_id = ?", turnId)
    }

    /// The chat's notes not yet tied to a turn go to `turnId`: the turn they led to.
    public func attachPendingNotes(sessionId: String, to turnId: String) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE code_notes SET turn_id = ? WHERE session_id = ? AND turn_id IS NULL",
                           arguments: [turnId, sessionId])
        }
    }

    private func notes(where clause: String, _ value: String) throws -> [CodeNote] {
        try writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM code_notes WHERE \(clause) ORDER BY created_at, rowid", arguments: [value])
                .map { row in
                    CodeNote(id: row["id"], sessionId: row["session_id"], turnId: row["turn_id"],
                             kind: CodeNote.Kind(rawValue: row["kind"]) ?? .lineComment, path: row["path"], line: row["line"],
                             commit: row["commit_sha"], body: row["body"], author: row["author"], createdAt: row["created_at"])
                }
        }
    }

    private static func turnCommit(_ row: Row) -> TurnCommit {
        TurnCommit(sha: row["sha"], turnId: row["turn_id"], link: CommitLink(rawValue: row["link"]) ?? .turn,
                   patchId: row["patch_id"])
    }
}

private struct TurnRow: FetchableRecord, PersistableRecord {
    static let databaseTableName = "turn_records"
    let value: TurnRecord

    init(_ value: TurnRecord) { self.value = value }

    init(row: Row) throws {
        value = TurnRecord(
            id: try row.decode(forColumn: "id"),
            projectId: try row.decode(forColumn: "project_id"),
            sessionId: try row.decode(forColumn: "session_id"),
            chatName: try row.decode(forColumn: "chat_name"),
            providerId: try row.decode(forColumn: "provider_id"),
            number: try row.decode(forColumn: "number"),
            startedAt: try row.decode(forColumn: "started_at"),
            endedAt: try row.decode(forColumn: "ended_at"),
            request: try row.decode(forColumn: "request"),
            corrections: Self.list(try row.decode(forColumn: "corrections")),
            summary: try row.decode(forColumn: "summary"),
            files: Self.list(try row.decode(forColumn: "files")),
            uncommitted: Self.list(try row.decode(forColumn: "uncommitted")),
            headBefore: try row.decode(forColumn: "head_before"),
            headAfter: try row.decode(forColumn: "head_after"),
            branch: try row.decode(forColumn: "branch"),
            pullRequest: try row.decode(forColumn: "pull_request"),
            ticket: try row.decode(forColumn: "ticket"),
            logStart: try row.decode(forColumn: "log_start"),
            logEnd: try row.decode(forColumn: "log_end"))
    }

    func encode(to container: inout PersistenceContainer) throws {
        container["id"] = value.id
        container["project_id"] = value.projectId
        container["session_id"] = value.sessionId
        container["chat_name"] = value.chatName
        container["provider_id"] = value.providerId
        container["number"] = value.number
        container["started_at"] = value.startedAt
        container["ended_at"] = value.endedAt
        container["request"] = value.request
        container["corrections"] = Self.text(value.corrections)
        container["summary"] = value.summary
        container["files"] = Self.text(value.files)
        container["uncommitted"] = Self.text(value.uncommitted)
        container["head_before"] = value.headBefore
        container["head_after"] = value.headAfter
        container["branch"] = value.branch
        container["pull_request"] = value.pullRequest
        container["ticket"] = value.ticket
        container["log_start"] = value.logStart
        container["log_end"] = value.logEnd
    }

    static func list(_ text: String) -> [String] {
        (try? JSONDecoder().decode([String].self, from: Data(text.utf8))) ?? []
    }

    static func text(_ list: [String]) -> String {
        String(decoding: (try? JSONEncoder().encode(list)) ?? Data("[]".utf8), as: UTF8.self)
    }
}
