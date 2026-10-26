import Foundation
import Testing
@testable import AbstractCore

@Suite("Finding in a review's diff")
struct DiffSearchTests {
    /// A changed file, a renamed one, and one so long the review starts it
    /// collapsed and waits for "Show Diff" before drawing it.
    private func files() -> [FileDiff] {
        let long = (1...7_000).map { "+line \($0)" + ($0 == 6_500 ? " needle" : "") }.joined(separator: "\n")
        return Diff.parse("""
        diff --git a/app.swift b/app.swift
        index 1111111..2222222 100644
        --- a/app.swift
        +++ b/app.swift
        @@ -10,4 +10,4 @@ func run()
         let needle = 1
        -print(Needle)
        +print(needle, needle)
         done()
        @@ -40,2 +40,3 @@
         a
        +NEEDLE here
         b
        diff --git a/old/name.txt b/new/name.txt
        similarity index 90%
        rename from old/name.txt
        rename to new/name.txt
        index 3333333..4444444 100644
        --- a/old/name.txt
        +++ b/new/name.txt
        @@ -1,2 +1,2 @@
        -the old needle
        +the new needle
         end
        diff --git a/big.txt b/big.txt
        new file mode 100644
        index 0000000..5555555
        --- /dev/null
        +++ b/big.txt
        @@ -0,0 +1,7000 @@
        \(long)

        """)
    }

    @Test func countsEveryAppearanceInFileOrderThenLineOrder() {
        let matches = DiffSearch().matches(of: "needle", in: files())
        #expect(matches.count == 8)
        #expect(matches.map(\.path) == ["app.swift", "app.swift", "app.swift", "app.swift", "app.swift",
                                         "new/name.txt", "new/name.txt", "big.txt"])
        // Two on one line count as two, told apart by occurrence.
        #expect(matches[2].occurrence == 0 && matches[3].occurrence == 1)
        #expect(matches[2].newLine == 11 && matches[3].newLine == 11)
    }

    @Test func givesEachMatchItsLineNumbersAndPlaceInTheHunks() {
        let matches = DiffSearch().matches(of: "needle", in: files())
        let context = matches[0], removed = matches[1], second = matches[4]
        #expect(context.origin == .context && context.oldLine == 10 && context.newLine == 10)
        #expect(removed.origin == .removed && removed.oldLine == 11 && removed.newLine == nil)
        #expect(second.hunk == 1 && second.line == 1 && second.newLine == 41)
    }

    @Test func includesFilesTheReviewHasCollapsedOrNotDrawn() throws {
        let match = try #require(DiffSearch().matches(of: "needle", in: files()).last)
        #expect(match.path == "big.txt")
        #expect(match.newLine == 6_500)
    }

    @Test func findsInARenamedFileUnderItsNewPath() {
        let renamed = DiffSearch().matches(of: "needle", in: files()).filter { $0.path == "new/name.txt" }
        #expect(renamed.map(\.origin) == [.removed, .added])
        #expect(renamed.map(\.oldLine) == [1, nil])
    }

    @Test func canSearchOnlyAddedOrOnlyRemovedLines() {
        let added = DiffSearch(lines: .added).matches(of: "needle", in: files())
        #expect(added.allSatisfy { $0.origin == .added })
        #expect(added.count == 5)
        let removed = DiffSearch(lines: .removed).matches(of: "needle", in: files())
        #expect(removed.map(\.path) == ["app.swift", "new/name.txt"])
    }

    @Test func ignoresCaseUnlessAskedToMatchIt() {
        let all = DiffSearch().matches(of: "Needle", in: files())
        #expect(all.count == 8)
        let exact = DiffSearch(caseSensitive: true).matches(of: "Needle", in: files())
        #expect(exact.count == 1)
        #expect(exact.first?.origin == .removed)
        #expect(DiffSearch(caseSensitive: true).matches(of: "NEEDLE", in: files()).first?.newLine == 41)
    }

    @Test func findsInLinesAsTheReviewShowsThem() {
        let tabbed = Diff.parse("""
        diff --git a/t.txt b/t.txt
        --- a/t.txt
        +++ b/t.txt
        @@ -1 +1 @@
        -x
        +\tindented\r

        """)
        #expect(DiffSearch().matches(of: "    indented", in: tabbed).count == 1)
        #expect(Diff.display("\tx\r") == "    x")
    }

    @Test func skipsBinaryFilesAndEmptyWords() {
        var binary = FileDiff(path: "image.png", isBinary: true, rawHeader: "")
        binary.hunks = files()[0].hunks
        #expect(DiffSearch().matches(of: "needle", in: [binary]).isEmpty)
        #expect(DiffSearch().matches(of: "", in: files()).isEmpty)
    }

    @Test func stepsThroughMatchesRoundTheEnds() {
        var find = DiffFind()
        #expect(find.label == "")
        find.search("needle", in: files(), using: DiffSearch())
        #expect(find.label == "1 of 8")
        // The first Return shows the first match rather than skipping it.
        #expect(find.next()?.newLine == 10)
        #expect(find.next()?.oldLine == 11)
        #expect(find.label == "2 of 8")
        find.previous()
        #expect(find.previous()?.path == "big.txt")
        #expect(find.label == "8 of 8")
        #expect(find.next()?.newLine == 10)
        find.search("nowhere", in: files(), using: DiffSearch())
        #expect(find.label == "No results")
        #expect(find.next() == nil)
    }

    @Test func staysOnTheSameMatchWhenTheDiffIsReadAgain() {
        var find = DiffFind()
        find.search("needle", in: files(), using: DiffSearch())
        for _ in 0..<6 { find.next() }
        let was = find.currentMatch
        #expect(was?.path == "new/name.txt")
        // The first file left the diff: the match moves up the list but stays the one you're on.
        find.refresh(Array(files().dropFirst()), using: DiffSearch())
        #expect(find.label == "1 of 3")
        #expect(find.currentMatch == was && find.shown)
        // It's gone itself: the nearest takes its place, shown by the next Return.
        find.refresh(Array(files().dropFirst(2)), using: DiffSearch())
        #expect(find.label == "1 of 1")
        #expect(!find.shown)
        #expect(find.next()?.path == "big.txt")
    }
}
