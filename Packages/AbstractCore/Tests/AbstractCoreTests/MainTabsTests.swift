import Testing
@testable import AbstractCore

@Suite("Main pane tabs")
struct MainTabsTests {
    @Test func aChatReplacesTheChatShowingUnlessAskedForANewTab() {
        var tabs = MainTabs()
        tabs.openChat("a")
        tabs.openChat("b")
        #expect(tabs.tabs.map(\.kind) == [.chat(sessionId: "b")])
        tabs.openChat("c", newTab: true)
        #expect(tabs.tabs.map(\.kind) == [.chat(sessionId: "b"), .chat(sessionId: "c")])
        tabs.openChat("b")
        #expect(tabs.active?.kind == .chat(sessionId: "b"))
        #expect(tabs.tabs.count == 2)
    }

    @Test func previewFilesReplaceEachOtherUntilKept() {
        var tabs = MainTabs()
        tabs.openChat("a")
        tabs.openFile("x.swift", in: "a")
        tabs.openFile("y.swift", in: "a")
        #expect(tabs.tabs.map(\.kind) == [.chat(sessionId: "a"), .file(sessionId: "a", path: "y.swift")])
        tabs.keep(tabs.activeId!)
        tabs.openFile("z.swift", in: "a")
        #expect(tabs.tabs.count == 3)
        // Opening a kept file again doesn't make it a preview.
        tabs.openFile("y.swift", in: "a")
        #expect(tabs.active?.preview == false)
    }

    @Test func aChatWhileAFileShowsOpensBesideIt() {
        var tabs = MainTabs()
        tabs.openChat("a")
        tabs.openFile("x.swift", in: "a", preview: false)
        tabs.openChat("b")
        #expect(tabs.tabs.map(\.kind) == [.chat(sessionId: "a"), .file(sessionId: "a", path: "x.swift"), .chat(sessionId: "b")])
    }

    @Test func closingHandsOverToTheNeighbour() {
        var tabs = MainTabs()
        tabs.openChat("a")
        tabs.openDiff(in: "a")
        tabs.openFile("x.swift", in: "a", preview: false)
        tabs.activate(tabs.tabs[1].id)
        tabs.close(tabs.tabs[1].id)
        #expect(tabs.active?.kind == .file(sessionId: "a", path: "x.swift"))
        tabs.removeSession("a")
        #expect(tabs.tabs.isEmpty && tabs.activeId == nil)
    }

    @Test func dragMovesATab() {
        var tabs = MainTabs()
        tabs.openChat("a")
        tabs.openDiff(in: "a")
        tabs.openFile("x.swift", in: "a", preview: false)
        tabs.move(tabs.tabs[2].id, to: tabs.tabs[0].id)
        #expect(tabs.tabs.map(\.kind) == [.file(sessionId: "a", path: "x.swift"), .chat(sessionId: "a"), .diff(sessionId: "a")])
    }
}
