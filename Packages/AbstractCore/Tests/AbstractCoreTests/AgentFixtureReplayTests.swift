import Foundation
import Testing
@testable import AbstractCore

/// Every recorded agent fixture replayed through its bundled agent plugin
/// (ABS-185) gives, line for line, the events the Swift parser it replaced
/// gave. Those events were written down once from the Swift parsers before
/// they were deleted (`Fixtures/events/<fixture>.events.json`): on stdout and
/// on stderr, and at exit with 0, 1 and no code.
@Suite struct AgentFixtureReplayTests {
    static var fixtures: [String] {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/events")
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasSuffix(".events.json") }.map { String($0.dropLast(".events.json".count)) }.sorted()
    }

    static func golden(_ fixture: String) throws -> [String: JSONValue] {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/events/\(fixture).events", withExtension: "json"))
        return try #require(try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url)).object)
    }

    static func lines(_ name: String) throws -> [String] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    static func events(_ value: JSONValue?) -> [AgentEvent] {
        (value?.array ?? []).compactMap(AgentEventJSON.decode)
    }

    /// It hands its thread back now and then: CI runs tests on very few, and
    /// async tests elsewhere time out behind seconds of parsing.
    @Test(arguments: fixtures)
    func replaysAsTheSwiftParserDid(_ fixture: String) async throws {
        let agent = String(fixture.prefix { $0 != "-" })
        let plugin = try #require(AgentPlugins.shared.anyAgent(agent), "no bundled agent plugin for \(agent)")
        let lines = try Self.lines(fixture)
        let golden = try Self.golden(fixture)
        for stream in [OutputStreamKind.stdout, .stderr] {
            let expected = try #require(golden[stream.rawValue]?.array)
            #expect(expected.count == lines.count)
            let parser = plugin.makeParser()
            for (index, (line, want)) in zip(lines, expected).enumerated() {
                if index % 20 == 19 { await Task.yield() }
                #expect(parser.feed(line, stream: stream) == Self.events(want), "\(fixture) line \(index + 1) on \(stream)")
            }
            // Read in one batch, as a log is replayed, it's the same again.
            if stream == .stdout {
                let batch = plugin.makeParser().feed(lines: lines.map { OutputLine(stream: .stdout, line: $0) })
                #expect(batch == expected.map(Self.events), "\(fixture) as one batch")
            }
        }
        for key in ["0", "1", "null"] {
            let code: Int32? = key == "null" ? nil : Int32(key)
            #expect(plugin.makeParser().onExit(code: code) == Self.events(golden["exit:" + key]), "\(fixture) exit \(key)")
        }
    }

    @Test func everyAgentFixtureHasItsEvents() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        let recorded = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(".jsonl") && ["claude-", "codex-", "opencode-", "muse-"].contains(where: $0.hasPrefix) }
            .map { String($0.dropLast(".jsonl".count)) }.sorted()
        #expect(recorded == Self.fixtures)
        #expect(recorded.count >= 25)
    }
}
