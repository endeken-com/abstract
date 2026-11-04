import Foundation
import Testing
@testable import AbstractCore

/// Today's provider fixtures replayed through the agent plugins (ABS-185):
/// every line gives the same events as the Swift parser it replaces.
@Suite struct AgentPluginParityTests {
    static func lines(_ name: String) throws -> [String] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// Lines no agent should trip on.
    static let oddLines = ["", "not json", "[]", "42", "null", #"{"type":7}"#, #"{"type":"tool_use","part":{"tool":"x"}}"#,
                           #"{"type":"text","part":"oops"}"#, #"{"type":"step_finish","part":{"tokens":{"input":"many"}}}"#,
                           #"{"type":"tool_use","part":{"tool":"read","callID":"c","state":{"status":"error","input":null,"error":"no"}}}"#]

    static func plugin(_ id: String) throws -> any ProviderDefinition {
        let provider = try #require(AgentPlugins.shared.anyAgent(id))
        return provider
    }

    func expectSameEvents(swift: () -> OutputParser, plugin: () -> OutputParser, lines: [String],
                          sourceLocation: SourceLocation = #_sourceLocation) {
        for stream in [OutputStreamKind.stdout, .stderr] {
            let a = swift(), b = plugin()
            for (index, line) in lines.enumerated() {
                let expected = a.feed(line, stream: stream), actual = b.feed(line, stream: stream)
                #expect(actual == expected, "line \(index + 1) on \(stream)", sourceLocation: sourceLocation)
            }
            for code in [Int32(0), 1, nil] as [Int32?] {
                #expect(b.onExit(code: code) == a.onExit(code: code), "exit \(String(describing: code))", sourceLocation: sourceLocation)
            }
        }
        // A batch reads the same as line by line.
        let one = plugin(), many = plugin()
        let batched = many.feed(lines: lines.map { OutputLine(stream: .stdout, line: $0) })
        #expect(batched == lines.map { one.feed($0, stream: .stdout) }, sourceLocation: sourceLocation)
    }

    @Test(arguments: ["opencode-messages", "opencode-mcp", "opencode-naming", "opencode-plugin-tool"])
    func openCodeFixturesReadTheSame(_ fixture: String) throws {
        let plugin = try Self.plugin("opencode")
        expectSameEvents(swift: { OpenCodeParser() }, plugin: { plugin.makeParser() }, lines: try Self.lines(fixture) + Self.oddLines)
    }
}
