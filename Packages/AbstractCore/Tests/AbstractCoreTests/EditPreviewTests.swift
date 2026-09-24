import Foundation
import Testing
@testable import AbstractCore

@Suite struct EditPreviewInputTests {
    private func input(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    @Test func editKeepsSharedLinesAsContext() throws {
        let preview = try #require(EditPreview.fromToolInput(name: "Edit", input: input(
            #"{"file_path":"/a.swift","old_string":"a\nb\nc","new_string":"a\nB\nc"}"#)))
        #expect(preview.lines.map(\.origin) == [.context, .removed, .added, .context])
        #expect(preview.lines.map(\.content) == ["a", "b", "B", "c"])
        #expect((preview.additions, preview.deletions) == (1, 1))
        #expect(preview.filePath == "/a.swift")
    }

    @Test func removalsReadBeforeAdditions() {
        let lines = EditPreview.lineDiff("x\ny", "p\nq\nr")
        #expect(lines.map(\.origin) == [.removed, .removed, .added, .added, .added])
    }

    @Test func insertedLineInTheMiddle() {
        let lines = EditPreview.lineDiff("one\nthree\n", "one\ntwo\nthree\n")
        #expect(lines.map(\.origin) == [.context, .added, .context])
        #expect(lines[1].content == "two")
    }

    @Test func multiEditMarksEachEditAsItsOwnHunk() throws {
        let preview = try #require(EditPreview.fromToolInput(name: "MultiEdit", input: input(
            #"{"file_path":"/a","edits":[{"old_string":"a","new_string":"b"},{"old_string":"c","new_string":"d"}]}"#)))
        #expect(preview.lines.map(\.content) == ["a", "b", "c", "d"])
        #expect(preview.lines.map { $0.startsHunk == true } == [false, false, true, false])
    }

    @Test func writeIsAllAdditionsNumberedFromOne() throws {
        let preview = try #require(EditPreview.fromToolInput(name: "Write", input: input(
            #"{"file_path":"/n.txt","content":"hi\nthere\n"}"#)))
        #expect(preview.lines.map(\.origin) == [.added, .added])
        #expect(preview.lines.map(\.newLine) == [1, 2])
        #expect((preview.additions, preview.deletions) == (2, 0))
    }

    @Test func otherToolsHaveNoPreview() throws {
        #expect(EditPreview.fromToolInput(name: "Bash", input: try input(#"{"command":"ls"}"#)) == nil)
        #expect(EditPreview.fromToolInput(name: "Edit", input: try input(#"{"file_path":"/a"}"#)) == nil)
    }

    @Test func timelineShowsTheInputDiffUntilTheResultArrives() throws {
        var timeline = Timeline()
        let edit = try input(#"{"file_path":"/a","old_string":"x","new_string":"y"}"#)
        timeline.append(.toolUse(id: "t1", name: "Edit", input: edit, edit: nil))
        guard case let .tools(_, calls)? = timeline.blocks.last else { Issue.record("no tools block"); return }
        #expect(calls.first?.edit?.lines.map(\.origin) == [.removed, .added])

        let numbered = EditPreview(filePath: "/a", additions: 1, deletions: 1,
                                   lines: [.init(origin: .removed, content: "x", oldLine: 4), .init(origin: .added, content: "y", newLine: 4)])
        timeline.append(.toolResult(toolUseId: "t1", output: "ok", isError: false, edit: numbered))
        guard case let .tools(_, after)? = timeline.blocks.last else { Issue.record("no tools block"); return }
        #expect(after.first?.edit == numbered)
    }
}

@Suite struct ClaudePatchLineNumberTests {
    @Test func structuredPatchCarriesLineNumbersAndHunkBreaks() {
        let parser = ClaudeProvider().makeParser()
        let events = parser.feed(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t","content":"ok"}]},"tool_use_result":{"filePath":"/a","structuredPatch":[{"oldStart":10,"newStart":10,"lines":[" keep","-old","+new"]},{"oldStart":40,"newStart":40,"lines":["+tail"]}]}}"#, stream: .stdout)
        guard case let .toolResult(_, _, _, edit?)? = events.first else { Issue.record("no edit"); return }
        #expect(edit.lines.map(\.oldLine) == [10, 11, nil, nil])
        #expect(edit.lines.map(\.newLine) == [10, nil, 11, 40])
        #expect(edit.lines.map { $0.startsHunk == true } == [false, false, false, true])
    }
}
