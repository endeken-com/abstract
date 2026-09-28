import Foundation
import Synchronization

/// What to do after a line from a helper process.
enum SideStep<Result: Sendable>: Sendable {
    case wait
    case send([String])
    case finish(Result)
    case fail(String)
}

extension SideStep: Equatable where Result: Equatable {}

/// An agent's short-lived helper (a server it runs beside the chat). Both
/// stdout and stderr reach `reply` line by line — a ready signal (like
/// OpenCode's listening line) can land on either — and stderr's last lines
/// also explain a failure.
enum SideProcess {
    /// Spawns `spec`, writes `opening`, and hands each output line to `reply`
    /// until it finishes or fails. The process is stopped however it ends:
    /// an answer, a failure, its exit, the timeout or cancellation.
    static func converse<R: Sendable>(_ executor: any Executor, _ spec: LaunchSpec, opening: [String] = [], timeout: Duration,
                                      reply: @escaping @Sendable (String) -> SideStep<R>) async throws -> R {
        try await run(executor, spec, opening: opening, timeout: timeout, keepRunning: false, reply: reply).0
    }

    /// Spawns `spec` and waits for the first output line `ready` accepts,
    /// leaving the process running for the caller to stop.
    static func start(_ executor: any Executor, _ spec: LaunchSpec, timeout: Duration,
                      until ready: @escaping @Sendable (String) -> Bool) async throws -> (line: String, process: any RunningProcess) {
        let (line, process) = try await run(executor, spec, opening: [], timeout: timeout, keepRunning: true) { line in
            ready(line) ? .finish(line) : .wait
        }
        guard let process else { throw AbstractError.message("\(Self.name(spec)) stopped before it was ready.") }
        return (line, process)
    }

    static func name(_ spec: LaunchSpec) -> String { (spec.command as NSString).lastPathComponent }

    private static func run<R: Sendable>(_ executor: any Executor, _ spec: LaunchSpec, opening: [String], timeout: Duration,
                                         keepRunning: Bool,
                                         reply: @escaping @Sendable (String) -> SideStep<R>) async throws -> (R, (any RunningProcess)?) {
        let gate = SideGate<R>(name: name(spec), keepRunning: keepRunning)
        let timer = Task {
            try await Task.sleep(for: timeout)
            gate.fail("\(gate.name) didn't answer in time.")
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard gate.arm(continuation) else { return }
                do {
                    let process = try executor.spawn(spec, onLine: { line in
                        if line.stream == .stderr { gate.noteStderr(line.line) }
                        switch reply(line.line) {
                        case .wait: break
                        case .send(let lines): gate.write(lines)
                        case .finish(let value): gate.finish(value)
                        case .fail(let message): gate.fail(message)
                        }
                    }, onExit: { code in gate.exited(code) })
                    gate.attach(process, opening: opening)
                } catch {
                    gate.fail(error)
                }
            }
        } onCancel: {
            gate.fail(CancellationError())
        }
    }
}

/// Ends a side conversation exactly once, from whichever of answer, failure,
/// exit, timeout or cancellation comes first, and stops the process unless
/// the caller keeps it.
private final class SideGate<R: Sendable>: Sendable {
    typealias Outcome = Result<(R, (any RunningProcess)?), any Error>

    private struct State {
        var continuation: CheckedContinuation<(R, (any RunningProcess)?), any Error>?
        var process: (any RunningProcess)?
        /// Lines to write once the process is attached.
        var pending: [String] = []
        var stderr: [String] = []
        var outcome: Outcome?
        /// A `keepRunning` `finish` that arrived before `attach` (the reader
        /// can see the ready line before `spawn` hands back the process):
        /// resolved once `attach` supplies the process to keep.
        var pendingFinish: R?
    }

    let name: String
    private let keepRunning: Bool
    private let state = Mutex(State())

    init(name: String, keepRunning: Bool) { self.name = name; self.keepRunning = keepRunning }

    /// false when it already ended (the timeout or cancellation beat the spawn).
    func arm(_ continuation: CheckedContinuation<(R, (any RunningProcess)?), any Error>) -> Bool {
        let early = state.withLock { s -> Outcome? in
            if let outcome = s.outcome { return outcome }
            s.continuation = continuation
            return nil
        }
        guard let early else { return true }
        continuation.resume(with: early)
        return false
    }

    private enum Landing {
        case alreadyEnded
        case resolves(CheckedContinuation<(R, (any RunningProcess)?), any Error>?, Outcome)
        case none
    }

    func attach(_ process: any RunningProcess, opening: [String]) {
        let landing = state.withLock { s -> Landing in
            if s.outcome != nil { return .alreadyEnded }
            s.process = process
            for line in opening + s.pending { try? process.write(line) }
            s.pending = []
            guard let value = s.pendingFinish else { return .none }
            s.pendingFinish = nil
            let result: Outcome = .success((value, process))
            s.outcome = result
            defer { s.continuation = nil }
            return .resolves(s.continuation, result)
        }
        switch landing {
        case .alreadyEnded: process.terminate()
        case .resolves(let continuation, let result): continuation?.resume(with: result)
        case .none: break
        }
    }

    func write(_ lines: [String]) {
        state.withLock { s in
            guard s.outcome == nil else { return }
            if let process = s.process { for line in lines { try? process.write(line) } } else { s.pending += lines }
        }
    }

    func noteStderr(_ line: String) {
        state.withLock { s in s.stderr = Array((s.stderr + [line]).suffix(5)) }
    }

    func finish(_ value: R) {
        // The reader can see a ready line before `spawn` returns and `attach`
        // runs: hold it rather than resolving with no process to keep.
        if keepRunning {
            let deferred = state.withLock { s -> Bool in
                guard s.outcome == nil, s.process == nil else { return false }
                s.pendingFinish = value
                return true
            }
            if deferred { return }
        }
        end { .success((value, $0)) }
    }
    func fail(_ message: String) { fail(AbstractError.message(message)) }
    func fail(_ error: any Error) { end { _ in .failure(error) } }

    func exited(_ code: Int32?) {
        let tail = state.withLock { $0.stderr.joined(separator: "\n") }
        fail("\(name) stopped (exit code \(code.map(String.init) ?? "?"))" + (tail.isEmpty ? "." : ": " + tail))
    }

    private func end(_ outcome: ((any RunningProcess)?) -> Outcome) {
        let ended = state.withLock { s -> (CheckedContinuation<(R, (any RunningProcess)?), any Error>?, Outcome, (any RunningProcess)?)? in
            guard s.outcome == nil else { return nil }
            let result = outcome(keepRunning ? s.process : nil)
            s.outcome = result
            defer { s.continuation = nil }
            return (s.continuation, result, s.process)
        }
        guard let (continuation, result, process) = ended else { return }
        if case .success = result, keepRunning {} else { process?.terminate() }
        continuation?.resume(with: result)
    }
}
