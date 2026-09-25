import Foundation
import Synchronization

/// A project's setup script, run in a new worktree before its agent starts,
/// so the agent never works in a checkout that is still installing.
public enum SetupScript {
    /// Runs `script` in `directory` through the user's shell, as a login
    /// and interactive shell like a terminal's, so it finds what the
    /// terminal would (nvm, pyenv). Each line of output goes to `onLine` as
    /// it comes, cleaned for reading. Returns the exit code; nil when a
    /// signal stopped it. Cancelling the calling task stops the script and
    /// everything it started.
    public static func run(_ script: String, in directory: String, executor: any Executor,
                           shell: String? = nil,
                           onLine: @escaping @Sendable (String) -> Void) async throws -> Int32? {
        let spec = LaunchSpec(command: shell ?? LoginShell.userShell(), args: ["-l", "-i", "-c", script], cwd: directory,
                              keepStdinOpen: false)
        let run = ScriptRun()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32?, any Error>) in
                run.begin(continuation)
                do {
                    let process = try executor.spawn(spec, onLine: { onLine(clean($0.line)) }, onExit: { run.exited($0) })
                    run.attach(process)
                } catch {
                    run.fail(error)
                }
            }
        } onCancel: {
            run.cancel()
        }
    }

    /// A line as a person reads it: colour and cursor codes removed, and of a
    /// line redrawn in place (a progress bar), only what it last showed.
    public static func clean(_ line: String) -> String {
        var text = line
        if text.hasSuffix("\r") { text.removeLast() }
        if let redraw = text.lastIndex(of: "\r") { text = String(text[text.index(after: redraw)...]) }
        return text.replacing(escapes, with: "")
    }

    /// CSI sequences (colours, cursor moves) and OSC ones (titles, links).
    nonisolated(unsafe) private static let escapes = /\u{1B}\[[0-?]*[ -\/]*[@-~]|\u{1B}\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\)|\u{1B}[@-Z\\-_]/
}

private final class ScriptRun: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Int32?, any Error>?
        var process: (any RunningProcess)?
        var cancelled = false
    }

    private let state = Mutex(State())

    func begin(_ continuation: CheckedContinuation<Int32?, any Error>) {
        state.withLock { $0.continuation = continuation }
    }

    /// Stops it at once if it was cancelled before it started.
    func attach(_ process: any RunningProcess) {
        let stop = state.withLock { s in
            s.process = process
            return s.cancelled
        }
        if stop { process.terminate() }
    }

    func cancel() {
        let process = state.withLock { s in
            s.cancelled = true
            return s.process
        }
        process?.terminate()
    }

    func exited(_ code: Int32?) {
        let (continuation, cancelled) = state.withLock { s in
            defer { s.continuation = nil }
            return (s.continuation, s.cancelled)
        }
        if cancelled { continuation?.resume(throwing: CancellationError()) } else { continuation?.resume(returning: code) }
    }

    func fail(_ error: any Error) {
        let continuation = state.withLock { s in
            defer { s.continuation = nil }
            return s.continuation
        }
        continuation?.resume(throwing: error)
    }
}
