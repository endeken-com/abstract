import Foundation
import Testing
@testable import AbstractCore

/// A message to a chat whose agent isn't running is numbered after its log,
/// without counting the whole log each time; a log written elsewhere since
/// is counted again (ABS-184).
@Suite struct SessionEngineLineCountTests {
    @Test func messagesAreNumberedAfterTheLog() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("count-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = SessionEngine(executor: LocalExecutor.shared, logDirectory: dir)
        let encoder = JSONEncoder()
        let log = SyntheticChats.log(lines: 500)
        let url = dir.appendingPathComponent("chat.jsonl")
        try (log.map { String(decoding: try! encoder.encode($0), as: UTF8.self) }.joined(separator: "\n") + "\n")
            .write(to: url, atomically: true, encoding: .utf8)
        #expect(engine.logLength(sessionId: "chat") == log.count)
        #expect(engine.record(sessionId: "chat", OutputLine(stream: .user, line: "one")) == log.count + 1)
        #expect(engine.record(sessionId: "chat", OutputLine(stream: .user, line: "two")) == log.count + 2)
        // Another process appends a line.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"stream\":\"note\",\"line\":\"elsewhere\"}\n".utf8))
        try handle.close()
        #expect(engine.record(sessionId: "chat", OutputLine(stream: .user, line: "three")) == log.count + 4)
        #expect(engine.replay(sessionId: "chat").last?.seq == log.count + 4)
    }

    @Test func newlinesAreCounted() {
        let text = Data("a\nbb\n\nccc".utf8)
        #expect(text.withUnsafeBytes(SessionEngine.newlines) == 3)
        #expect(Data().withUnsafeBytes(SessionEngine.newlines) == 0)
    }
}
