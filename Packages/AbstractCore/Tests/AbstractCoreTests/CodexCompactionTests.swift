import Foundation
import Testing
@testable import AbstractCore

@Suite("Codex compaction")
struct CodexCompactionTests {
    static func fixture() throws -> [String] {
        let url = try #require(Bundle.module.url(forResource: "codex-app-server-compact", withExtension: "jsonl", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    static func request(_ line: String) -> JSONValue? { try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) }

    @Test func opensWithInitialize() {
        let opening = CodexCompaction(threadId: "t-1").opening
        #expect(opening.count == 1)
        #expect(opening[0].hasSuffix("\n"))
        #expect(Self.request(opening[0])?["method"]?.string == "initialize")
        #expect(Self.request(opening[0])?["params"]?["clientInfo"]?["name"]?.string == "abstract")
    }

    @Test func resumesThenCompactsTheThread() throws {
        var c = CodexCompaction(threadId: "t-1")
        let lines = try Self.fixture()
        guard case let .send(afterInit) = c.receive(lines[0]) else { Issue.record("no reply to initialize"); return }
        #expect(afterInit.compactMap { Self.request($0)?["method"]?.string } == ["initialized", "thread/resume"])
        #expect(Self.request(afterInit[1])?["params"]?["threadId"]?.string == "t-1")
        #expect(c.receive(lines[1]) == .wait)
        guard case let .send(afterResume) = c.receive(lines[2]) else { Issue.record("no compact request"); return }
        #expect(Self.request(afterResume[0])?["method"]?.string == "thread/compact/start")
        #expect(Self.request(afterResume[0])?["params"]?["threadId"]?.string == "t-1")
    }

    @Test func finishesWithTheTokensBeforeAndAfter() throws {
        var c = CodexCompaction(threadId: "t-1")
        let steps = try Self.fixture().map { c.receive($0) }
        #expect(steps.contains(.finish(CompactionResult(tokensBefore: 17251, tokensAfter: 5546, contextWindow: 258_400))))
    }

    @Test func anErrorFailsWithItsMessage() {
        var c = CodexCompaction(threadId: "nope")
        #expect(c.receive(#"{"error":{"code":-32600,"message":"invalid thread id"},"id":2}"#) == .fail("Codex: invalid thread id"))
    }

    @Test func ignoresWhatIsntJSON() {
        var c = CodexCompaction(threadId: "t-1")
        #expect(c.receive("WARN something") == .wait)
    }

    @Test func codexCompactsThroughItsAppServer() {
        #expect(CodexProvider().commands.extra.contains(.compact))
        guard case .sideChannel(let compactor)? = CodexProvider().compaction else { Issue.record("no side channel"); return }
        #expect(compactor is CodexCompactor)
    }
}
