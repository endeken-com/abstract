import Foundation
import Synchronization

/// What a time-limited command did.
public struct TimedResult: Sendable {
    /// nil when it was killed by a signal (including by the time limit).
    public var code: Int32?
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool

    public var ok: Bool { !timedOut && code == 0 }

    /// The last line it wrote to stderr, else stdout: why it failed, usually.
    public var lastLine: String? {
        for text in [stderr, stdout] {
            if let line = text.split(separator: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                return line.trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}

public extension Executor {
    /// Spawn `spec`, collect its output, and stop it (SIGTERM, then SIGKILL)
    /// once `timeout` has passed or the calling task is cancelled.
    func run(_ spec: LaunchSpec, timeout: Duration) async throws -> TimedResult {
        let run = TimedRunState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<TimedResult, any Error>) in
                run.begin(continuation)
                do {
                    let process = try spawn(spec, onLine: { run.append($0) }, onExit: { run.exited($0) })
                    run.attach(process)
                } catch {
                    run.fail(error)
                    return
                }
                let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { run.expire() }
            }
        } onCancel: {
            run.expire()
        }
    }
}

private final class TimedRunState: Sendable {
    private struct State {
        var continuation: CheckedContinuation<TimedResult, any Error>?
        var process: (any RunningProcess)?
        var stdout: [String] = []
        var stderr: [String] = []
        var timedOut = false
        var expireRequested = false
    }

    private let state = Mutex(State())

    func begin(_ continuation: CheckedContinuation<TimedResult, any Error>) {
        state.withLock { $0.continuation = continuation }
    }

    func attach(_ process: any RunningProcess) {
        let expireNow = state.withLock { s -> Bool in
            s.process = process
            return s.expireRequested && s.continuation != nil
        }
        if expireNow { process.terminate() }
    }

    func append(_ line: OutputLine) {
        state.withLock { s in
            if line.stream == .stdout { s.stdout.append(line.line) } else { s.stderr.append(line.line) }
        }
    }

    /// The time limit passed (or the caller gave up): stop the process. Its
    /// exit then reports the result.
    func expire() {
        let process = state.withLock { s -> (any RunningProcess)? in
            guard s.continuation != nil else { return nil }
            s.expireRequested = true
            s.timedOut = true
            return s.process
        }
        process?.terminate()
    }

    func exited(_ code: Int32?) {
        let done = state.withLock { s -> (CheckedContinuation<TimedResult, any Error>, TimedResult)? in
            guard let continuation = s.continuation else { return nil }
            s.continuation = nil
            s.process = nil
            return (continuation, TimedResult(code: code, stdout: s.stdout.joined(separator: "\n"),
                                              stderr: s.stderr.joined(separator: "\n"), timedOut: s.timedOut))
        }
        if let (continuation, result) = done { continuation.resume(returning: result) }
    }

    func fail(_ error: any Error) {
        let continuation = state.withLock { s -> CheckedContinuation<TimedResult, any Error>? in
            defer { s.continuation = nil }
            return s.continuation
        }
        continuation?.resume(throwing: error)
    }
}
