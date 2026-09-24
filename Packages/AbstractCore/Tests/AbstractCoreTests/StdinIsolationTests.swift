import Foundation
import Synchronization
import Testing
@testable import AbstractCore

/// One chat's agent finishing must never close another chat's stdin.
@Suite("Stdin isolation", .serialized)
struct StdinIsolationTests {
    @Test func aShortLivedClosedStdinProcessDoesNotCloseAWaitingProcessesStdin() async throws {
        let exec = LocalExecutor.shared
        let got = Mutex<[String]>([])
        let waiterExited = Mutex(false)

        // Like a claude chat parked on a permission prompt.
        let waiter = try exec.spawn(
            LaunchSpec(command: "/bin/sh", args: ["-c", "read -r x; echo \"read:[$x]\""], cwd: "/tmp", keepStdinOpen: true),
            onLine: { line in got.withLock { $0.append(line.line) } },
            onExit: { _ in waiterExited.withLock { $0 = true } }
        )

        // Like several codex turns starting and finishing meanwhile.
        for _ in 0..<5 {
            let done = Mutex(false)
            _ = try exec.spawn(
                LaunchSpec(command: "/bin/echo", args: ["turn"], cwd: "/tmp", keepStdinOpen: false),
                onLine: { _ in }, onExit: { _ in done.withLock { $0 = true } }
            )
            for _ in 0..<50 where !done.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(20)) }
            _ = try await exec.run("/usr/bin/true", [], cwd: nil)
        }
        try await Task.sleep(for: .seconds(2.5))
        #expect(!waiterExited.withLock { $0 }, "the waiting process must still be waiting; got \(got.withLock { $0 })")

        try waiter.write("answer\n")
        for _ in 0..<100 where !waiterExited.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(got.withLock { $0 } == ["read:[answer]"])
    }
}
