import Foundation
import Testing
@testable import AbstractCore

/// How fast an agent plugin reads its agent's output against the Swift
/// parser it replaces (ABS-185). Each fixture is read 3 times over, as one
/// long log replayed (one batch call per 512 lines, as `ChatStream` does) and
/// line by line (as a live chat reads it). Numbers go to standard error and
/// docs/perf/ABS-185.md; the bound, against Swift measured alongside, is
/// loose enough for a busy CI Mac.
/// Kept small: it runs beside every other suite, and seconds of synchronous
/// parsing on the shared thread pool starve the async tests around it. For
/// numbers, ABSTRACT_BENCH_REPEATS=40 swift test --filter AgentParseBenchmark.
@Suite(.serialized) struct AgentParseBenchmark {
    static let repeats = Int(ProcessInfo.processInfo.environment["ABSTRACT_BENCH_REPEATS"] ?? "") ?? 3

    static func lines(_ fixtures: [String]) throws -> [OutputLine] {
        let lines = try fixtures.flatMap { try AgentPluginParityTests.lines($0).filter { !$0.isEmpty } }
        return Array(repeating: lines.map { OutputLine(stream: .stdout, line: $0) }, count: repeats).flatMap { $0 }
    }

    static func seconds(_ body: () -> Void) -> Double {
        body() // warm up
        let start = ContinuousClock.now
        body()
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    static func measure(_ agent: String, fixtures: [String], swift: @escaping () -> OutputParser) throws -> (swift: Double, batch: Double, live: Double, lines: Int) {
        let lines = try Self.lines(fixtures)
        let plugin = try #require(AgentPlugins.shared.anyAgent(agent))
        let swiftTime = seconds {
            let parser = swift()
            for line in lines { _ = parser.feed(line.line, stream: line.stream) }
        }
        let batchTime = seconds {
            let parser = plugin.makeParser()
            var i = 0
            while i < lines.count {
                let end = min(i + ChatStream.batchLimit, lines.count)
                _ = parser.feed(lines: Array(lines[i..<end]))
                i = end
            }
        }
        let liveTime = seconds {
            let parser = plugin.makeParser()
            for line in lines { _ = parser.feed(line.line, stream: line.stream) }
        }
        func perHundred(_ s: Double) -> String { String(format: "%.3f ms", s * 1000 / Double(lines.count) * 100) }
        let report = "BENCH \(agent): \(lines.count) lines; per 100 lines Swift \(perHundred(swiftTime)), "
            + "plugin replay \(perHundred(batchTime)), plugin live \(perHundred(liveTime)); "
            + String(format: "replay %.2f×, live %.2f× Swift\n", batchTime / swiftTime, liveTime / swiftTime)
        FileHandle.standardError.write(Data(report.utf8))
        return (swiftTime, batchTime, liveTime, lines.count)
    }

    @Test func openCodeParsesAboutAsFastAsSwift() throws {
        let r = try Self.measure("opencode", fixtures: ["opencode-messages", "opencode-mcp", "opencode-naming", "opencode-plugin-tool"],
                                 swift: { OpenCodeParser() })
        // Within 4× of Swift, measured side by side: a loaded Mac slows both.
        #expect(r.batch < r.swift * 4 + 0.05)
    }

    @Test func museParsesAboutAsFastAsSwift() throws {
        let fixtures = ["muse-serve-tools", "muse-serve-reasoning", "muse-serve-resume", "muse-echo-start", "muse-echo-resume",
                        "muse-wonder-start", "muse-wonder-resume", "muse-mock-tool", "muse-mock-failure", "muse-echo-naming"]
        let r = try Self.measure("muse", fixtures: fixtures, swift: { MuseParser() })
        #expect(r.batch < r.swift * 4 + 0.05)
    }
}
