import Foundation
import Testing
@testable import AbstractCore

/// A long chat opens on its newest page, then the whole log takes its place
/// with every event in order (ABS-184).
@Suite struct TimelinePageTests {
    func engine(lines: [OutputLine]) throws -> (SessionEngine, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("page-\(UUID().uuidString)")
        let engine = SessionEngine(executor: LocalExecutor.shared, logDirectory: dir)
        let encoder = JSONEncoder()
        let text = lines.map { String(decoding: try! encoder.encode($0), as: UTF8.self) }.joined(separator: "\n") + "\n"
        try text.write(to: dir.appendingPathComponent("chat.jsonl"), atomically: true, encoding: .utf8)
        return (engine, dir)
    }

    func texts(_ timeline: Timeline) -> [String] {
        timeline.blocks.compactMap { block in
            switch block {
            case let .user(_, text): "you: \(text)"
            case let .assistant(_, text, _, _): text
            default: nil
            }
        }
    }

    @Test func theNewestPageShowsFirstThenTheWholeLogInOrder() throws {
        let log = SyntheticChats.log(lines: 1_000)
        let (engine, dir) = try engine(lines: log)
        defer { try? FileManager.default.removeItem(at: dir) }

        let page = try #require(TimelinePage.newest(engine: engine, sessionId: "chat", providerId: "claude", bytes: 16 << 10))
        let whole = TimelinePage.whole(engine: engine, sessionId: "chat", providerId: "claude")
        let pageTexts = texts(page), wholeTexts = texts(whole.timeline)
        // The page starts at a message of yours and is the end of the whole chat, as it reads.
        #expect(pageTexts.first?.hasPrefix("you: ") == true)
        #expect(pageTexts.count < wholeTexts.count / 4)
        #expect(Array(wholeTexts.suffix(pageTexts.count)) == pageTexts)
        // The whole log: every turn, first to last.
        #expect(wholeTexts == texts(ChatStream.timeline(log, currentProvider: "claude")))
        #expect(wholeTexts.first == "you: Fix the oauth callback, case 0.")
        #expect(whole.lastSeq == log.count)
    }

    @Test func aShortLogIsReadWhole() throws {
        let (engine, dir) = try engine(lines: SyntheticChats.log(lines: 30))
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(TimelinePage.newest(engine: engine, sessionId: "chat", providerId: "claude") == nil)
        #expect(TimelinePage.newest(engine: engine, sessionId: "missing", providerId: "claude") == nil)
    }

    @Test func whatIsLoggedAfterTheWholeReadCarriesOn() throws {
        let log = SyntheticChats.log(lines: 700)
        let (engine, dir) = try engine(lines: log)
        defer { try? FileManager.default.removeItem(at: dir) }
        let whole = TimelinePage.whole(engine: engine, sessionId: "chat", providerId: "claude")
        let more = SyntheticChats.turn(999, at: Date())
        for line in more { engine.record(sessionId: "chat", line) }
        let later = engine.tail(sessionId: "chat", fromByte: whole.end, firstSeq: whole.lastSeq + 1)
        #expect(later.lines.map(\.seq) == Array(whole.lastSeq + 1...whole.lastSeq + more.count))
        var timeline = whole.timeline
        for (_, line) in later.lines { timeline.append(contentsOf: whole.stream.feed(line), at: line.at) }
        let all = texts(timeline)
        #expect(all.contains("you: Fix the oauth callback, case 999."))
        #expect(all.last == "Fixed: the state is checked before the token refresh, with a test for case 999.")
        #expect(all.dropLast(3) == texts(whole.timeline)[...])
    }
}
