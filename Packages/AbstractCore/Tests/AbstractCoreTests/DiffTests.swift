import Testing
@testable import AbstractCore

@Suite struct DiffTests {
    static let sample = "diff --git a/src/main.rs b/src/main.rs\nindex 83db48f..bf269f4 100644\n--- a/src/main.rs\n+++ b/src/main.rs\n@@ -1,3 +1,4 @@\n fn main() {\n-    println!(\"old\");\n+    println!(\"new\");\n+    println!(\"extra\");\n }\n@@ -10,2 +11,2 @@ fn other() {\n-    let x = 1;\n+    let x = 2;\n     done();\ndiff --git a/hi.txt b/hi.txt\nnew file mode 100644\nindex 0000000..45b983b\n--- /dev/null\n+++ b/hi.txt\n@@ -0,0 +1 @@\n+hi\n"

    @Test func parsesFilesHunksAndCounts() throws {
        let files = Diff.parse(Self.sample)
        try #require(files.count == 2)
        let main = files[0]
        #expect(main.path == "src/main.rs")
        #expect(main.oldPath == nil)
        #expect(main.status == .modified)
        #expect(main.hunks.count == 2)
        #expect(main.additions == 3)
        #expect(main.deletions == 2)
        #expect(main.hunks[0].oldStart == 1)
        #expect(main.hunks[0].newLines == 4)
        #expect(main.hunks[1].header == "@@ -10,2 +11,2 @@ fn other() {")
        #expect(main.hunks[1].oldStart == 10 && main.hunks[1].oldLines == 2)
        #expect(main.hunks[1].newStart == 11 && main.hunks[1].newLines == 2)

        let hi = files[1]
        #expect(hi.path == "hi.txt")
        #expect(hi.status == .added)
        #expect(hi.additions == 1)
        #expect(hi.hunks[0].oldStart == 0 && hi.hunks[0].oldLines == 0)
        #expect(hi.hunks[0].newStart == 1 && hi.hunks[0].newLines == 1)
    }

    @Test func partialPatchContainsOnlySelectedHunk() {
        let files = Diff.parse(Self.sample)
        let patch = Diff.buildPatch(files[0], hunks: [1])
        #expect(patch.hasPrefix("diff --git a/src/main.rs b/src/main.rs\n"))
        #expect(patch.contains("index 83db48f..bf269f4"), "3-way needs the index line")
        #expect(patch.contains("let x = 2"))
        #expect(!patch.contains("println!(\"new\")"), "hunk 0 must be excluded")
    }

    @Test func emptySelectionMeansWholeFile() {
        let files = Diff.parse(Self.sample)
        let patch = Diff.buildPatch(files[0], hunks: [])
        #expect(patch.contains("println!(\"new\")"))
        #expect(patch.contains("let x = 2"))
    }

    @Test func handlesEmptyAndGarbageInput() {
        #expect(Diff.parse("").isEmpty)
        #expect(Diff.parse("not a diff at all\njust text").isEmpty)
    }

    @Test func rawTextIsByteFaithful() {
        // Whole-file patches reproduce the input exactly: nothing added, nothing lost.
        let files = Diff.parse(Self.sample)
        #expect(files.map { Diff.buildPatch($0, hunks: []) }.joined() == Self.sample)
        // The trailing newline of the input is not an extra context line.
        #expect(files[1].hunks[0].lines == [DiffLine(origin: .added, content: "hi")])
    }

    @Test func keepsCarriageReturnsAndNoNewlineMarkers() {
        let input = "diff --git a/w.txt b/w.txt\nindex 1..2 100644\n--- a/w.txt\n+++ b/w.txt\n@@ -1 +1 @@\n-old\r\n+new\r\n\\ No newline at end of file\n"
        let file = Diff.parse(input)[0]
        #expect(file.hunks[0].lines.map(\.origin) == [.removed, .added, .noNewline])
        #expect(file.hunks[0].lines[1].content == "new\r")
        #expect(Diff.buildPatch(file, hunks: []) == input)
    }

    @Test func parsesRenamesDeletionsAndBinaries() {
        let input = """
        diff --git a/old name.txt b/new name.txt
        similarity index 90%
        rename from old name.txt
        rename to new name.txt
        index 1..2 100644
        --- a/old name.txt
        +++ b/new name.txt
        @@ -1 +1 @@
        -a
        +b
        diff --git a/gone.txt b/gone.txt
        deleted file mode 100644
        index 3..0
        --- a/gone.txt
        +++ /dev/null
        @@ -1 +0,0 @@
        -bye
        diff --git a/logo.png b/logo.png
        index 4..5 100644
        Binary files a/logo.png and b/logo.png differ

        """
        let files = Diff.parse(input)
        #expect(files.map(\.path) == ["new name.txt", "gone.txt", "logo.png"])
        #expect(files[0].status == .renamed)
        #expect(files[0].oldPath == "old name.txt")
        #expect(files[1].status == .deleted)
        #expect(files[1].deletions == 1)
        #expect(files[2].isBinary)
        #expect(files[2].hunks.isEmpty)
        #expect(files[2].id == "logo.png")
    }
}
