// Codex reports which files a patch touched but not how: the enricher reads
// each file after the patch and logs the diff beside the change.

import Foundation
import Testing
@testable import AbstractCore

@Suite struct CodexEditDiffsTests {
    let exec = LocalExecutor.shared

    private func repo() async throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("abstract-codex-diffs-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@abstract.local"], ["config", "user.name", "T"],
                     ["config", "commit.gpgsign", "false"]] {
            _ = try await exec.run("git", args, cwd: dir)
        }
        try (1...20).map { "line \($0)\n" }.joined().write(toFile: dir + "/app.txt", atomically: true, encoding: .utf8)
        _ = try await exec.run("git", ["add", "-A"], cwd: dir)
        _ = try await exec.run("git", ["commit", "-qm", "init"], cwd: dir)
        return dir
    }

    private func completed(_ path: String, kind: String = "update") -> OutputLine {
        OutputLine(stream: .stdout, line: #"{"type":"item.completed","item":{"id":"i","type":"file_change","changes":[{"path":"\#(path)","kind":"\#(kind)"}],"status":"completed"}}"#)
    }

    private func edit(_ line: OutputLine) -> EditPreview? {
        for event in CodexProvider().makeParser().feed(line.line, stream: line.stream) {
            if case let .toolResult(_, _, _, edit) = event { return edit }
        }
        return nil
    }

    @Test func firstEditIsDiffedAgainstHead() async throws {
        let dir = try await repo(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let enricher = try #require(CodexProvider().makeLineEnricher(executor: exec, cwd: dir))
        try (1...20).map { $0 == 10 ? "ten\n" : "line \($0)\n" }.joined().write(toFile: dir + "/app.txt", atomically: true, encoding: .utf8)

        let preview = try #require(edit(enricher.enrich(completed(dir + "/app.txt"))))
        #expect((preview.additions, preview.deletions) == (1, 1))
        #expect(preview.lines.first == EditPreview.Line(origin: .context, content: "line 7", oldLine: 7, newLine: 7))
        #expect(preview.lines.contains(EditPreview.Line(origin: .added, content: "ten", newLine: 10)))
    }

    @Test func laterEditsShowOnlyTheirOwnChange() async throws {
        let dir = try await repo(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let enricher = try #require(CodexProvider().makeLineEnricher(executor: exec, cwd: dir))
        let path = dir + "/app.txt"
        try (1...20).map { $0 == 2 ? "two\n" : "line \($0)\n" }.joined().write(toFile: path, atomically: true, encoding: .utf8)
        _ = enricher.enrich(completed(path))
        try (1...20).map { $0 == 2 ? "two\n" : $0 == 18 ? "eighteen\n" : "line \($0)\n" }.joined()
            .write(toFile: path, atomically: true, encoding: .utf8)

        let preview = try #require(edit(enricher.enrich(completed(path))))
        #expect((preview.additions, preview.deletions) == (1, 1))
        #expect(!preview.lines.contains { $0.content == "two" && $0.origin != .context })
    }

    @Test func newFileIsAllAdditions() async throws {
        let dir = try await repo(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let enricher = try #require(CodexProvider().makeLineEnricher(executor: exec, cwd: dir))
        try "a\nb\nc\n".write(toFile: dir + "/new.txt", atomically: true, encoding: .utf8)

        let preview = try #require(edit(enricher.enrich(completed(dir + "/new.txt", kind: "add"))))
        #expect((preview.additions, preview.deletions) == (3, 0))
    }

    @Test func otherLinesPassThroughUntouched() throws {
        let enricher = try #require(CodexProvider().makeLineEnricher(executor: exec, cwd: "/tmp"))
        let line = OutputLine(stream: .stdout, line: #"{"type":"item.completed","item":{"id":"m","type":"agent_message","text":"hi"}}"#)
        #expect(enricher.enrich(line) == line)
    }

    @Test func unifiedDiffKeepsThreeLinesOfContextPerHunk() {
        let old = (1...30).map { "l\($0)" }.joined(separator: "\n")
        let new = (1...30).map { $0 == 5 ? "five" : $0 == 25 ? "twentyfive" : "l\($0)" }.joined(separator: "\n")
        let diff = EditPreview.unifiedDiff(old, new)
        #expect(diff.split(separator: "\n").filter { $0.hasPrefix("@@") } == ["@@ -2,7 +2,7 @@", "@@ -22,7 +22,7 @@"])
        #expect(EditPreview.unifiedDiff(old, old).isEmpty)
    }

    @Test func countsEveryLineEvenPastThePreviewCap() {
        let diff = (1...300).map { "+x\($0)" }.joined(separator: "\n")
        let line = #"{"type":"item.completed","item":{"id":"i","type":"file_change","changes":[{"path":"a","diff":\#(JSONValue.string(diff).compact())}],"status":"completed"}}"#
        let preview = edit(OutputLine(stream: .stdout, line: line))
        #expect(preview?.additions == 300)
        #expect(preview?.lines.count == 200)
    }
}
