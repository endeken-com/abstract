import Foundation
import Testing
import AbstractCore

@Suite struct PanelLayoutTests {
    @Test func sideChromeMovesIntoThePanelAndBackAsTheWindowResizes() {
        var layout = PanelLayout.standard()
        let files = layout.side.tabs[1].id
        layout.activate(files)

        #expect(!SidePanelChrome.usesPanelHeader(mainColumnWidth: 700, sideIsOpen: layout.side.isOpen))
        #expect(SidePanelChrome.usesPanelHeader(mainColumnWidth: 380, sideIsOpen: layout.side.isOpen))
        #expect(SidePanelChrome.usesPanelHeader(mainColumnWidth: 280, sideIsOpen: layout.side.isOpen))
        #expect(!SidePanelChrome.usesPanelHeader(mainColumnWidth: 700, sideIsOpen: layout.side.isOpen))
        #expect(layout.side.active?.id == files)

        layout.setOpen(.side, false)
        #expect(!SidePanelChrome.usesPanelHeader(mainColumnWidth: 280, sideIsOpen: layout.side.isOpen))
    }

    @Test func sideHeaderHeightMatchesTheTitleBandOnBothSidesOfTheThreshold() {
        // One row at the title band's height, wide or compact, so the hairline
        // under it lines up with the main pane's and never jumps on resize.
        #expect(SidePanelChrome.headerHeight == 52)
        for width in [CGFloat(700), 620, 619, 380, 280] {
            #expect(SidePanelChrome.hairlineOffset(mainColumnWidth: width, sideIsOpen: true) == SidePanelChrome.headerHeight)
        }
        // At the narrowest panel, the chat buttons keep their room and the
        // tabs take the rest: the two together never exceed the header.
        let controls: CGFloat = 4 * 28 + 3 * 2
        let tabs = SidePanelChrome.tabsWidth(headerWidth: 260, controlsWidth: controls, gap: 2)
        #expect(tabs + controls + 2 == 260)
        #expect(tabs > 0)
        #expect(SidePanelChrome.tabsWidth(headerWidth: 100, controlsWidth: controls, gap: 2) == 0)
    }

    @Test func standardHasChangesAndFilesBesideTheChat() {
        let layout = PanelLayout.standard()
        #expect(layout.side.isOpen)
        #expect(layout.side.tabs.map(\.kind) == [.changes, .files])
        #expect(!layout.bottom.isOpen && layout.bottom.tabs.isEmpty)
        #expect(layout.isShowing(.changes) && !layout.isShowing(.files))
    }

    @Test func openingAnEmptyPanelGivesItItsDefaultTab() {
        var layout = PanelLayout.standard()
        layout.toggle(.bottom)
        #expect(layout.bottom.isOpen)
        #expect(layout.bottom.tabs.map(\.kind) == [.terminal])
        layout.toggle(.bottom)
        #expect(!layout.bottom.isOpen)
        #expect(layout.bottom.tabs.count == 1, "hiding keeps the tabs, so terminals keep running")
    }

    @Test func showReusesSingleKindsAndOpensTheirPanel() {
        var layout = PanelLayout.standard()
        layout.setOpen(.side, false)
        let files = layout.show(.files)
        #expect(files?.kind == .files)
        #expect(layout.side.isOpen && layout.side.active?.kind == .files)
        #expect(layout.items(of: .files).count == 1)
    }

    @Test func terminalsGoToTheBottomAndCanBeMany() {
        var layout = PanelLayout.standard()
        let first = layout.show(.terminal)
        let second = layout.add(.terminal, to: .bottom)
        #expect(layout.bottom.tabs.map(\.id) == [first?.id, second?.id].compactMap { $0 })
        #expect(layout.bottom.active?.id == second?.id)
        let again = layout.show(.terminal)
        #expect(again?.id == first?.id, "no slot named: bring back the first one")
        let beside = layout.show(.terminal, in: .side)
        #expect(beside.map { layout.slot(of: $0.id) } == .side)
    }

    @Test func reviewOnlyLivesInTheSidePanel() throws {
        var layout = PanelLayout.standard()
        let below = layout.add(.review, to: .bottom)
        #expect(below == nil)
        let added = layout.add(.review, to: .side)
        let review = try #require(added)
        let moved = layout.move(review.id, to: .bottom)
        #expect(!moved)
        #expect(layout.slot(of: review.id) == .side)
        let chat = layout.add(.chat, to: .side)
        #expect(chat == nil)
        let changes = layout.items(of: .changes)[0]
        let movedChanges = layout.move(changes.id, to: .bottom)
        #expect(!movedChanges, "reviewing changes stays in the side panel")
    }

    @Test func movingASingleKindKeepsOneTab() {
        var layout = PanelLayout.standard()
        let files = layout.items(of: .files)[0]
        let moved = layout.move(files.id, to: .bottom)
        #expect(moved)
        #expect(layout.slot(of: files.id) == .bottom)
        #expect(layout.bottom.isOpen && layout.bottom.active?.id == files.id)
        _ = layout.add(.files, to: .side)
        #expect(layout.items(of: .files).count == 1)
        #expect(layout.slot(of: files.id) == .side)
    }

    @Test func closingPicksANeighbourAndTheLastTabClosesThePanel() {
        var layout = PanelLayout.standard()
        let changes = layout.side.tabs[0], files = layout.side.tabs[1]
        layout.close(changes.id)
        #expect(layout.side.active?.id == files.id)
        layout.close(files.id)
        #expect(layout.side.tabs.isEmpty && !layout.side.isOpen)
        layout.toggle(.side)
        #expect(layout.side.tabs.map(\.kind) == [.changes])
    }

    @Test func sizesStayInRange() {
        var layout = PanelLayout.standard()
        layout.resize(.side, to: 10)
        layout.resize(.bottom, to: 10_000)
        #expect(layout.side.size == PanelSlot.side.sizes.lowerBound)
        #expect(layout.bottom.size == PanelSlot.bottom.sizes.upperBound)
    }

    @Test func roundTripsThroughJSON() throws {
        var layout = PanelLayout.standard()
        layout.show(.terminal)
        let data = try JSONEncoder().encode(layout)
        #expect(try JSONDecoder().decode(PanelLayout.self, from: data) == layout)
    }
}
