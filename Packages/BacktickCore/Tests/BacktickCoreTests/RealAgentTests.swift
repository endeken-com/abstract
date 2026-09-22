import Foundation
import Testing
@testable import BacktickCore

/// Runs the real `claude` CLI through the engine and parser. Opt-in because it
/// needs the binary and a signed-in subscription:
///   BACKTICK_E2E=1 swift test --filter RealAgent
@Suite("Real agent", .serialized, .enabled(if: ProcessInfo.processInfo.environment["BACKTICK_E2E"] != nil))
struct RealAgentTests {
    @Test(.timeLimit(.minutes(3)))
    func claudeCompletesATurnInAWorktreeAndStaysAliveForFollowUps() async throws {
        let exec = LocalExecutor.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("real-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "t"]] {
            _ = try await exec.run("git", args, cwd: root.path)
        }
        try "hello\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        _ = try await exec.run("git", ["add", "-A"], cwd: root.path)
        _ = try await exec.run("git", ["commit", "-qm", "init"], cwd: root.path)

        let project = Project(name: "real", rootPath: root.path, defaultBaseRef: "main")
        let ws = try await Workspace.provision(executor: exec, project: project, name: "Create hi file",
                                               baseRef: "main", template: root.path + "-wt/{slug}", prefix: "backtick/")
        defer { try? FileManager.default.removeItem(atPath: root.path + "-wt") }

        let provider = ClaudeProvider()
        let spec = provider.buildLaunch(LaunchContext(cwd: ws.path, prompt: "Create a file named hi.txt containing the word hi. Then stop.",
                                                      permissionPolicy: .autoEdits))
        let engine = SessionEngine(executor: exec, logDirectory: root.appendingPathComponent("logs"))
        try engine.launch(sessionId: "real", spec: spec)

        let parser = provider.makeParser()
        var timeline = Timeline()
        var idle = false
        var raw: [String] = []
        for await event in engine.events {
            guard case let .line(_, _, line) = event else { break }
            for e in parser.feed(line.line, stream: line.stream) {
                timeline.append(e)
                if case .status(.idle, _) = e { idle = true }
                if case let .raw(l, s) = e, s == .stdout { raw.append(l) }
            }
            if idle { break }
        }
        #expect(idle, "the turn finished and the agent is waiting for a follow-up")
        #expect(engine.isAlive("real"), "stdin stays open so follow-ups reuse the process")
        #expect(FileManager.default.fileExists(atPath: ws.path + "/hi.txt"), "the agent worked inside its worktree")
        #expect(!FileManager.default.fileExists(atPath: root.path + "/hi.txt"), "the main working tree was not touched")
        #expect(raw.isEmpty, "every stdout frame was understood: \(raw.prefix(3))")

        let files = try await Diff.collect(exec, worktree: ws.path, exclude: [])
        #expect(files.contains { $0.path == "hi.txt" && $0.status == .added }, "the new file shows up for review")

        engine.stop(sessionId: "real")
        for await event in engine.events { if case .exit = event { break } }
        #expect(!engine.isAlive("real"))
    }
}
