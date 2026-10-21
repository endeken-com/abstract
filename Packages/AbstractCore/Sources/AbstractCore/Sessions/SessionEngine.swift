import Foundation
import Synchronization

/// Raw output from a session's agent process, as the engine saw it.
public enum EngineEvent: Sendable {
    case line(sessionId: String, seq: Int, OutputLine)
    case exit(sessionId: String, code: Int32?)
}

/// Runs agent processes, one per session, and records everything they print.
///
/// The engine is provider-agnostic: it spawns a `LaunchSpec`, relays each
/// output line verbatim on `events`, appends it to the session's log for
/// replay, and writes whatever it is given to stdin.
public final class SessionEngine: Sendable {
    public let events: AsyncStream<EngineEvent>
    private let continuation: AsyncStream<EngineEvent>.Continuation
    private let executor: any Executor
    private let logDirectory: URL
    /// Where each session's raw output is kept, one `<id>.jsonl` per session.
    public var logsURL: URL { logDirectory }
    private let state = Mutex<[String: Running]>([:])
    /// Each chat's queued messages, read from beside its log when first asked for.
    private let queues = Mutex<[String: [QueuedMessage]]>([:])

    private struct Running: @unchecked Sendable {
        let process: RunningProcess
        /// The session's log, shared with `recordInput` so numbers stay in order.
        let writer: LogWriter
    }

    public init(executor: any Executor, logDirectory: URL) {
        self.executor = executor
        self.logDirectory = logDirectory
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    public static func defaultLogDirectory() -> URL {
        URL(fileURLWithPath: Store.defaultPath()).deletingLastPathComponent().appendingPathComponent("sessions", isDirectory: true)
    }

    public func isAlive(_ sessionId: String) -> Bool {
        state.withLock { $0[sessionId] != nil }
    }

    public var aliveSessionIds: Set<String> {
        state.withLock { Set($0.keys) }
    }

    /// Spawn the agent for a session. Sequence numbers continue from the log,
    /// so a resumed session appends rather than overwrites.
    public func launch(sessionId: String, spec: LaunchSpec, enricher: (any LineEnricher)? = nil) throws {
        if isAlive(sessionId) { throw AbstractError.message("This chat's agent is already running.") }
        let logURL = logFile(sessionId)
        let startSeq = lineCount(logURL)
        let writer = LogWriter(url: logURL, startingAt: startSeq)

        let process = try executor.spawn(
            spec,
            onLine: { [weak self] line in
                let line = Self.stamped(enricher?.enrich(line) ?? line)
                // The log is the single source of sequence numbers, so live
                // streaming and replay always agree.
                let n = writer.append(line)
                self?.continuation.yield(.line(sessionId: sessionId, seq: n, line))
            },
            onExit: { [weak self] code in
                guard let self else { return }
                _ = self.state.withLock { $0.removeValue(forKey: sessionId) }
                writer.close()
                self.continuation.yield(.exit(sessionId: sessionId, code: code))
            }
        )
        state.withLock { running in
            // A process that failed instantly has already exited; don't track it.
            if !writer.isClosed { running[sessionId] = Running(process: process, writer: writer) }
        }
    }

    public func write(sessionId: String, _ text: String) throws {
        let process = state.withLock { $0[sessionId]?.process }
        guard let process else { throw AbstractError.message("This chat's agent is not running.") }
        try process.write(text)
    }

    /// Logs what you sent the agent, numbered with its output, and reports
    /// it like any other line. `queued`: the queued messages it delivers,
    /// taken off the queue once logged. They're marked as sending first, so a
    /// relaunch in between finds them in the log rather than send them again.
    public func recordInput(sessionId: String, text: String, queued ids: [String] = []) {
        guard !ids.isEmpty else {
            record(sessionId: sessionId, OutputLine(stream: .user, line: text))
            return
        }
        markSending(sessionId: sessionId, ids)
        record(sessionId: sessionId, OutputLine(stream: .user, line: text, queued: ids))
        withQueue(sessionId) { $0.removeAll { ids.contains($0.id) } }
    }

    // MARK: Messages waiting for the turn to end

    /// The chat's queued messages, oldest first. Kept beside its log, so they
    /// survive a relaunch.
    public func queued(sessionId: String) -> [QueuedMessage] {
        withQueue(sessionId) { $0 }
    }

    public func enqueue(sessionId: String, _ message: QueuedMessage) {
        withQueue(sessionId) { $0.append(message) }
    }

    /// Marks queued messages as on their way: they can't be edited or
    /// removed any more. For a send that logs them later (a handover).
    public func markSending(sessionId: String, _ ids: [String]) {
        withQueue(sessionId) { queue in
            for i in queue.indices where ids.contains(queue[i].id) { queue[i].sending = true }
        }
    }

    /// Puts back messages the agent didn't get after all. One still queued
    /// waits again where it was; one already logged goes back to the front
    /// under a new id, as the log names its old one as sent.
    public func requeue(sessionId: String, _ messages: [QueuedMessage]) {
        withQueue(sessionId) { queue in
            var fresh: [QueuedMessage] = []
            for message in messages {
                if let i = queue.firstIndex(where: { $0.id == message.id }) { queue[i].sending = nil; continue }
                fresh.append(QueuedMessage(text: message.text, attachments: message.attachments, queuedAt: message.queuedAt))
            }
            queue.insert(contentsOf: fresh, at: 0)
        }
    }

    /// Returns false when the message has already gone.
    @discardableResult
    public func editQueued(sessionId: String, id: String, text: String) -> Bool {
        withQueue(sessionId) { queue in
            guard let i = queue.firstIndex(where: { $0.id == id && $0.sending != true }) else { return false }
            queue[i].text = text
            return true
        }
    }

    /// The message taken off the queue; nil when it has already gone.
    @discardableResult
    public func removeQueued(sessionId: String, id: String) -> QueuedMessage? {
        withQueue(sessionId) { queue in
            guard let i = queue.firstIndex(where: { $0.id == id && $0.sending != true }) else { return nil }
            return queue.remove(at: i)
        }
    }

    private func withQueue<T>(_ sessionId: String, _ body: (inout [QueuedMessage]) -> T) -> T {
        queues.withLock { all in
            var queue = all[sessionId] ?? loadQueue(sessionId)
            let before = queue
            let result = body(&queue)
            all[sessionId] = queue
            if queue != before { saveQueue(sessionId, queue) }
            return result
        }
    }

    /// Reads the queue kept beside the log. Messages a relaunch caught being
    /// sent are dropped when the log has them, and wait again when it doesn't.
    private func loadQueue(_ sessionId: String) -> [QueuedMessage] {
        guard let data = try? Data(contentsOf: queueFile(sessionId)),
              var queue = try? JSONDecoder().decode([QueuedMessage].self, from: data) else { return [] }
        guard queue.contains(where: { $0.sending == true }) else { return queue }
        let sent = Set(replay(sessionId: sessionId).flatMap { $0.line.stream == .user ? $0.line.queued ?? [] : [] })
        queue.removeAll { $0.sending == true && sent.contains($0.id) }
        for i in queue.indices { queue[i].sending = nil }
        saveQueue(sessionId, queue)
        return queue
    }

    private func saveQueue(_ sessionId: String, _ queue: [QueuedMessage]) {
        let url = queueFile(sessionId)
        guard !queue.isEmpty else { try? FileManager.default.removeItem(at: url); return }
        guard let data = try? JSONEncoder().encode(queue) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func queueFile(_ sessionId: String) -> URL {
        logDirectory.appendingPathComponent("\(sessionId).queue.json")
    }

    /// Logs a line of Abstract's own (what you sent, a handoff) and reports it
    /// like any other. Returns its number in the log.
    @discardableResult
    public func record(sessionId: String, _ line: OutputLine) -> Int {
        let line = Self.stamped(line)
        let writer = state.withLock { $0[sessionId]?.writer }
        let n: Int
        if let writer {
            n = writer.append(line)
        } else {
            let url = logFile(sessionId)
            let once = LogWriter(url: url, startingAt: lineCount(url))
            n = once.append(line)
            once.close()
        }
        continuation.yield(.line(sessionId: sessionId, seq: n, line))
        return n
    }

    /// Every logged line keeps when it was written, so a turn's length can be
    /// worked out again after a relaunch.
    private static func stamped(_ line: OutputLine) -> OutputLine {
        var line = line
        if line.at == nil { line.at = Date() }
        return line
    }

    /// Lines in the session's log so far.
    public func logLength(sessionId: String) -> Int {
        lineCount(logFile(sessionId))
    }

    public func stop(sessionId: String) {
        let process = state.withLock { $0[sessionId]?.process }
        process?.terminate()
    }

    public func stopAll() {
        let all = state.withLock { Array($0.values) }
        for r in all { r.process.terminate() }
    }

    /// Everything the session printed, oldest first, numbered from 1.
    public func replay(sessionId: String, after seq: Int = 0) -> [(seq: Int, line: OutputLine)] {
        guard let data = try? Data(contentsOf: logFile(sessionId)), let text = String(data: data, encoding: .utf8) else {
            return []
        }
        let decoder = JSONDecoder()
        var out: [(Int, OutputLine)] = []
        var n = 0
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            n += 1
            guard n > seq, let line = try? decoder.decode(OutputLine.self, from: Data(raw.utf8)) else { continue }
            out.append((n, line))
        }
        return out
    }

    /// A bounded page of complete log lines in chronological order. With no
    /// `beforeSeq`, select the newest page. A page is capped by line count and
    /// about 4 MiB of raw log data.
    /// The cursor is the first raw sequence in this page; malformed lines still
    /// occupy a sequence number so subsequent pages cannot overlap.
    public func replayPage(sessionId: String, beforeSeq: Int? = nil, limit: Int = 160)
        -> (lines: [(seq: Int, line: OutputLine)], beforeSeq: Int?, hasMore: Bool) {
        guard let data = try? Data(contentsOf: logFile(sessionId), options: .mappedIfSafe),
              let lastNewline = data.lastIndex(of: 0x0A) else { return ([], nil, false) }
        let complete = data[data.startIndex...lastNewline]
        let total = complete.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
        let end = min(total, max(0, (beforeSeq ?? total + 1) - 1))
        guard end > 0 else { return ([], nil, false) }
        let requestedStart = max(1, end - min(max(limit, 1), 256) + 1)
        let decoder = JSONDecoder()
        var ranges: [(seq: Int, bytes: Range<Data.Index>)] = []
        var pageBytes = 0
        var seq = 0
        var lineStart = complete.startIndex
        for position in complete.indices where complete[position] == 0x0A {
            seq += 1
            if seq < requestedStart { lineStart = complete.index(after: position); continue }
            if seq > end { break }
            let range = lineStart..<position
            ranges.append((seq, range))
            pageBytes += range.count
            while ranges.count > 1 && pageBytes > (4 << 20) {
                pageBytes -= ranges.removeFirst().bytes.count
            }
            lineStart = complete.index(after: position)
        }
        var lines: [(seq: Int, line: OutputLine)] = []
        for entry in ranges {
            if let line = try? decoder.decode(OutputLine.self, from: Data(complete[entry.bytes])) {
                lines.append((entry.seq, line))
            }
        }
        let start = ranges.first?.seq
        return (lines, start, (start ?? 1) > 1)
    }

    /// The log's whole lines from byte `offset` on, numbered from `firstSeq`
    /// (a line that doesn't decode keeps its number), and the byte after the
    /// last of them and its number. For following a log another process
    /// writes, a bit at a time.
    public func tail(sessionId: String, fromByte offset: UInt64,
                     firstSeq: Int) -> (lines: [(seq: Int, line: OutputLine)], end: UInt64, lastSeq: Int) {
        guard let handle = try? FileHandle(forReadingFrom: logFile(sessionId)) else { return ([], offset, firstSeq - 1) }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.readToEnd(),
              let last = data.lastIndex(of: 0x0A) else { return ([], offset, firstSeq - 1) }
        let decoder = JSONDecoder()
        var out: [(Int, OutputLine)] = []
        var n = firstSeq - 1
        for raw in data[data.startIndex...last].split(separator: 0x0A, omittingEmptySubsequences: true) {
            n += 1
            if let line = try? decoder.decode(OutputLine.self, from: Data(raw)) { out.append((n, line)) }
        }
        return (out, offset + UInt64(data.distance(from: data.startIndex, to: last) + 1), n)
    }

    public func deleteLog(sessionId: String) {
        try? FileManager.default.removeItem(at: logFile(sessionId))
        queues.withLock { _ = $0.removeValue(forKey: sessionId) }
        try? FileManager.default.removeItem(at: queueFile(sessionId))
    }

    private func logFile(_ sessionId: String) -> URL {
        logDirectory.appendingPathComponent("\(sessionId).jsonl")
    }

    private func lineCount(_ url: URL) -> Int {
        guard let data = try? Data(contentsOf: url) else { return 0 }
        return data.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
    }
}

/// Appends JSONL to a session log from the process's reader queue.
private final class LogWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: FileHandle?
    private(set) var count = 0
    private var closed = false
    var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }
    private let encoder = JSONEncoder()

    /// `startingAt`: lines already in the log, so numbers continue from them.
    init(url: URL, startingAt: Int) {
        count = startingAt
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    /// Returns the line's number in the log.
    func append(_ line: OutputLine) -> Int {
        lock.lock(); defer { lock.unlock() }
        guard let handle, var data = try? encoder.encode(line) else { return count }
        data.append(0x0A)
        try? handle.write(contentsOf: data)
        count += 1
        return count
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        try? handle?.close()
        handle = nil
        closed = true
    }
}
