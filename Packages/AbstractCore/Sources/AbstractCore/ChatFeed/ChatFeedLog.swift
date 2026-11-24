import Foundation
import Synchronization

/// The chat feed's call log (ABS-217): one JSON line per HTTP request, with
/// when, which tool, which chat, the result code and how long it took.
/// Never a query, a message, a title or the token. Rotated at 5 MB, keeping
/// one older file beside it.
public final class ChatFeedLog: Sendable {
    public struct Entry: Sendable, Hashable, Codable {
        public var time: Date
        /// The JSON-RPC method, only when it's one the feed knows.
        public var method: String?
        public var tool: String?
        public var chatId: String?
        /// The HTTP status.
        public var code: Int
        /// The tool answered with an error (a chat not found, a bad argument).
        public var toolError: Bool?
        public var ms: Int

        public init(time: Date, method: String? = nil, tool: String? = nil, chatId: String? = nil, code: Int,
                    toolError: Bool? = nil, ms: Int) {
            self.time = time; self.method = method; self.tool = tool; self.chatId = chatId
            self.code = code; self.toolError = toolError; self.ms = ms
        }

        enum CodingKeys: String, CodingKey {
            case time, method, tool, code, ms
            case chatId = "chat_id"
            case toolError = "tool_error"
        }
    }

    public let url: URL
    let maxBytes: UInt64
    private let lock = Mutex(())

    public init(url: URL, maxBytes: UInt64 = 5 << 20) {
        self.url = url
        self.maxBytes = maxBytes
    }

    /// `<data dir>/logs/chat-feed.log`: in the app,
    /// `~/Library/Application Support/Abstract/logs/chat-feed.log`.
    public static func defaultURL(dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent("logs", isDirectory: true).appendingPathComponent("chat-feed.log")
    }

    public var rotatedURL: URL { url.appendingPathExtension("1") }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public func append(_ entry: Entry) {
        guard var line = try? Self.encoder.encode(entry) else { return }
        line.append(0x0A)
        lock.withLock { _ in
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let size = ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value ?? 0
            if size > 0, size + UInt64(line.count) > maxBytes {
                try? fm.removeItem(at: rotatedURL)
                try? fm.moveItem(at: url, to: rotatedURL)
            }
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        }
    }

    /// The newest `limit` calls, newest first.
    public func recent(_ limit: Int = 20) -> [Entry] {
        lock.withLock { _ in
            var lines: [Substring] = []
            for file in [url, rotatedURL] {
                guard lines.count < limit, let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                lines += text.split(separator: "\n").reversed().prefix(limit - lines.count)
            }
            return lines.compactMap { try? Self.decoder.decode(Entry.self, from: Data($0.utf8)) }
        }
    }
}
