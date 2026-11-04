import Foundation
import Testing
@testable import AbstractCore

/// How fast the agent plugins read their agents' output (ABS-185). Each
/// fixture is read 3 times over, as one long log replayed (a batch call per
/// 512 lines, as `ChatStream` does) and line by line (as a live chat reads
/// it). Numbers go to standard error; docs/perf/ABS-185.md has them beside the
/// Swift parsers they replaced, measured before those were deleted. The bound
/// only catches a plugin gone badly wrong on a busy CI Mac.
///
/// Kept small: it runs beside every other suite, and seconds of synchronous
/// parsing on the shared thread pool starve the async tests around it. For
/// numbers, ABSTRACT_BENCH_REPEATS=40 swift test --filter AgentParseBenchmark.
@Suite(.serialized) struct AgentParseBenchmark {
    static let repeats = Int(ProcessInfo.processInfo.environment["ABSTRACT_BENCH_REPEATS"] ?? "") ?? 3

    static func seconds(_ body: () -> Void) -> Double {
        body() // warm up
        let start = ContinuousClock.now
        body()
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    @Test(arguments: ["claude", "codex", "opencode", "muse"])
    func pluginsReadTheirAgentsQuickly(_ agent: String) throws {
        let fixtures = AgentFixtureReplayTests.fixtures.filter { $0.hasPrefix(agent + "-") && $0 != "codex-app-server-compact" }
        let base = try fixtures.flatMap { try AgentFixtureReplayTests.lines($0).filter { !$0.isEmpty } }
        let lines = Array(repeating: base.map { OutputLine(stream: .stdout, line: $0) }, count: Self.repeats).flatMap { $0 }
        let plugin = try #require(AgentPlugins.shared.anyAgent(agent))
        let replay = Self.seconds {
            let parser = plugin.makeParser()
            var i = 0
            while i < lines.count {
                let end = min(i + ChatStream.batchLimit, lines.count)
                _ = parser.feed(lines: Array(lines[i..<end]))
                i = end
            }
        }
        let live = Self.seconds {
            let parser = plugin.makeParser()
            for line in lines { _ = parser.feed(line.line, stream: line.stream) }
        }
        let perHundred = { (s: Double) in s * 1000 / Double(lines.count) * 100 }
        FileHandle.standardError.write(Data(String(format: "BENCH %@: %d lines; per 100 lines replay %.3f ms, live %.3f ms\n",
                                                   agent, lines.count, perHundred(replay), perHundred(live)).utf8))
        #expect(perHundred(replay) < 100, "\(agent) replays at \(perHundred(replay)) ms per 100 lines")
    }
}
