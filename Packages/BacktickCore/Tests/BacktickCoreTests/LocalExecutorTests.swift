import Darwin
import Foundation
import Synchronization
import Testing
@testable import BacktickCore

/// Collects a spawned process's callbacks.
private final class Recorder: Sendable {
    private struct State {
        var lines: [OutputLine] = []
        var exits: [Int32?] = []
        var linesAtExit: Int?
    }

    private let state = Mutex(State())

    var lines: [OutputLine] { state.withLock { $0.lines } }
    var stdout: [String] { lines.filter { $0.stream == .stdout }.map(\.line) }
    var stderr: [String] { lines.filter { $0.stream == .stderr }.map(\.line) }
    var exitCount: Int { state.withLock { $0.exits.count } }
    /// How many lines had arrived when onExit fired.
    var linesAtExit: Int? { state.withLock { $0.linesAtExit } }

    func line(_ line: OutputLine) { state.withLock { $0.lines.append(line) } }

    func exit(_ code: Int32?) {
        state.withLock { s in
            s.exits.append(code)
            if s.linesAtExit == nil { s.linesAtExit = s.lines.count }
        }
    }

    /// `.some(code)` once onExit fired, nil on timeout.
    func waitForExit(timeout: Duration = .seconds(10)) async -> Int32?? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let first = state.withLock({ $0.exits.first }) { return .some(first) }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    func waitForLine(timeout: Duration = .seconds(10), _ match: (OutputLine) -> Bool) async -> OutputLine? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let line = lines.first(where: match) { return line }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }
}

@Suite struct LocalExecutorTests {
    let exec = LocalExecutor.shared

    private func spawn(_ command: String, _ args: [String], stdin: String? = nil, keepStdinOpen: Bool = false,
                       env: [String: String] = [:]) throws -> (RunningProcess, Recorder) {
        let recorder = Recorder()
        let spec = LaunchSpec(command: command, args: args, cwd: FileManager.default.temporaryDirectory.path,
                              env: env, stdinInitial: stdin, keepStdinOpen: keepStdinOpen)
        let process = try exec.spawn(spec, onLine: { recorder.line($0) }, onExit: { recorder.exit($0) })
        return (process, recorder)
    }

    // MARK: run

    @Test func runEcho() async throws {
        let out = try await exec.run("echo", ["hello", "world"], cwd: nil)
        #expect(out.ok)
        #expect(out.stdout == "hello world\n")
        #expect(out.stderr == "")
    }

    @Test func runReportsFailureAndStderr() async throws {
        let out = try await exec.run("sh", ["-c", "echo oops >&2; exit 3"], cwd: nil)
        #expect(out.code == 3)
        #expect(!out.ok)
        #expect(out.stderr == "oops\n")
    }

    @Test func runUsesCwdAndSetsGitTerminalPrompt() async throws {
        let resolved = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(resolved) }
        let dir = String(cString: resolved)
        let out = try await exec.run("sh", ["-c", "pwd -P; echo \"$GIT_TERMINAL_PROMPT\""], cwd: dir)
        #expect(out.stdout == "\(dir)\n0\n")
    }

    @Test(.timeLimit(.minutes(1)))
    func runLargeOutputOnBothStreamsDoesNotDeadlock() async throws {
        let out = try await exec.run("sh", ["-c", "seq 1 200000; seq 1 200000 >&2"], cwd: nil)
        #expect(out.ok)
        let lines = out.stdout.split(separator: "\n")
        #expect(lines.count == 200_000)
        #expect(lines.last == "200000")
        #expect(out.stderr.split(separator: "\n").count == 200_000)
    }

    @Test func runMissingCommandThrowsNotFound() async {
        await #expect(throws: BacktickError.notFound("backtick-no-such-binary")) {
            try await self.exec.run("backtick-no-such-binary", [], cwd: nil)
        }
    }

    // MARK: which / PATH

    @Test func whichResolvesAgainstTheLoginPath() async throws {
        let sh = try #require(await exec.which("sh"))
        #expect(sh.hasPrefix("/") && sh.hasSuffix("/sh"))
        #expect(await exec.which("/bin/sh") == "/bin/sh")
        #expect(await exec.which("backtick-no-such-binary") == nil)
        #expect(await exec.which("/tmp") == nil, "directories are not executables")
    }

    @Test func childPathIncludesTheUsualToolDirectories() async throws {
        let path = await exec.searchPath.split(separator: ":").map(String.init)
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "\(exec.homeDirectory)/.local/bin", "/usr/bin"] {
            #expect(path.contains(dir), "\(dir) missing from \(path)")
        }
        #expect(Set(path).count == path.count, "no duplicates")
        let out = try await exec.run("sh", ["-c", "printf %s \"$PATH\""], cwd: nil)
        #expect(out.stdout == path.joined(separator: ":"))
    }

    @Test func loginShellOutputIsExtractedFromNoise() {
        let m = LoginShell.marker
        #expect(LoginShell.extract("Last login: today\n\(m)/a:/b\(m)bye") == "/a:/b")
        #expect(LoginShell.extract("no markers") == nil)
        #expect(LoginShell.extract("\(m)\(m)") == nil)
        #expect(LoginShell.merge("/a:/b:/a", extras: ["/b", "/c"]) == "/a:/b:/c")
    }

    // MARK: spawn

    @Test func spawnStreamsLinesInOrderAndReportsExitCode() async throws {
        let script = "for i in 1 2 3 4 5; do echo line$i; done; echo warn >&2; printf 'a\\r\\nb\\n'; printf partial; exit 7"
        let (process, recorder) = try spawn("sh", ["-c", script])
        #expect(process.pid > 0)
        let code = try #require(await recorder.waitForExit())
        #expect(code == 7)
        #expect(recorder.stdout == ["line1", "line2", "line3", "line4", "line5", "a", "b", "partial"])
        #expect(recorder.stderr == ["warn"])
        #expect(recorder.linesAtExit == recorder.lines.count, "onExit comes after the last line")
        try await Task.sleep(for: .milliseconds(300))
        #expect(recorder.exitCount == 1, "onExit exactly once")
    }

    @Test func spawnDecodesInvalidUTF8Lossily() async throws {
        let (_, recorder) = try spawn("printf", ["\\377ok\\n"])
        #expect(try #require(await recorder.waitForExit()) == 0)
        #expect(recorder.stdout == ["\u{FFFD}ok"])
    }

    @Test func spawnPassesEnvironment() async throws {
        let (_, recorder) = try spawn("sh", ["-c", "echo \"$BACKTICK_TEST\""], env: ["BACKTICK_TEST": "hello"])
        #expect(try #require(await recorder.waitForExit()) == 0)
        #expect(recorder.stdout == ["hello"])
    }

    @Test(.timeLimit(.minutes(1)))
    func closedStdinLetsCatExit() async throws {
        // Without the close, `cat` (like `codex exec`) would wait for input forever.
        let (process, recorder) = try spawn("cat", [], stdin: "hello\nworld\n", keepStdinOpen: false)
        guard let code = await recorder.waitForExit(timeout: .seconds(10)) else {
            process.terminate()
            Issue.record("cat never exited: stdin was not closed")
            return
        }
        #expect(code == 0)
        #expect(recorder.stdout == ["hello", "world"])
        #expect(throws: BacktickError.self) { try process.write("late\n") }
    }

    @Test(.timeLimit(.minutes(1)))
    func openStdinTakesFollowUps() async throws {
        let (process, recorder) = try spawn("cat", [], stdin: "first\n", keepStdinOpen: true)
        #expect(await recorder.waitForLine { $0.line == "first" } != nil)
        try process.write("second\n")
        #expect(await recorder.waitForLine { $0.line == "second" } != nil)
        process.closeStdin()
        #expect(try #require(await recorder.waitForExit()) == 0)
        #expect(recorder.stdout == ["first", "second"])
    }

    @Test func spawnMissingBinaryThrowsNotFound() {
        #expect(throws: BacktickError.notFound("backtick-no-such-binary")) {
            _ = try self.spawn("backtick-no-such-binary", [])
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func terminateEndsSleep() async throws {
        let start = ContinuousClock.now
        let (process, recorder) = try spawn("sleep", ["30"])
        try await Task.sleep(for: .milliseconds(100))
        process.terminate()
        let code = try #require(await recorder.waitForExit(timeout: .seconds(5)))
        #expect(code == nil, "killed by a signal: no exit code")
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test(.timeLimit(.minutes(1)))
    func terminateReachesTheWholeProcessGroup() async throws {
        let (process, recorder) = try spawn("sh", ["-c", "sleep 30 & echo $!; wait"])
        let line = try #require(await recorder.waitForLine { _ in true })
        let grandchild = try #require(pid_t(line.line))
        #expect(kill(grandchild, 0) == 0, "grandchild is running")
        process.terminate()
        #expect(await recorder.waitForExit(timeout: .seconds(5)) != nil)
        let deadline = ContinuousClock.now + .seconds(5)
        while kill(grandchild, 0) == 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(kill(grandchild, 0) != 0, "the agent's child died with it")
    }

    @Test(.timeLimit(.minutes(1)))
    func terminateEscalatesToSIGKILL() async throws {
        let (process, recorder) = try spawn("sh", ["-c", "trap '' TERM; echo ready; while :; do sleep 0.1; done"])
        #expect(await recorder.waitForLine { $0.line == "ready" } != nil)
        let start = ContinuousClock.now
        process.terminate()
        let code = try #require(await recorder.waitForExit(timeout: .seconds(10)))
        let elapsed = ContinuousClock.now - start
        #expect(code == nil)
        #expect(elapsed >= .milliseconds(2500), "SIGTERM was ignored, so only SIGKILL ended it")
        #expect(elapsed < .seconds(8))
    }
}
