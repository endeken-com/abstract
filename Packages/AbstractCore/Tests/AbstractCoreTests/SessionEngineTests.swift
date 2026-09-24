import Foundation
import Testing
@testable import AbstractCore

@Suite("Session engine", .serialized)
struct SessionEngineTests {
    private func makeEngine() -> (SessionEngine, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("engine-\(UUID().uuidString)")
        return (SessionEngine(executor: LocalExecutor.shared, logDirectory: dir), dir)
    }

    private func collect(_ engine: SessionEngine, until: @escaping ([EngineEvent]) -> Bool, timeout: Double = 10) async -> [EngineEvent] {
        var seen: [EngineEvent] = []
        let deadline = Date().addingTimeInterval(timeout)
        for await e in engine.events {
            seen.append(e)
            if until(seen) || Date() > deadline { break }
        }
        return seen
    }

    @Test func whatYouSendIsLoggedInOrderWithTheOutput() async throws {
        let (engine, dir) = makeEngine()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        engine.recordInput(sessionId: "s1", text: "Add a test")
        try engine.launch(sessionId: "s1", spec: LaunchSpec(command: "/bin/sh", args: ["-c", "echo done"], cwd: dir.path, keepStdinOpen: false))
        _ = await collect(engine) { $0.contains { if case .exit = $0 { return true }; return false } }
        let replay = engine.replay(sessionId: "s1")
        #expect(replay.map(\.seq) == [1, 2])
        #expect(replay[0].line == OutputLine(stream: .user, line: "Add a test"))
        #expect(replay[1].line.line == "done")
    }

    @Test func aHandoffIsLoggedBetweenMessagesAndCounted() throws {
        let (engine, dir) = makeEngine()
        defer { try? FileManager.default.removeItem(at: dir) }
        engine.recordInput(sessionId: "s1", text: "first")
        let marker = HandoffMarker(phase: .handoff, from: "claude", to: "codex").line
        #expect(engine.record(sessionId: "s1", marker) == 2)
        engine.recordInput(sessionId: "s1", text: "second")
        #expect(engine.replay(sessionId: "s1").map(\.line) == [OutputLine(stream: .user, line: "first"), marker,
                                                                OutputLine(stream: .user, line: "second")])
        #expect(engine.logLength(sessionId: "s1") == 3)
    }

    @Test func streamsLogsAndReplaysInOrder() async throws {
        let (engine, dir) = makeEngine()
        defer { try? FileManager.default.removeItem(at: dir) }
        let spec = LaunchSpec(command: "/bin/sh", args: ["-c", "echo one; echo two; echo oops 1>&2; echo three"], cwd: dir.path, keepStdinOpen: false)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try engine.launch(sessionId: "s1", spec: spec)
        let events = await collect(engine) { $0.contains { if case .exit = $0 { return true }; return false } }

        let lines = events.compactMap { e -> (Int, OutputLine)? in if case let .line(_, seq, l) = e { return (seq, l) }; return nil }
        #expect(lines.filter { $0.1.stream == .stdout }.map(\.1.line) == ["one", "two", "three"])
        #expect(lines.contains { $0.1.stream == .stderr && $0.1.line == "oops" })
        #expect(Set(lines.map(\.0)).count == lines.count, "sequence numbers are unique")
        #expect(events.contains { if case let .exit(_, code) = $0 { return code == 0 }; return false })
        #expect(!engine.isAlive("s1"))

        let replay = engine.replay(sessionId: "s1")
        #expect(replay.count == lines.count)
        #expect(replay.map(\.seq) == Array(1...replay.count))
        #expect(engine.replay(sessionId: "s1", after: replay.count - 1).count == 1)
    }

    @Test func writesStdinToALiveProcessAndStopsIt() async throws {
        let (engine, dir) = makeEngine()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let spec = LaunchSpec(command: "/bin/sh", args: ["-c", "while read -r l; do echo \"got $l\"; done"], cwd: dir.path,
                              stdinInitial: "first\n", keepStdinOpen: true)
        try engine.launch(sessionId: "s2", spec: spec)
        #expect(engine.isAlive("s2"))
        try await Task.sleep(for: .milliseconds(200))
        try engine.write(sessionId: "s2", "second\n")
        var gotBoth = false
        for await e in engine.events {
            if case let .line(_, _, l) = e, l.line == "got second" { gotBoth = true; break }
        }
        #expect(gotBoth)
        engine.stop(sessionId: "s2")
        for await e in engine.events { if case .exit = e { break } }
        #expect(!engine.isAlive("s2"))
        #expect(throws: AbstractError.self) { try engine.write(sessionId: "s2", "late\n") }
    }

    @Test func relaunchingAppendsToTheLogInsteadOfOverwriting() async throws {
        let (engine, dir) = makeEngine()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for word in ["alpha", "beta"] {
            try engine.launch(sessionId: "s3", spec: LaunchSpec(command: "/bin/echo", args: [word], cwd: dir.path, keepStdinOpen: false))
            for await e in engine.events { if case .exit = e { break } }
        }
        #expect(engine.replay(sessionId: "s3").map(\.line.line) == ["alpha", "beta"])
    }

    @Test func aLogIsFollowedAWholeLineAtATime() throws {
        let (engine, dir) = makeEngine()
        defer { try? FileManager.default.removeItem(at: dir) }
        engine.recordInput(sessionId: "s4", text: "one")
        engine.recordInput(sessionId: "s4", text: "two")
        let first = engine.tail(sessionId: "s4", fromByte: 0, firstSeq: 1)
        #expect(first.lines.map(\.seq) == [1, 2])
        #expect(first.lines.map(\.line.line) == ["one", "two"])

        // Half a line (still being written) waits for the rest.
        let handle = try FileHandle(forWritingTo: dir.appendingPathComponent("s4.jsonl"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"stream":"user","li"#.utf8))
        #expect(engine.tail(sessionId: "s4", fromByte: first.end, firstSeq: 3).lines.isEmpty)
        try handle.write(contentsOf: Data(#"ne":"three"}"#.utf8 + [0x0A]))
        try handle.close()
        let next = engine.tail(sessionId: "s4", fromByte: first.end, firstSeq: 3)
        #expect(next.lines.map(\.seq) == [3])
        #expect(next.lines.map(\.line.line) == ["three"])
        #expect(engine.tail(sessionId: "s4", fromByte: next.end, firstSeq: 4).lines.isEmpty)
    }
}
