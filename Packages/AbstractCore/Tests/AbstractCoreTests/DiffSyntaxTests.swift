import Foundation
import Testing
@testable import AbstractCore

@Suite struct DiffSyntaxTests {
    /// A line's "token": the line and the side it was coloured in.
    struct Seen: Sendable, Hashable { let line: String; let side: String }

    /// Colours every line, remembering which code it came from.
    static let tokenize: @Sendable (String) async -> [[Seen]]? = { code in
        code.split(separator: "\n", omittingEmptySubsequences: false).map { [Seen(line: String($0), side: code)] }
    }

    private func line(_ origin: EditPreview.Origin, _ content: String, hunk: Bool? = nil) -> EditPreview.Line {
        EditPreview.Line(origin: origin, content: content, startsHunk: hunk)
    }

    @Test func eachSideColoursItsOwnLinesWithTheUnchangedOnesAsContext() async {
        let edit = EditPreview(filePath: "app.js", additions: 1, deletions: 1, lines: [
            line(.context, "/* start"), line(.removed, "old */"), line(.added, "new */"), line(.context, "end"),
        ])
        let coloured = await DiffSyntax.edit(edit, tokenize: Self.tokenize)
        let old = "/* start\nold */\nend", new = "/* start\nnew */\nend"
        #expect(coloured == [[Seen(line: "/* start", side: new)], [Seen(line: "old */", side: old)],
                             [Seen(line: "new */", side: new)], [Seen(line: "end", side: new)]])
    }

    @Test func hunksColourApart() async {
        let edit = EditPreview(filePath: "a.swift", additions: 2, deletions: 0, lines: [
            line(.added, "a"), line(.added, "b", hunk: true),
        ])
        let coloured = await DiffSyntax.edit(edit, tokenize: Self.tokenize)
        #expect(coloured.map { $0?.first?.side } == ["a", "b"])
    }

    @Test func anUnknownLanguageStaysPlain() async {
        let edit = EditPreview(filePath: "notes.xyz", additions: 1, deletions: 1, lines: [line(.removed, "a"), line(.added, "b")])
        let coloured = await DiffSyntax.edit(edit) { _ -> [[Seen]]? in nil }
        #expect(coloured == [nil, nil])
    }

    @Test func clippedLinesAndLongEditsStayPlain() async {
        let long = String(repeating: "x", count: DiffSyntax.clippedLine + 1)
        let edit = EditPreview(filePath: "a.js", additions: 2, deletions: 0, lines: [line(.added, long), line(.added, "b")])
        let coloured = await DiffSyntax.edit(edit, tokenize: Self.tokenize)
        #expect(coloured == [nil, [Seen(line: "b", side: "\nb")]])

        let huge = EditPreview(filePath: "a.js", additions: DiffSyntax.editLimit + 1, deletions: 0,
                               lines: Array(repeating: line(.added, "a"), count: DiffSyntax.editLimit + 1))
        #expect(await DiffSyntax.edit(huge, tokenize: Self.tokenize).allSatisfy { $0 == nil })
    }

    @Test func otherLinesAreNeitherColouredNorContext() async {
        let coloured = await DiffSyntax.hunk([(.removed, "a"), (.other, "note"), (.added, "b")], tokenize: Self.tokenize)
        #expect(coloured == [[Seen(line: "a", side: "a")], nil, [Seen(line: "b", side: "b")]])
    }

    @Test func theCacheKeyChangesWithTheTheme() {
        let edit = EditPreview(filePath: "a.js", additions: 1, deletions: 0, lines: [line(.added, "a")])
        #expect(DiffSyntax.EditKey(edit: edit, theme: "graphite") == DiffSyntax.EditKey(edit: edit, theme: "graphite"))
        #expect(DiffSyntax.EditKey(edit: edit, theme: "graphite") != DiffSyntax.EditKey(edit: edit, theme: "paper"))
        var changed = edit
        changed.lines[0].content = "b"
        #expect(DiffSyntax.EditKey(edit: edit, theme: "graphite") != DiffSyntax.EditKey(edit: changed, theme: "graphite"))
    }
}
