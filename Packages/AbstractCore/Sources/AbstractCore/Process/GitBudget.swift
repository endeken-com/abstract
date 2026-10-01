import Darwin
import Foundation
import os
import Synchronization

/// The app-wide budget for git Abstract runs in the background: the reads
/// that keep its views up to date, which nobody asked for by clicking.
///
/// At most `maxRunning` run at once, and one per folder. Each is stopped
/// (its whole process group) once it runs past its time limit, or once nobody
/// is waiting for it any more. A read asked for while the same one is still
/// queued joins it instead of queueing another.
///
/// A last-resort guard sits on top: when `pauseAt` git processes Abstract
/// started are alive, whoever started them, no background read starts and the
/// oldest running one is stopped, until fewer than `resumeBelow` are left.
/// It is never expected to trigger; it is there so a future bug can't use up
/// the Mac's processes.
///
/// Actions you start (Commit, Push, Pull) don't go through it.
public final class GitBudget: Sendable {
    public struct Limits: Sendable {
        public var maxRunning: Int
        public var perFolder: Int
        public var readTimeout: Duration
        public var pauseAt: Int
        public var resumeBelow: Int
        /// How often a paused budget counts again.
        public var recheck: Duration

        public init(maxRunning: Int = 4, perFolder: Int = 1, readTimeout: Duration = .seconds(10),
                    pauseAt: Int = 32, resumeBelow: Int = 8, recheck: Duration = .seconds(1)) {
            self.maxRunning = maxRunning; self.perFolder = perFolder; self.readTimeout = readTimeout
            self.pauseAt = pauseAt; self.resumeBelow = resumeBelow; self.recheck = recheck
        }
    }

    public static let shared = GitBudget()

    public let limits: Limits
    private let census: @Sendable () -> Int
    private let log: @Sendable (String) -> Void
    private let state = Mutex(State())

    /// `census` counts the git processes alive that Abstract started; `log`
    /// defaults to the system log.
    public init(limits: Limits = Limits(), census: @escaping @Sendable () -> Int = { ProcessCensus.gitProcesses() },
                log: (@Sendable (String) -> Void)? = nil) {
        self.limits = limits; self.census = census
        self.log = log ?? { GitBudget.logger.notice("\($0, privacy: .public)") }
    }

    private static let logger = Logger(subsystem: "dev.abstract", category: "git")

    /// Background reads that are running, and waiting to.
    public var running: Int { state.withLock { $0.runningCount } }
    public var queued: Int { state.withLock { $0.queue.count } }
    /// Whether the guard has stopped background reads from starting.
    public var isPaused: Bool { state.withLock { $0.paused } }

    /// Runs `work` inside the budget, keyed by `folder`; `what` names it in
    /// the log and in the time-limit error. Given a `signature`, a call while
    /// a job with the same folder and signature is still queued gets that
    /// job's result (which must be a `T` too) instead of queueing its own.
    public func run<T: Sendable>(in folder: String, what: String, coalescing signature: [String]? = nil,
                                 timeout: Duration? = nil,
                                 _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let waiter = state.withLock { s in
            s.nextId += 1
            s.pending.insert(s.nextId)
            return s.nextId
        }
        let value = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<any Sendable, any Error>) in
                let accepted = state.withLock { s -> Bool in
                    s.pending.remove(waiter)
                    if s.cancelled.remove(waiter) != nil { return false }
                    let joined = signature.flatMap { signature in
                        s.queue.first { s.jobs[$0]?.folder == folder && s.jobs[$0]?.signature == signature }
                    }
                    let id: Int
                    if let joined {
                        id = joined
                    } else {
                        s.nextId += 1
                        id = s.nextId
                        s.jobs[id] = Job(folder: folder, what: what, signature: signature,
                                         timeout: timeout ?? limits.readTimeout, work: { try await work() })
                        s.queue.append(id)
                    }
                    s.jobs[id]?.waiters[waiter] = continuation
                    s.waiting[waiter] = id
                    return true
                }
                if accepted { pump() } else { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            abandon(waiter)
        }
        guard let result = value as? T else { throw AbstractError.message("\(what) answered with something unexpected") }
        return result
    }

    // MARK: Internals

    private struct Job {
        let folder: String
        let what: String
        let signature: [String]?
        let timeout: Duration
        let work: @Sendable () async throws -> any Sendable
        var waiters: [Int: CheckedContinuation<any Sendable, any Error>] = [:]
        var started: ContinuousClock.Instant?
        var task: Task<Void, Never>?
        var timer: Task<Void, Never>?
        /// Timed out, or nobody waits any more: its waiters have been answered
        /// and its task cancelled. It keeps its slot until the work ends.
        var stopped = false
    }

    private struct State {
        var nextId = 0
        /// Queued jobs, oldest first.
        var queue: [Int] = []
        var jobs: [Int: Job] = [:]
        /// Which job each waiter waits on.
        var waiting: [Int: Int] = [:]
        /// Waiters not registered yet, and those of them cancelled already.
        var pending: Set<Int> = []
        var cancelled: Set<Int> = []
        var paused = false
        var watching = false

        var runningCount: Int { jobs.values.count { $0.started != nil } }

        func startable(_ limits: Limits) -> Int? {
            let running = jobs.values.filter { $0.started != nil }
            guard running.count < limits.maxRunning else { return nil }
            return queue.first { id in
                let folder = jobs[id]?.folder
                return running.count { $0.folder == folder } < limits.perFolder
            }
        }

        /// The running job that started first and isn't stopped yet.
        var oldest: Int? {
            jobs.filter { $0.value.started != nil && !$0.value.stopped }
                .min { $0.value.started! < $1.value.started! }?.key
        }
    }

    private func abandon(_ waiter: Int) {
        let (continuation, task) = state.withLock { s -> (CheckedContinuation<any Sendable, any Error>?, Task<Void, Never>?) in
            guard let id = s.waiting.removeValue(forKey: waiter) else {
                if s.pending.contains(waiter) { s.cancelled.insert(waiter) }
                return (nil, nil)
            }
            let continuation = s.jobs[id]?.waiters.removeValue(forKey: waiter)
            guard let job = s.jobs[id], job.waiters.isEmpty else { return (continuation, nil) }
            if job.started == nil {
                s.jobs[id] = nil
                s.queue.removeAll { $0 == id }
                return (continuation, nil)
            }
            s.jobs[id]?.stopped = true
            return (continuation, job.task)
        }
        continuation?.resume(throwing: CancellationError())
        task?.cancel()
    }

    /// Starts what the limits allow.
    private func pump() {
        guard state.withLock({ !$0.paused && $0.startable(limits) != nil }) else { return }
        let alive = census()
        if alive >= limits.pauseAt {
            trip(alive)
            return
        }
        let starting = state.withLock { s -> [(Int, Job)] in
            var starting: [(Int, Job)] = []
            while !s.paused, let id = s.startable(limits) {
                s.queue.removeAll { $0 == id }
                s.jobs[id]?.started = .now
                if let job = s.jobs[id] { starting.append((id, job)) }
            }
            return starting
        }
        for (id, job) in starting { launch(id, job) }
    }

    private func launch(_ id: Int, _ job: Job) {
        let task = Task { [self] in
            let result: Result<any Sendable, any Error>
            do { result = .success(try await job.work()) } catch { result = .failure(error) }
            finish(id, result)
        }
        let timer = Task { [self] in
            try? await Task.sleep(for: job.timeout)
            if !Task.isCancelled { stop(id, because: TimeLimitExceeded(what: job.what, limit: job.timeout)) }
        }
        let (gone, stopped) = state.withLock { s -> (Bool, Bool) in
            guard s.jobs[id] != nil else { return (true, false) }
            s.jobs[id]?.task = task
            s.jobs[id]?.timer = timer
            return (false, s.jobs[id]?.stopped == true)
        }
        if gone { timer.cancel() } else if stopped { task.cancel() }
    }

    private func finish(_ id: Int, _ result: Result<any Sendable, any Error>) {
        let (waiters, timer) = state.withLock { s -> ([CheckedContinuation<any Sendable, any Error>], Task<Void, Never>?) in
            guard let job = s.jobs.removeValue(forKey: id) else { return ([], nil) }
            for waiter in job.waiters.keys { s.waiting[waiter] = nil }
            return (Array(job.waiters.values), job.timer)
        }
        timer?.cancel()
        for waiter in waiters { waiter.resume(with: result) }
        pump()
    }

    /// Answers a running job's waiters with `error` and cancels its work,
    /// which ends its processes.
    private func stop(_ id: Int, because error: any Error) {
        let stopped = state.withLock { s -> (Job, [CheckedContinuation<any Sendable, any Error>])? in
            guard let job = s.jobs[id], job.started != nil, !job.stopped else { return nil }
            for waiter in job.waiters.keys { s.waiting[waiter] = nil }
            s.jobs[id]?.waiters = [:]
            s.jobs[id]?.stopped = true
            return (job, Array(job.waiters.values))
        }
        guard let (job, waiters) = stopped else { return }
        log("Stopped \(job.what) in \(job.folder): \(error.localizedDescription)")
        job.task?.cancel()
        for waiter in waiters { waiter.resume(throwing: error) }
    }

    /// Too many git processes are alive: pause, and stop the oldest read.
    private func trip(_ alive: Int) {
        let (first, watch, oldest) = state.withLock { s -> (Bool, Bool, Int?) in
            let first = !s.paused, watch = !s.watching
            s.paused = true
            s.watching = true
            return (first, watch, s.oldest)
        }
        if first {
            log("\(alive) git processes are running, so background git is paused until fewer than \(limits.resumeBelow) are.")
        }
        if let oldest { stop(oldest, because: AbstractError.message("Stopped because too many git processes were running.")) }
        if watch { Task { [self] in await watchUntilClear() } }
    }

    private func watchUntilClear() async {
        while true {
            try? await Task.sleep(for: limits.recheck)
            let alive = census()
            if alive < limits.resumeBelow { break }
            if alive >= limits.pauseAt, let oldest = state.withLock({ $0.oldest }) {
                stop(oldest, because: AbstractError.message("Stopped because too many git processes were running."))
            }
        }
        state.withLock { s in
            s.paused = false
            s.watching = false
        }
        log("Background git resumed.")
        pump()
    }
}

/// A command that ran past its time limit and was stopped.
public struct TimeLimitExceeded: Error, LocalizedError, Sendable, Equatable {
    public var what: String
    public var limit: Duration

    public var errorDescription: String? { "\(what) took longer than \(limit.components.seconds) seconds and was stopped." }
}

/// `work`, cancelled once `limit` has passed, which then throws
/// `TimeLimitExceeded`. Returns only once `work` has ended.
public func withTimeLimit<T: Sendable>(_ limit: Duration, what: String,
                                       _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(for: limit)
            return nil
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw CancellationError() }
        guard let value = first else { throw TimeLimitExceeded(what: what, limit: limit) }
        return value
    }
}

/// `base`, with every `run` inside `budget`: the executor for git Abstract
/// runs in the background. Spawned processes and files are `base`'s own.
public struct BudgetedExecutor: Executor {
    public let base: any Executor
    public let budget: GitBudget

    public init(_ base: any Executor, budget: GitBudget = .shared) {
        self.base = base; self.budget = budget
    }

    public var homeDirectory: String { base.homeDirectory }

    public func run(_ command: String, _ args: [String], cwd: String?) async throws -> ExecResult {
        let what = "`" + ([command] + args.prefix(2)).joined(separator: " ") + "`"
        return try await budget.run(in: cwd ?? "", what: what, coalescing: [command] + args) { [base] in
            try await base.run(command, args, cwd: cwd)
        }
    }

    public func spawn(_ spec: LaunchSpec, onLine: @escaping @Sendable (OutputLine) -> Void,
                      onExit: @escaping @Sendable (Int32?) -> Void) throws -> RunningProcess {
        try base.spawn(spec, onLine: onLine, onExit: onExit)
    }
    public func fileExists(_ path: String) -> Bool { base.fileExists(path) }
    public func readFile(_ path: String) throws -> String { try base.readFile(path) }
    public func createDirectory(_ path: String) throws { try base.createDirectory(path) }
    public func removeItem(_ path: String) throws { try base.removeItem(path) }
    public func which(_ binary: String) async -> String? { await base.which(binary) }
    public func readData(_ path: String) async throws -> Data { try await base.readData(path) }
    public func writeData(_ data: Data, to path: String) async throws { try await base.writeData(data, to: path) }
    public func fileInfo(_ path: String) async -> FileInfo? { await base.fileInfo(path) }
}

/// Counts processes on this Mac.
public enum ProcessCensus {
    /// The git processes alive that this app started: its children named
    /// git, and every git below them. Git an agent runs is the agent's, not
    /// counted.
    public static func gitProcesses() -> Int {
        gitProcesses(in: snapshot(), root: getpid())
    }

    static func gitProcesses(in processes: [(pid: pid_t, parent: pid_t, name: String)], root: pid_t) -> Int {
        func isGit(_ name: String) -> Bool { name == "git" || name.hasPrefix("git-") }
        var children: [pid_t: [(pid: pid_t, name: String)]] = [:]
        for p in processes { children[p.parent, default: []].append((p.pid, p.name)) }
        var count = 0
        var stack = (children[root] ?? []).filter { isGit($0.name) }.map(\.pid)
        count += stack.count
        var seen = Set(stack)
        while let pid = stack.popLast() {
            for child in children[pid] ?? [] where seen.insert(child.pid).inserted {
                if isGit(child.name) { count += 1 }
                stack.append(child.pid)
            }
        }
        return count
    }

    /// Every process: its pid, its parent's, and its name.
    static func snapshot() -> [(pid: pid_t, parent: pid_t, name: String)] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        for _ in 0..<3 {
            var size = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else { return [] }
            // Room for processes started since.
            let stride = MemoryLayout<kinfo_proc>.stride
            var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 64)
            size = procs.count * stride
            if sysctl(&mib, u_int(mib.count), &procs, &size, nil, 0) != 0 {
                if errno == ENOMEM { continue }
                return []
            }
            return procs.prefix(size / stride).map { p in
                var comm = p.kp_proc.p_comm
                let name = withUnsafeBytes(of: &comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                return (p.kp_proc.p_pid, p.kp_eproc.e_ppid, name)
            }
        }
        return []
    }
}
