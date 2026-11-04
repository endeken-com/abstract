import Foundation

/// A chat's log read for its transcript in two steps (ABS-184), so a long
/// chat shows at once: its newest page, read from the end of the file, then
/// the whole log, read and replayed away from the main thread.
public enum TimelinePage {
    /// The whole log replayed, the stream that read it (to read what's
    /// logged after), where the log ended and the number of its last line.
    public struct Whole: @unchecked Sendable {
        public let timeline: Timeline
        public let stream: ChatStream
        public let end: UInt64
        public let lastSeq: Int
    }

    /// The newest lines of the chat's log, up to `bytes` of them, from its
    /// first message of yours in them so a turn isn't cut in half (from the
    /// first whole line when there's none). Nil when the whole log is no
    /// longer than that: read it whole. `providerId`: the agent writing now.
    public static func newest(engine: SessionEngine, sessionId: String, providerId: String,
                              bytes: Int = 256 << 10) -> Timeline? {
        guard let lines = engine.tailLines(sessionId: sessionId, maxBytes: bytes) else { return nil }
        let page = lines.firstIndex { $0.stream == .user }.map { Array(lines[$0...]) } ?? lines
        return ChatStream(providerId: ChatStream.firstProvider(in: page, current: providerId)).replay(page)
    }

    /// The whole log, as opening a chat always read it.
    public static func whole(engine: SessionEngine, sessionId: String, providerId: String) -> Whole {
        let (replay, end, lastSeq) = engine.tail(sessionId: sessionId, fromByte: 0, firstSeq: 1)
        let lines = replay.map(\.line)
        // Each agent's part of the log is read by its own parser.
        let stream = ChatStream(providerId: ChatStream.firstProvider(in: lines, current: providerId))
        return Whole(timeline: stream.replay(lines), stream: stream, end: end, lastSeq: lastSeq)
    }
}

extension SessionEngine {
    /// The whole lines in the last `maxBytes` of the chat's log, reading
    /// only those; nil when the log is no longer than that.
    public func tailLines(sessionId: String, maxBytes: Int) -> [OutputLine]? {
        let url = logsURL.appendingPathComponent("\(sessionId).jsonl", isDirectory: false)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > UInt64(maxBytes) else { return nil }
        guard (try? handle.seek(toOffset: size - UInt64(maxBytes))) != nil,
              let data = try? handle.readToEnd(), let last = data.lastIndex(of: 0x0A),
              // Starting mid-file, the first line is cut.
              let first = data.firstIndex(of: 0x0A), first < last else { return [] }
        let decoder = JSONDecoder()
        return data[data.index(after: first)...last].split(separator: 0x0A, omittingEmptySubsequences: true).compactMap {
            try? decoder.decode(OutputLine.self, from: Data($0))
        }
    }
}
