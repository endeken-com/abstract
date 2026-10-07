import Darwin
import Foundation
import Synchronization
import Testing
@testable import AbstractCore

/// Stands in for git: each run holds a "process" for `hold`, or until it is
/// cancelled (killed), and counts how many are alive at once.
private final class FakeGit: Executor {
    struct Counts {
        var live = 0
        var peak = 0
        var perFolder: [String: Int] = [:]
        var peakPerFolder = 0
        var started = 0
        var killed = 0
    }

    let hold: Duration?
    let firstRunGate: AsyncStream<Void>?
    let counts = Mutex(Counts())

    /// `hold` nil: never exits on its own.
    init(hold: Duration?, firstRunGate: AsyncStream<Void>? = nil) {
        self.hold = hold
        self.firstRunGate = firstRunGate
    }

    var homeDirectory: String { "/home/test" }

    func run(_ command: String, _ args: [String], cwd: String?) async throws -> ExecResult {
        let folder = cwd ?? ""
        let runNumber = counts.withLock { c in
            c.live += 1
            c.started += 1
            c.peak = max(c.peak, c.live)
            c.perFolder[folder, default: 0] += 1
            c.peakPerFolder = max(c.peakPerFolder, c.perFolder[folder]!)
            return c.started
        }
        defer { counts.withLock { $0.live -= 1; $0.perFolder[folder]! -= 1 } }
        do {
            if runNumber == 1, let firstRunGate {
                for await _ in firstRunGate { break }
            } else {
                try await Task.sleep(for: hold ?? .seconds(3600))
            }
        } catch {
            counts.withLock { $0.killed += 1 }
            throw error
        }
        return ExecResult(code: 0, stdout: args.joined(separator: " "), stderr: "")
    }

    func spawn(_ spec: LaunchSpec, onLine: @escaping @Sendable (OutputLine) -> Void,
               onExit: @escaping @Sendable (Int32?) -> Void) throws -> RunningProcess {
        throw AbstractError.message("not here")
    }
    func fileExists(_ path: String) -> Bool { false }
    func readFile(_ path: String) throws -> String { throw AbstractError.notFound(path) }
    func createDirectory(_ path: String) throws {}
    func removeItem(_ path: String) throws {}
    func which(_ binary: String) async -> String? { nil }

    func snapshot() -> Counts { counts.withLock { $0 } }
}

/// Waits up to `timeout` for `condition`.
private func eventually(_ timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

private func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno != ESRCH }

@Suite(.serialized) struct GitBudgetTests {
    private func budget(timeout: Duration = .seconds(10), census: @escaping @Sendable () -> Int = { 0 },
                        recheck: Duration = .milliseconds(20)) -> GitBudget {
        GitBudget(limits: .init(readTimeout: timeout, recheck: recheck), census: census, log: { _ in })
    }

    @Test(.timeLimit(.minutes(1)))
    func neverMoreThanFourAtOnceOrOnePerFolder() async throws {
        let git = FakeGit(hold: .milliseconds(20))
        let exec = BudgetedExecutor(git, budget: budget())
        try await withThrowingTaskGroup(of: ExecResult.self) { group in
            for i in 0..<40 {
                group.addTask { try await exec.run("git", ["status", "\(i)"], cwd: "/wt/\(i % 6)") }
            }
            for try await result in group { #expect(result.ok) }
        }
        let counts = git.snapshot()
        #expect(counts.started == 40)
        #expect(counts.peak <= 4)
        #expect(counts.peak > 1)
        #expect(counts.peakPerFolder == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func aReadAskedForWhileTheSameIsQueuedJoinsIt() async throws {
        let gate = AsyncStream<Void>.makeStream()
        let git = FakeGit(hold: .milliseconds(20), firstRunGate: gate.stream)
        let budget = budget()
        let exec = BudgetedExecutor(git, budget: budget)
        // The first holds the folder; the rest wait behind it, as one.
        try await withThrowingTaskGroup(of: ExecResult.self) { group in
            group.addTask { try await exec.run("git", ["status"], cwd: "/wt") }
            #expect(await eventually { git.snapshot().started == 1 })
            for _ in 0..<10 { group.addTask { try await exec.run("git", ["status"], cwd: "/wt") } }
            let allJoined = await eventually { budget.waiterCount == 11 }
            gate.continuation.yield(())
            gate.continuation.finish()
            #expect(allJoined)
            for try await result in group { #expect(result.stdout == "status") }
        }
        #expect(git.snapshot().started == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func aStuckReadIsStoppedAtItsTimeLimit() async throws {
        let git = FakeGit(hold: nil)
        let budget = budget(timeout: .milliseconds(100))
        let exec = BudgetedExecutor(git, budget: budget)
        let started = ContinuousClock.now
        await #expect(throws: TimeLimitExceeded.self) { try await exec.run("git", ["status"], cwd: "/wt") }
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(await eventually { git.snapshot().live == 0 && budget.running == 0 })
        #expect(git.snapshot().killed == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func aStuckGitProcessIsKilledAtItsTimeLimit() async throws {
        let dir = NSTemporaryDirectory() + "budget-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let local = LocalExecutor.shared
        _ = await local.searchPath
        let exec = BudgetedExecutor(local, budget: budget(timeout: .seconds(2)))
        // A git that never exits, and the shell it waits on.
        let alias = "alias.hang=!f() { echo $$ > \"\(dir)/pid\"; sleep 60; }; f"
        await #expect(throws: TimeLimitExceeded.self) {
            try await exec.run("git", ["-c", alias, "hang"], cwd: dir)
        }
        let pid = try #require(pid_t(GitText.trimmed(try String(contentsOfFile: dir + "/pid", encoding: .utf8))))
        #expect(await eventually { !isAlive(pid) })
    }

    @Test(.timeLimit(.minutes(1)))
    func aThousandTriggersAgainstAHungGitLeaveNothingBehind() async throws {
        let git = FakeGit(hold: nil)
        let budget = budget(timeout: .milliseconds(5))
        let exec = BudgetedExecutor(git, budget: budget)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<1000 {
                // Half of them repeats of a read that's waiting already.
                let args = i.isMultiple(of: 2) ? ["status"] : ["rev-list", "\(i)"]
                group.addTask { _ = try? await exec.run("git", args, cwd: "/wt/\(i % 10)") }
            }
        }
        let counts = git.snapshot()
        #expect(counts.peak <= 4)
        #expect(counts.peakPerFolder == 1)
        #expect(counts.started < 1000)
        #expect(await eventually { git.snapshot().live == 0 })
        #expect(budget.running == 0)
        #expect(budget.queued == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingTheCallerEndsItsRead() async throws {
        let git = FakeGit(hold: nil)
        let budget = budget()
        let exec = BudgetedExecutor(git, budget: budget)
        let running = Task { try await exec.run("git", ["status"], cwd: "/wt") }
        #expect(await eventually { git.snapshot().live == 1 })
        // Queued behind it, in the same folder.
        let waiting = Task { try await exec.run("git", ["diff"], cwd: "/wt") }
        #expect(await eventually { budget.queued == 1 })
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        #expect(budget.queued == 0)
        running.cancel()
        await #expect(throws: CancellationError.self) { try await running.value }
        #expect(await eventually { git.snapshot().live == 0 && budget.running == 0 })
        #expect(git.snapshot().started == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func oneCallerGivingUpDoesNotStopAJoinedRead() async throws {
        let git = FakeGit(hold: .milliseconds(200))
        let exec = BudgetedExecutor(git, budget: budget())
        let first = Task { try await exec.run("git", ["status"], cwd: "/wt") }
        #expect(await eventually { git.snapshot().live == 1 })
        let a = Task { try await exec.run("git", ["diff"], cwd: "/wt") }
        let b = Task { try await exec.run("git", ["diff"], cwd: "/wt") }
        try await Task.sleep(for: .milliseconds(20))
        a.cancel()
        #expect(try await b.value.stdout == "diff")
        _ = try await first.value
        #expect(git.snapshot().started == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func theGuardPausesAt32AndResumesUnder8() async throws {
        let alive = Mutex(0)
        let git = FakeGit(hold: nil)
        let budget = budget(census: { alive.withLock { $0 } })
        let exec = BudgetedExecutor(git, budget: budget)

        let oldest = Task { try await exec.run("git", ["status"], cwd: "/a") }
        #expect(await eventually { git.snapshot().live == 1 })

        alive.withLock { $0 = 32 }
        let held = Task { try await exec.run("git", ["status"], cwd: "/b") }
        // Paused: nothing new starts, and the oldest read is stopped.
        await #expect(throws: AbstractError.self) { try await oldest.value }
        #expect(budget.isPaused)
        #expect(await eventually { git.snapshot().live == 0 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(git.snapshot().started == 1)
        #expect(budget.queued == 1)

        // Still above 8: stays paused.
        alive.withLock { $0 = 8 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(budget.isPaused)

        alive.withLock { $0 = 7 }
        #expect(await eventually { !budget.isPaused && git.snapshot().live == 1 })
        held.cancel()
        _ = try? await held.value
    }

    @Test func theCensusCountsGitAbstractStartedNotAnAgents() {
        let me: pid_t = 100
        let table: [(pid: pid_t, parent: pid_t, name: String)] = [
            (100, 1, "Abstract"),
            (200, 100, "git"),            // a read
            (201, 200, "sh"),             // submodule foreach's shell
            (202, 201, "git"),            //   and its git
            (203, 202, "git-remote-https"),
            (300, 100, "claude"),         // an agent
            (301, 300, "git"),            //   and the agent's own git
            (400, 1, "git"),              // someone else's
        ]
        #expect(ProcessCensus.gitProcesses(in: table, root: me) == 3)
    }

    @Test(.timeLimit(.minutes(1)))
    func theCensusSeesALiveGit() async throws {
        let exec = LocalExecutor.shared
        let task = Task { try await exec.run("git", ["-c", "alias.hang=!sleep 30", "hang"], cwd: NSTemporaryDirectory()) }
        #expect(await eventually { ProcessCensus.gitProcesses() >= 1 })
        task.cancel()
        _ = try? await task.value
    }

    @Test func aTimeLimitReturnsTheResultInTime() async throws {
        #expect(try await withTimeLimit(.seconds(5), what: "quick") { 42 } == 42)
        await #expect(throws: TimeLimitExceeded(what: "slow", limit: .milliseconds(50))) {
            try await withTimeLimit(.milliseconds(50), what: "slow") { try await Task.sleep(for: .seconds(30)) }
        }
    }
}
