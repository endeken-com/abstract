import Foundation
import Testing
@testable import AbstractCore

@Suite("Output style")
struct OutputStyleTests {
    private func context(_ style: OutputStyle) -> LaunchContext {
        LaunchContext(cwd: "/w", prompt: "do it", permissionPolicy: .autoEdits, outputStyle: style)
    }

    @Test func claudeGetsItsBuiltInStyleBySettings() throws {
        for spec in [Agents.claude.buildLaunch(context(.explanatory)), Agents.claude.buildResume(context(.explanatory), resumeId: "s")] {
            let i = try #require(spec.args.firstIndex(of: "--settings"))
            let json = try JSONSerialization.jsonObject(with: Data(spec.args[i + 1].utf8)) as? [String: String]
            #expect(json == ["outputStyle": "Explanatory"])
        }
    }

    @Test func defaultStyleAddsNothing() {
        #expect(!Agents.claude.buildLaunch(context(.default)).args.contains("--settings"))
        #expect(!Agents.codex.buildLaunch(context(.default)).args.contains { $0.hasPrefix("developer_instructions") })
    }

    @Test func codexGetsTheStyleAsQuotedDeveloperInstructions() throws {
        let args = Agents.codex.buildResume(context(.concise), resumeId: "t").args
        let i = try #require(args.firstIndex { $0.hasPrefix("developer_instructions=") })
        #expect(args[i - 1] == "-c")
        let value = String(args[i].dropFirst("developer_instructions=".count))
        let decoded = try JSONDecoder().decode(String.self, from: Data(value.utf8))
        #expect(decoded == OutputStyle.concise.instructions)
        #expect(args.last == "do it")
    }
}
