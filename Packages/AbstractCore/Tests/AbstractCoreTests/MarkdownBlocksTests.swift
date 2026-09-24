import Testing
@testable import AbstractCore

@Suite("Markdown blocks")
struct MarkdownBlocksTests {
    @Test func paragraphsAndHeadingsStandAlone() {
        #expect(MarkdownBlocks.split("# Title\n\nFirst line\nsame paragraph\n\n\nSecond") == ["# Title", "First line\nsame paragraph", "Second"])
    }

    @Test func codeFencesKeepTheirBlankLines() {
        let text = "Before\n\n```swift\nlet a = 1\n\nlet b = 2\n```\n\nAfter"
        #expect(MarkdownBlocks.split(text) == ["Before", "```swift\nlet a = 1\n\nlet b = 2\n```", "After"])
    }

    @Test func anUnclosedFenceRunsToTheEnd() {
        #expect(MarkdownBlocks.split("Look:\n\n```\ncode\n\nmore") == ["Look:", "```\ncode\n\nmore"])
    }

    @Test func aLooseListStaysOneBlock() {
        let text = "1. First\n\n   continued\n\n2. Second\n- third\n\nAfter the list"
        #expect(MarkdownBlocks.split(text) == ["1. First\n\n   continued\n\n2. Second\n- third", "After the list"])
    }

    @Test func linkDefinitionsJoinTheTextAbove() {
        #expect(MarkdownBlocks.split("See [docs][1].\n\n[1]: https://example.com") == ["See [docs][1].\n\n[1]: https://example.com"])
    }

    @Test func earlierBlocksDontChangeAsTextStreams() {
        let full = "Intro paragraph.\n\n- one\n- two\n\nClosing words here."
        var settled: [String] = []
        for end in full.indices.dropFirst() {
            // Every block but the last is final once the next one starts.
            let blocks = Array(MarkdownBlocks.split(String(full[..<end])).dropLast())
            #expect(Array(blocks.prefix(settled.count)) == settled)
            settled = blocks
        }
        #expect(MarkdownBlocks.split(full) == ["Intro paragraph.", "- one\n- two", "Closing words here."])
    }
}
