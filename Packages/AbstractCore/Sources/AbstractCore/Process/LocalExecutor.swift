import Darwin
import Dispatch
import Foundation
import Synchronization

/// Runs commands on this Mac.
///
/// A GUI app launched from Finder or the Dock does not inherit the user's
/// shell PATH, so `claude` (~/.local/bin) and `codex` (/opt/homebrew/bin)
/// would not be found. The login shell's PATH is resolved once per process
/// and used for every child and every command lookup.
public final class LocalExecutor: Executor, Sendable {
    public static let shared = LocalExecutor()

    public let homeDirectory: String
    /// Seconds between SIGTERM and SIGKILL in `RunningProcess.terminate()`.
    let killGrace: TimeInterval

    public init() {
        self.homeDirectory = LoginShell.userHomeDirectory()
        self.killGrace = 3
        LoginShell.prewarm()
    }

    /// The PATH every child gets (the login shell's, plus common tool dirs).
    public var searchPath: String { get async { await LoginShell.path() } }

    // MARK: Executor

    public func run(_ command: String, _ args: [String], cwd: String?) async throws -> ExecResult {
        let path = await LoginShell.path()
        guard let executable = Self.resolveExecutable(command, searchPath: path, home: homeDirectory, cwd: cwd) else {
            throw AbstractError.notFound(command)
        }
        var environment = Self.childEnvironment(path: path)
        // Keep git quiet and scriptable.
        environment["GIT_TERMINAL_PROMPT"] = "0"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true) }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let collector = RunCollector()
        let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ExecResult, any Error>) in
            collector.begin(continuation)
            // Both pipes drain concurrently, so a child filling one while we
            // wait on the other can never deadlock.
            for (output, kind) in [(stdout, OutputStreamKind.stdout), (stderr, .stderr)] {
                output.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        collector.finish(kind)
                    } else {
                        collector.append(data, kind)
                    }
                }
            }
            process.terminationHandler = { finished in
                // Killed by a signal: no exit code, like Rust's `status.code()`.
                collector.exited(finished.terminationReason == .exit ? finished.terminationStatus : -1)
            }
            do {
                try process.run()
            } catch {
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                collector.fail(AbstractError.message("failed to run `\(command)`: \(error.localizedDescription)"))
            }
        }
        withExtendedLifetime((process, stdout, stderr)) {}
        return result
    }

    public func spawn(
        _ spec: LaunchSpec,
        onLine: @escaping @Sendable (OutputLine) -> Void,
        onExit: @escaping @Sendable (Int32?) -> Void
    ) throws -> RunningProcess {
        var environment = Self.childEnvironment(path: LoginShell.blockingPath())
        for (key, value) in spec.env { environment[key] = value }
        guard let executable = Self.resolveExecutable(
            spec.command, searchPath: environment["PATH"] ?? "", home: homeDirectory, cwd: spec.cwd)
        else { throw AbstractError.notFound(spec.command) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: spec.cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AbstractError.message("failed to spawn `\(spec.command)`: working directory \(spec.cwd) does not exist")
        }

        // Own session and process group, so terminate() reaches the agent's
        // children and nothing can block on the launching terminal.
        let child = try Spawner.launch(
            executable: executable, arguments: [executable] + spec.args, environment: environment, cwd: spec.cwd,
            stdin: .pipe, stdout: .pipe, stderr: .pipe)
        let process = LocalProcess(child: child, killGrace: killGrace, onLine: onLine, onExit: onExit)
        process.start()

        // Agents that take no follow-up input (codex exec) block waiting on
        // stdin unless it is closed, so close it as soon as the initial
        // payload is written. Interactive agents keep it open.
        if let initial = spec.stdinInitial { try? process.write(initial) }
        if !spec.keepStdinOpen { process.closeStdin() }
        return process
    }

    public func fileExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    public func readFile(_ path: String) throws -> String {
        String(decoding: try Data(contentsOf: URL(fileURLWithPath: path)), as: UTF8.self)
    }

    public func createDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    /// Removes a file or directory tree. Already gone counts as success.
    public func removeItem(_ path: String) throws {
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            var info = Darwin.stat()
            if lstat(path, &info) != 0 && errno == ENOENT { return }
            throw error
        }
    }

    public func which(_ binary: String) async -> String? {
        Self.resolveExecutable(binary, searchPath: await LoginShell.path(), home: homeDirectory, cwd: nil)
    }

    // MARK: Helpers

    static func childEnvironment(path: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = path
        return environment
    }

    /// Absolute path of `name`: looked up on `searchPath` when bare, taken as
    /// a path (relative to `cwd`) when it contains a slash.
    static func resolveExecutable(_ name: String, searchPath: String, home: String, cwd: String?) -> String? {
        guard !name.isEmpty else { return nil }
        if name.contains("/") {
            var path = expandTilde(name, home: home)
            if !path.hasPrefix("/"), let cwd { path = GitText.trimTrailingSlashes(cwd) + "/" + path }
            return isExecutableFile(path) ? path : nil
        }
        for dir in searchPath.split(separator: ":") {
            let candidate = GitText.trimTrailingSlashes(expandTilde(String(dir), home: home)) + "/" + name
            if isExecutableFile(candidate) { return candidate }
        }
        return nil
    }

    private static func expandTilde(_ path: String, home: String) -> String {
        if path == "~" { return home }
        return path.hasPrefix("~/") ? home + path.dropFirst() : path
    }

    private static func isExecutableFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }
}

// MARK: - run() output collection

/// Gathers a `run` child's output and resumes the caller once the process
/// has exited and both pipes hit EOF.
private final class RunCollector: Sendable {
    private struct State {
        var continuation: CheckedContinuation<ExecResult, any Error>?
        var stdout = Data()
        var stderr = Data()
        var open: Set<OutputStreamKind> = [.stdout, .stderr]
        var code: Int32?
    }

    /// How long to wait for EOF after exit. A grandchild that inherited the
    /// pipes (a daemon the command started) must not hang the caller forever.
    private static let eofGrace: TimeInterval = 2
    private let state = Mutex(State())

    func begin(_ continuation: CheckedContinuation<ExecResult, any Error>) {
        state.withLock { $0.continuation = continuation }
    }

    func append(_ data: Data, _ kind: OutputStreamKind) {
        state.withLock { s in
            if kind == .stdout { s.stdout.append(data) } else { s.stderr.append(data) }
        }
    }

    func finish(_ kind: OutputStreamKind) {
        state.withLock { _ = $0.open.remove(kind) }
        complete(force: false)
    }

    func exited(_ code: Int32) {
        state.withLock { $0.code = code }
        complete(force: false)
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.eofGrace) { [self] in complete(force: true) }
    }

    func fail(_ error: any Error) {
        state.withLock { s in
            let continuation = s.continuation
            s.continuation = nil
            return continuation
        }?.resume(throwing: error)
    }

    private func complete(force: Bool) {
        let ready = state.withLock { s -> (CheckedContinuation<ExecResult, any Error>, ExecResult)? in
            guard let code = s.code, force || s.open.isEmpty, let continuation = s.continuation else { return nil }
            s.continuation = nil
            return (continuation, ExecResult(code: code, stdout: String(decoding: s.stdout, as: UTF8.self),
                                             stderr: String(decoding: s.stderr, as: UTF8.self)))
        }
        if let (continuation, result) = ready { continuation.resume(returning: result) }
    }
}

// MARK: - Streaming child

final class LocalProcess: RunningProcess, Sendable {
    let pid: Int32

    private struct State {
        var stdinFD: Int32
        var stdinOpen = true
        /// Set once the child is a zombie, before it is reaped, so a signal can
        /// never reach a recycled pid.
        var exited = false
        var terminating = false
        var exitCode: Int32?
        var exitSeen = false
        var reported = false
        var stdout = LineBuffer()
        var stderr = LineBuffer()
        var channels: [DispatchIO] = []

        mutating func withBuffer<R>(_ kind: OutputStreamKind, _ body: (inout LineBuffer) -> R) -> R {
            switch kind {
            case .stdout: body(&stdout)
            // A process only writes stdout and stderr; `.user` and `.handoff` are Abstract's own.
            case .stderr, .user, .handoff: body(&stderr)
            }
        }
    }

    /// How long output may keep flowing after exit before onExit fires anyway
    /// (a grandchild that inherited stdout must not keep the session open).
    private static let eofGrace: TimeInterval = 2
    /// How much longer to wait, past the grace, for output the child wrote
    /// before it exited but a busy machine hasn't read yet.
    private static let unreadGrace: TimeInterval = 20
    private let killGrace: TimeInterval
    private let stdoutFD: Int32
    private let stderrFD: Int32
    private let onLine: @Sendable (OutputLine) -> Void
    private let onExit: @Sendable (Int32?) -> Void
    /// Serialises every callback, so lines arrive in order and onExit last.
    private let queue: DispatchQueue
    /// Serialises stdin writes and the final close.
    private let stdinQueue: DispatchQueue
    private let state: Mutex<State>

    init(child: Spawner.Child, killGrace: TimeInterval,
         onLine: @escaping @Sendable (OutputLine) -> Void, onExit: @escaping @Sendable (Int32?) -> Void) {
        self.pid = child.pid
        self.stdoutFD = child.stdout
        self.stderrFD = child.stderr
        self.killGrace = killGrace
        self.onLine = onLine
        self.onExit = onExit
        self.queue = DispatchQueue(label: "dev.abstract.process.\(child.pid)")
        self.stdinQueue = DispatchQueue(label: "dev.abstract.process.\(child.pid).stdin")
        self.state = Mutex(State(stdinFD: child.stdin))
    }

    func start() {
        startReading(stdoutFD, .stdout)
        startReading(stderrFD, .stderr)
        Thread.detachNewThread { [self] in waitForExit() }
    }

    // MARK: RunningProcess

    func write(_ text: String) throws {
        let bytes = Array(text.utf8)
        let accepted = state.withLock { s in
            guard s.stdinOpen else { return false }
            // Enqueued under the lock so a concurrent closeStdin() lands after it.
            stdinQueue.async { [self] in writeAll(bytes) }
            return true
        }
        guard accepted else { throw AbstractError.message("stdin is closed") }
    }

    func closeStdin() {
        state.withLock { $0.stdinOpen = false }
        // After any pending writes, so the initial payload is never cut off.
        stdinQueue.async { [self] in closeStdinNow() }
    }

    func terminate() {
        let first = state.withLock { s in
            guard !s.exited, !s.terminating else { return false }
            s.terminating = true
            return true
        }
        guard first else { return }
        sendSignal(SIGTERM)
        queue.asyncAfter(deadline: .now() + killGrace) { [self] in sendSignal(SIGKILL) }
    }

    // MARK: Internals

    private func sendSignal(_ sig: Int32) {
        state.withLock { s in
            guard !s.exited else { return }
            // The whole group first (the agent's own children), the pid as a fallback.
            if kill(-pid, sig) != 0 { _ = kill(pid, sig) }
        }
    }

    private func writeAll(_ bytes: [UInt8]) {
        let fd = state.withLock { $0.stdinFD }
        guard fd >= 0 else { return }
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { buffer in
                Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
            }
            if n > 0 {
                offset += n
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                // EPIPE: the child is gone or closed its stdin.
                closeStdinNow()
                return
            }
        }
    }

    private func closeStdinNow() {
        let fd = state.withLock { s in
            let fd = s.stdinFD
            s.stdinFD = -1
            s.stdinOpen = false
            return fd
        }
        if fd >= 0 { close(fd) }
    }

    private func startReading(_ fd: Int32, _ kind: OutputStreamKind) {
        let channel = DispatchIO(type: .stream, fileDescriptor: fd, queue: queue) { _ in close(fd) }
        channel.setLimit(lowWater: 1)
        state.withLock { $0.channels.append(channel) }
        channel.read(offset: 0, length: Int.max, queue: queue) { [self] done, data, _ in
            consume(kind, data, done: done)
            if done { channel.close() }
        }
    }

    /// On `queue`.
    private func consume(_ kind: OutputStreamKind, _ data: DispatchData?, done: Bool) {
        let lines = state.withLock { s -> [String] in
            s.withBuffer(kind) { buffer in
                guard buffer.isOpen else { return [] }
                var lines: [String] = []
                data?.enumerateBytes { bytes, _, _ in lines += buffer.append(bytes) }
                if done, let last = buffer.finish() { lines.append(last) }
                return lines
            }
        }
        for line in lines { onLine(OutputLine(stream: kind, line: line)) }
        if done { reportIfFinished() }
    }

    private func waitForExit() {
        var info = siginfo_t()
        // Wait without reaping, mark exited, then reap: terminate() checks the
        // flag, so it cannot signal a pid the system has handed to someone else.
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == -1 && errno == EINTR {}
        state.withLock { $0.exited = true }
        var status: Int32 = 0
        var reaped: pid_t
        repeat { reaped = waitpid(pid, &status, 0) } while reaped == -1 && errno == EINTR
        let code: Int32? = reaped == pid && (status & 0x7f) == 0 ? (status >> 8) & 0xff : nil
        queue.async { [self] in processExited(code) }
    }

    /// On `queue`.
    private func processExited(_ code: Int32?) {
        state.withLock { s in
            s.exitCode = code
            s.exitSeen = true
            s.stdinOpen = false
        }
        stdinQueue.async { [self] in closeStdinNow() }
        reportIfFinished()
        let giveUp = Date().addingTimeInterval(Self.eofGrace + Self.unreadGrace)
        queue.asyncAfter(deadline: .now() + Self.eofGrace) { [self] in forceFinishOutput(giveUpAt: giveUp) }
    }

    /// Bytes waiting in a stream's pipe that nothing has read yet. Only asked
    /// while that stream is open, so its descriptor is still this process's.
    private func unread(_ kind: OutputStreamKind) -> Int32 {
        let fd = kind == .stdout ? stdoutFD : stderrFD
        guard fd >= 0, state.withLock({ s in s.withBuffer(kind) { $0.isOpen } }) else { return 0 }
        var count: Int32 = 0
        // FIONREAD (_IOR('f', 127, int)), which Swift doesn't import.
        let fionread: UInt = 0x4004_667F
        return withUnsafeMutablePointer(to: &count) { ioctl(fd, fionread, $0) } == 0 ? count : 0
    }

    /// On `queue`: stop waiting for EOF held up by a grandchild.
    private func forceFinishOutput(giveUpAt: Date) {
        // Output the child left in the pipe is still on its way, not a
        // grandchild's: wait for it (on a starved machine the reader lags).
        if Date() < giveUpAt, unread(.stdout) > 0 || unread(.stderr) > 0 {
            queue.asyncAfter(deadline: .now() + 0.1) { [self] in forceFinishOutput(giveUpAt: giveUpAt) }
            return
        }
        let (lines, channels) = state.withLock { s -> ([OutputLine], [DispatchIO]) in
            var lines: [OutputLine] = []
            for kind in [OutputStreamKind.stdout, .stderr] {
                s.withBuffer(kind) { buffer in
                    if buffer.isOpen, let last = buffer.finish() { lines.append(OutputLine(stream: kind, line: last)) }
                }
            }
            let channels = s.channels
            s.channels = []
            return (lines, channels)
        }
        for channel in channels { channel.close(flags: .stop) }
        for line in lines { onLine(line) }
        reportIfFinished()
    }

    /// On `queue`: onExit exactly once, after the process exited and all output was delivered.
    private func reportIfFinished() {
        let report = state.withLock { s -> Int32?? in
            guard s.exitSeen, !s.reported, !s.stdout.isOpen, !s.stderr.isOpen else { return nil }
            s.reported = true
            s.channels = []
            return .some(s.exitCode)
        }
        if let code = report { onExit(code) }
    }
}

/// Splits a byte stream into lines: `\n` or `\r\n` terminated, UTF-8 decoded
/// lossily, with the last partial line flushed at EOF.
struct LineBuffer {
    private(set) var isOpen = true
    private var pending: [UInt8] = []

    mutating func append(_ bytes: UnsafeBufferPointer<UInt8>) -> [String] {
        var lines: [String] = []
        var start = 0
        for i in 0..<bytes.count where bytes[i] == UInt8(ascii: "\n") {
            pending.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[start..<i]))
            lines.append(Self.decode(pending))
            pending.removeAll(keepingCapacity: true)
            start = i + 1
        }
        pending.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[start..<bytes.count]))
        return lines
    }

    /// Close the stream; returns the unterminated last line, if any.
    mutating func finish() -> String? {
        isOpen = false
        defer { pending = [] }
        return pending.isEmpty ? nil : Self.decode(pending)
    }

    private static func decode(_ line: [UInt8]) -> String {
        let body = line.last == UInt8(ascii: "\r") ? line.dropLast() : line[...]
        return String(decoding: body, as: UTF8.self)
    }
}

// MARK: - posix_spawn

enum Spawner {
    enum Stream { case null, pipe }

    struct Child: Sendable {
        let pid: pid_t
        /// Parent ends of the pipes; -1 when that stream is /dev/null.
        let stdin: Int32
        let stdout: Int32
        let stderr: Int32
    }

    /// Spawn in a new session (so also a new process group whose id is the
    /// child's pid), with signals reset to default and no inherited fds other
    /// than 0, 1 and 2, and those in `inherit` (the child's fd: this process's).
    static func launch(executable: String, arguments: [String], environment: [String: String], cwd: String?,
                       stdin: Stream, stdout: Stream, stderr: Stream, inherit: [Int32: Int32] = [:]) throws -> Child {
        var parentEnds: [Int32] = []
        var childEnds: [Int32] = []
        func closeAll() { (parentEnds + childEnds).forEach { _ = close($0) } }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }

        func wire(_ stream: Stream, target: Int32) throws -> Int32 {
            switch stream {
            case .null:
                posix_spawn_file_actions_addopen(&actions, target, "/dev/null", target == 0 ? O_RDONLY : O_WRONLY, 0)
                return -1
            case .pipe:
                var fds: [Int32] = [-1, -1]
                guard pipe(&fds) == 0 else { throw AbstractError.message("pipe: \(String(cString: strerror(errno)))") }
                // Never let one child inherit another child's pipe (the stdin
                // write end leaking would stop EOF from ever reaching it).
                let (readEnd, writeEnd) = (movedAboveStdio(fds[0]), movedAboveStdio(fds[1]))
                let (parent, child) = target == 0 ? (writeEnd, readEnd) : (readEnd, writeEnd)
                parentEnds.append(parent)
                childEnds.append(child)
                posix_spawn_file_actions_adddup2(&actions, child, target)
                return parent
            }
        }

        let stdinFD: Int32, stdoutFD: Int32, stderrFD: Int32
        do {
            stdinFD = try wire(stdin, target: 0)
            stdoutFD = try wire(stdout, target: 1)
            stderrFD = try wire(stderr, target: 2)
        } catch {
            closeAll()
            throw error
        }
        for (target, source) in inherit {
            // dup2 onto itself would keep close-on-exec set.
            if target == source { posix_spawn_file_actions_addinherit_np(&actions, source) }
            else { posix_spawn_file_actions_adddup2(&actions, source, target) }
        }
        if let cwd { posix_spawn_file_actions_addchdir_np(&actions, cwd) }

        posix_spawnattr_setflags(&attributes, Int16(
            POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var defaults = sigset_t()
        sigfillset(&defaults)
        sigdelset(&defaults, SIGKILL)
        sigdelset(&defaults, SIGSTOP)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)

        let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        childEnds.forEach { _ = close($0) }
        guard rc == 0 else {
            parentEnds.forEach { _ = close($0) }
            throw AbstractError.message("failed to spawn `\(executable)`: \(String(cString: strerror(rc)))")
        }
        // Writing to a dead child must fail with EPIPE, not kill the app.
        if stdinFD >= 0 { _ = fcntl(stdinFD, F_SETNOSIGPIPE, 1) }
        return Child(pid: pid, stdin: stdinFD, stdout: stdoutFD, stderr: stderrFD)
    }

    /// Close-on-exec, and never 0/1/2 (dup2 onto itself would keep CLOEXEC set).
    private static func movedAboveStdio(_ fd: Int32) -> Int32 {
        guard fd <= 2 else {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            return fd
        }
        let moved = fcntl(fd, F_DUPFD_CLOEXEC, 3)
        close(fd)
        return moved
    }
}

// MARK: - Login shell PATH

enum LoginShell {
    static let marker = "__ABSTRACT_LOGIN_PATH__"
    /// Heavy shell configs (nvm, conda) take a second or two; give up well after.
    static let timeout: TimeInterval = 5
    static let systemPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    private static let queue = DispatchQueue(label: "dev.abstract.login-shell", qos: .userInitiated)
    private static let cache = Mutex<String?>(nil)

    static func prewarm() {
        if cache.withLock({ $0 }) != nil { return }
        queue.async { _ = resolveOnQueue() }
    }

    /// Blocks the calling thread the first time (at most `timeout`).
    static func blockingPath() -> String {
        if let path = cache.withLock({ $0 }) { return path }
        return queue.sync { resolveOnQueue() }
    }

    static func path() async -> String {
        if let path = cache.withLock({ $0 }) { return path }
        return await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: resolveOnQueue()) }
        }
    }

    private static func resolveOnQueue() -> String {
        if let path = cache.withLock({ $0 }) { return path }
        let path = resolve()
        cache.withLock { $0 = path }
        return path
    }

    static func resolve() -> String {
        let environment = ProcessInfo.processInfo.environment
        let home = userHomeDirectory()
        let fromShell = capture(shell: userShell(environment), environment: environment, home: home)
        let base = fromShell ?? environment["PATH"].flatMap { $0.isEmpty ? nil : $0 } ?? systemPath
        return merge(base, extras: fallbackDirectories(home: home))
    }

    static func fallbackDirectories(home: String) -> [String] {
        ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.bun/bin", "\(home)/.cargo/bin"]
    }

    /// `path` followed by any `extras` it lacks, without duplicates.
    static func merge(_ path: String, extras: [String]) -> String {
        var seen = Set<String>()
        let parts = path.split(separator: ":").map(String.init) + extras
        return parts.filter { seen.insert($0).inserted }.joined(separator: ":")
    }

    /// The PATH printed between the markers; rc files may print noise around it.
    static func extract(_ output: String) -> String? {
        guard let (_, rest) = GitText.splitOnce(output, marker),
              let (path, _) = GitText.splitOnce(rest, marker) else { return nil }
        let trimmed = GitText.trimmed(path)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func userHomeDirectory() -> String {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            let home = String(cString: dir)
            if !home.isEmpty { return home }
        }
        return NSHomeDirectory()
    }

    static func userShell(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let shell = environment["SHELL"], !shell.isEmpty, FileManager.default.isExecutableFile(atPath: shell) {
            return shell
        }
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return "/bin/zsh"
    }

    /// Run `$SHELL -l -i -c 'printf …"$PATH"'` in its own session (an
    /// interactive shell sharing a terminal it does not own stops itself with
    /// SIGTTIN) and return the PATH, or nil on failure or timeout.
    private static func capture(shell: String, environment: [String: String], home: String) -> String? {
        let script = "printf '\(marker)%s\(marker)' \"$PATH\""
        guard let child = try? Spawner.launch(
            executable: shell, arguments: [shell, "-l", "-i", "-c", script], environment: environment,
            cwd: home, stdin: .null, stdout: .pipe, stderr: .null)
        else { return nil }
        defer { close(child.stdout) }

        let deadline = Date().addingTimeInterval(timeout)
        var output: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        var found: String?
        var timedOut = false
        while found == nil {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                timedOut = true
                break
            }
            var poller = pollfd(fd: child.stdout, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, Int32(min(remaining, 1) * 1000))
            if ready < 0 && errno == EINTR { continue }
            if ready <= 0 { continue }
            let n = buffer.withUnsafeMutableBytes { Darwin.read(child.stdout, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            output.append(contentsOf: buffer[0..<n])
            // Stop at the closing marker: a background job the rc file started
            // may hold stdout open long after the shell is done.
            found = extract(String(decoding: output, as: UTF8.self))
        }
        reap(child.pid, graceSeconds: timedOut ? 0 : 1)
        return found
    }

    private static func reap(_ pid: pid_t, graceSeconds: TimeInterval) {
        var status: Int32 = 0
        let deadline = Date().addingTimeInterval(graceSeconds)
        repeat {
            let r = waitpid(pid, &status, WNOHANG)
            if r == pid || (r == -1 && errno != EINTR) { return }
            usleep(20_000)
        } while Date() < deadline
        kill(-pid, SIGKILL)
        kill(pid, SIGKILL)
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
    }
}
