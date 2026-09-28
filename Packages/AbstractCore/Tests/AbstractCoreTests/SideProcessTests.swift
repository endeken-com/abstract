import Foundation
import Testing
@testable import AbstractCore

private func sh(_ script: String) -> LaunchSpec {
    LaunchSpec(command: "/bin/sh", args: ["-c", script], cwd: NSTemporaryDirectory(), keepStdinOpen: true)
}

@Suite("Side processes")
struct SideProcessTests {
    let executor = LocalExecutor.shared

    @Test func answersEachLineUntilItFinishes() async throws {
        // Echoes what it's sent; the conversation ends on the second echo.
        let answer: String = try await SideProcess.converse(executor, sh("while read l; do echo \"got $l\"; done"),
                                                            opening: ["one\n"], timeout: .seconds(10)) { line in
            line == "got one" ? .send(["two\n"]) : line == "got two" ? .finish("done") : .wait
        }
        #expect(answer == "done")
    }

    @Test func aFailureCarriesItsReason() async {
        await #expect(throws: AbstractError.message("nope")) {
            let _: Int = try await SideProcess.converse(self.executor, sh("echo hi; sleep 5"), timeout: .seconds(10)) { _ in .fail("nope") }
        }
    }

    @Test func exitingFirstSaysSoWithStderr() async {
        do {
            let _: Int = try await SideProcess.converse(executor, sh("echo broken >&2; exit 3"), timeout: .seconds(10)) { _ in .wait }
            Issue.record("should throw")
        } catch {
            #expect(error.localizedDescription.contains("exit code 3"))
            #expect(error.localizedDescription.contains("broken"))
        }
    }

    @Test func silenceTimesOut() async {
        do {
            let _: Int = try await SideProcess.converse(executor, sh("sleep 30"), timeout: .milliseconds(300)) { _ in .wait }
            Issue.record("should throw")
        } catch {
            #expect(error.localizedDescription.contains("didn't answer in time"))
        }
    }

    @Test func cancellingStopsTheProcess() async throws {
        let marker = NSTemporaryDirectory() + "side-\(UUID().uuidString)"
        let task = Task {
            let _: Int = try await SideProcess.converse(executor, sh("echo $$ > \(marker); sleep 30"), timeout: .seconds(60)) { _ in .wait }
        }
        try await Task.sleep(for: .milliseconds(500))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let pid = try #require(Int32(String(contentsOfFile: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        try await Task.sleep(for: .seconds(3)) // SIGTERM, then SIGKILL after the grace period.
        #expect(kill(pid, 0) != 0, "the process is gone")
    }

    @Test func startLeavesItRunning() async throws {
        let (line, process) = try await SideProcess.start(executor, sh("echo 'listening on http://127.0.0.1:4096'; sleep 30"),
                                                          timeout: .seconds(10)) { $0.contains("listening") }
        #expect(line.hasSuffix("4096"))
        #expect(kill(process.pid, 0) == 0)
        process.terminate()
    }
}
