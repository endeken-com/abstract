import Testing
@testable import AbstractCore

@Suite("Worktree path labels")
struct WorktreePathDisplayTests {
    @Test func shortensOnlyPathsInsideTheHomeDirectory() {
        let home = "/Users/test"
        #expect(WorktreePathDisplay.abbreviated(home, homeDirectory: home) == "~")
        #expect(WorktreePathDisplay.abbreviated(home + "/Projects/Abstract", homeDirectory: home) == "~/Projects/Abstract")
        #expect(WorktreePathDisplay.abbreviated("/Users/tester/Projects", homeDirectory: home) == "/Users/tester/Projects")
        #expect(WorktreePathDisplay.abbreviated("/Volumes/Work/Abstract", homeDirectory: home) == "/Volumes/Work/Abstract")
    }

    @Test func handlesHomeDirectoryWithTrailingSlash() {
        #expect(WorktreePathDisplay.abbreviated("/Users/test/Project", homeDirectory: "/Users/test/") == "~/Project")
    }
}
