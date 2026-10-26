import Foundation
import Testing
@testable import AbstractCore

@Suite("Where the Find menu goes")
struct FindRoutingTests {
    private func front(_ tab: MainTabKind?, _ change: (inout FindFront) -> Void = { _ in }) -> FindFront {
        var front = FindFront(activeTab: tab, selectedSession: "s1")
        change(&front)
        return front
    }

    @Test func findGoesToWhatTheMainPaneShows() {
        #expect(front(.chat(sessionId: "s1")).target(for: .find) == .chat(sessionId: "s1"))
        #expect(front(nil).target(for: .find) == .chat(sessionId: "s1"))
        #expect(front(.file(sessionId: "s1", path: "a.swift")).target(for: .find) == .file(sessionId: "s1", path: "a.swift"))
        #expect(front(.diff(sessionId: "s1")).target(for: .find) == .review(sessionId: "s1"))
        // A tab of another chat than the one the window is on doesn't count.
        #expect(front(.diff(sessionId: "s2")).target(for: .find) == .chat(sessionId: "s1"))
        #expect(FindFront(activeTab: .diff(sessionId: "s1")).target(for: .find) == nil)
    }

    @Test func theTerminalKeepsItsOwnFindWhileItHasTheKeyboard() {
        for command in FindCommand.allCases {
            #expect(front(.diff(sessionId: "s1")) { $0.terminalHasKeyboard = true }.target(for: command) == .terminal)
            #expect(front(.file(sessionId: "s1", path: "a")) { $0.terminalHasKeyboard = true }.target(for: command) == .terminal)
        }
    }

    @Test func replaceAndUseSelectionOnlyGoToAFile() {
        let file = FindTarget.file(sessionId: "s1", path: "a.swift")
        #expect(front(.file(sessionId: "s1", path: "a.swift")).target(for: .replace) == file)
        #expect(front(.file(sessionId: "s1", path: "a.swift")).target(for: .useSelection) == file)
        #expect(front(.diff(sessionId: "s1")).target(for: .replace) == nil)
        #expect(front(.chat(sessionId: "s1")).target(for: .replace) == nil)
        #expect(front(.chat(sessionId: "s1")).target(for: .useSelection) == nil)
    }

    @Test func nextAndPreviousStepTheOpenFindBarElseTheFilesSearch() {
        for command in [FindCommand.next, .previous] {
            #expect(front(.diff(sessionId: "s1")) { $0.reviewFindOpen = true }.target(for: command) == .review(sessionId: "s1"))
            #expect(front(.diff(sessionId: "s1")).target(for: command) == nil)
            #expect(front(.diff(sessionId: "s1")) { $0.fileSearchHasMatches = true }.target(for: command) == .fileSearch(sessionId: "s1"))
            #expect(front(.chat(sessionId: "s1")) { $0.chatFindOpen = true; $0.fileSearchHasMatches = true }.target(for: command)
                    == .chat(sessionId: "s1"))
            #expect(front(.chat(sessionId: "s1")) { $0.fileSearchHasMatches = true }.target(for: command) == .fileSearch(sessionId: "s1"))
        }
    }

    @Test func nextInAFileFollowsItsFindBarThenTheFilesSearch() {
        let tab = MainTabKind.file(sessionId: "s1", path: "a.swift")
        let file = FindTarget.file(sessionId: "s1", path: "a.swift")
        // Stepping the Files search opens each match's file in front: ⌘G keeps stepping it.
        #expect(front(tab) { $0.fileSearchHasMatches = true }.target(for: .next) == .fileSearch(sessionId: "s1"))
        #expect(front(tab) { $0.fileSearchHasMatches = true; $0.fileFindOpen = true }.target(for: .next) == file)
        // Nothing else to step: the file finds the last words found again.
        #expect(front(tab).target(for: .previous) == file)
    }
}
