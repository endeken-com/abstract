import Foundation
import GRDB
import Synchronization

/// An open chat as the chat feed sees it (ABS-217): never a path, a
/// branch, a worktree or anything about the repository.
public struct FeedChat: Sendable, Hashable {
    public var id: String
    public var title: String
    /// The project's name only.
    public var projectName: String?
    public var createdAt: Date
    public var updatedAt: Date
    /// Its agent is working: mid-turn, starting, or waiting on you.
    public var isActive: Bool

    public init(id: String, title: String, projectName: String?, createdAt: Date, updatedAt: Date, isActive: Bool) {
        self.id = id; self.title = title; self.projectName = projectName
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.isActive = isActive
    }
}

/// One message in a chat: what you typed, or what the agent wrote back.
/// Never a tool call, its output, a diff, a file, an attachment or an image.
public struct FeedMessage: Sendable, Hashable {
    public enum Author: String, Sendable, Hashable { case user = "usuario", agent = "agente" }
    public var author: Author
    /// When it was logged; nil in logs from before times were kept.
    public var at: Date?
    /// Unfiltered: the server runs `ChatFeedFilter` on it before it leaves.
    public var text: String

    public init(author: Author, at: Date?, text: String) { self.author = author; self.at = at; self.text = text }
}

/// Everything the chat feed can learn about chats. Read methods only, and
/// only about open chats: there is deliberately nothing here that writes,
/// sends or runs anything.
public protocol ChatFeedReader: Sendable {
    /// Open chats (not archived, not deleted, made on this Mac), newest first.
    func openChats() throws -> [FeedChat]
    /// One open chat; nil when it's archived, deleted or never existed.
    func openChat(_ id: String) throws -> FeedChat?
    /// An open chat's messages, oldest first; empty when it isn't open.
    func messages(chatId: String) throws -> [FeedMessage]
}

/// The chat feed's view of Abstract's database and chat logs. Its database
/// connection is opened read-only, so even a write that got this far would
/// fail at SQLite.
public final class ChatFeedStore: ChatFeedReader {
    let database: DatabaseQueue
    let logsURL: URL
    private let cache = Mutex<[String: (size: UInt64, modified: Date?, messages: [FeedMessage])]>([:])

    /// `databasePath`: an existing database, made by `Store`. `logsURL`:
    /// where the chats' `<id>.jsonl` logs are.
    public init(databasePath: String, logsURL: URL) throws {
        var config = Configuration()
        config.readonly = true
        config.busyMode = .timeout(5)
        config.label = "Abstract.ChatFeed"
        database = try DatabaseQueue(path: databasePath, configuration: config)
        self.logsURL = logsURL
    }

    /// The app's own database and logs, or `ABSTRACT_DATA_DIR`'s.
    public static func openDefault() throws -> ChatFeedStore {
        try ChatFeedStore(databasePath: Store.defaultPath(), logsURL: SessionEngine.defaultLogDirectory())
    }

    private static let activeStatuses = [SessionStatus.running, .provisioning, .waitingInput].map(\.rawValue)

    private static let selectOpen = """
        SELECT s.id, s.name, s.status, s.created_at, s.last_event_at, p.name AS project_name
        FROM sessions s LEFT JOIN projects p ON p.id = s.project_id
        -- Chats mirrored from another Mac live only in memory, as "remote:…";
        -- the guard keeps them out even if one ever got saved.
        WHERE s.archived_at IS NULL AND s.id NOT LIKE 'remote:%'
        """

    public func openChats() throws -> [FeedChat] {
        try database.read { db in
            try Row.fetchAll(db, sql: Self.selectOpen + " ORDER BY COALESCE(s.last_event_at, s.created_at) DESC")
                .map(Self.chat)
        }
    }

    public func openChat(_ id: String) throws -> FeedChat? {
        try database.read { db in
            try Row.fetchOne(db, sql: Self.selectOpen + " AND s.id = ?", arguments: [id]).map(Self.chat)
        }
    }

    private static func chat(_ row: Row) -> FeedChat {
        let created: Date = row["created_at"]
        let status: String = row["status"]
        return FeedChat(id: row["id"], title: row["name"], projectName: row["project_name"], createdAt: created,
                        updatedAt: row["last_event_at"] ?? created, isActive: activeStatuses.contains(status))
    }

    public func messages(chatId: String) throws -> [FeedMessage] {
        guard try openChat(chatId) != nil else { return [] }
        let provider = try database.read { db in
            try String.fetchOne(db, sql: "SELECT provider_id FROM sessions WHERE id = ?", arguments: [chatId])
        } ?? "claude"
        let url = logsURL.appendingPathComponent("\(chatId).jsonl", isDirectory: false)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = attributes?[.modificationDate] as? Date
        if let known = cache.withLock({ $0[chatId] }), known.size == size, known.modified == modified { return known.messages }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
        let decoder = JSONDecoder()
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true).compactMap {
            try? decoder.decode(OutputLine.self, from: Data($0))
        }
        let messages = Self.messages(in: lines, providerId: provider)
        cache.withLock { $0[chatId] = (size, modified, messages) }
        return messages
    }

    /// A log's messages: your text without its attachments, and the agent's
    /// written replies. Thinking, tool calls and everything else are left out.
    public static func messages(in lines: [OutputLine], providerId: String) -> [FeedMessage] {
        let stream = ChatStream(providerId: ChatStream.firstProvider(in: lines, current: providerId))
        return stream.replay(lines).entries.compactMap { entry in
            guard case let .text(role, text, _, _) = entry.event else { return nil }
            let body = (role == .user ? PromptAttachments.split(text).text : text)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return nil }
            return FeedMessage(author: role == .user ? .user : .agent, at: entry.at, text: body)
        }
    }
}
