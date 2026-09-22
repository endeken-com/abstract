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
    private let state = Mutex<[String: Running]>([:])

    private struct Running: @unchecked Sendable {
        let process: RunningProcess
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
    public func launch(sessionId: String, spec: LaunchSpec) throws {
        if isAlive(sessionId) { throw BacktickError.message("This chat's agent is already running.") }
        let logURL = logFile(sessionId)
        let startSeq = lineCount(logURL)
        let writer = LogWriter(url: logURL)

        let process = try executor.spawn(
            spec,
            onLine: { [weak self] line in
                // The log is the single source of sequence numbers, so live
                // streaming and replay always agree.
                let n = startSeq + writer.append(line)
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
            if !writer.isClosed { running[sessionId] = Running(process: process) }
        }
    }

    public func write(sessionId: String, _ text: String) throws {
        let process = state.withLock { $0[sessionId]?.process }
        guard let process else { throw BacktickError.message("This chat's agent is not running.") }
        try process.write(text)
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

    public func deleteLog(sessionId: String) {
        try? FileManager.default.removeItem(at: logFile(sessionId))
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

    init(url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    /// Returns the number of lines written by this writer so far.
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
