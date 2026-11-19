import XCTest
@testable import AbstractCore

final class ChatColumnLayoutTests: XCTestCase {
    func testReadingColumnStaysCenteredAndInsideNarrowViewport() {
        for viewport in [240.0, 260, 320, 600] {
            let width = ChatColumnLayout.width(viewport: viewport)
            XCTAssertLessThanOrEqual(width + 64, viewport)
            XCTAssertEqual((viewport - width) / 2, 32)
        }
    }

    func testWideViewportCapsTheReadingColumn() {
        XCTAssertEqual(ChatColumnLayout.width(viewport: 1_200), 720)
        XCTAssertEqual(ChatColumnLayout.width(viewport: 784), 720)
    }
}

/// ABS-212: rows are only built at a real width, rebuilt when the column's
/// width differs from theirs, and never given a height measured at another.
final class ChatColumnWidthTests: XCTestCase {
    func testAViewportWithNoRealWidthGivesNoWidthToBuildAt() {
        for viewport in [0.0, 1, 40, 64, 100, 150] {
            XCTAssertNil(ChatColumnLayout.buildWidth(viewport: viewport), "viewport \(viewport)")
        }
    }

    func testTheNarrowestChatColumnStillBuilds() {
        // A 560 pt chat screen beside the narrowest side panel leaves the chat about 279 pt.
        XCTAssertEqual(ChatColumnLayout.buildWidth(viewport: 279), 215)
        XCTAssertEqual(ChatColumnLayout.buildWidth(viewport: 1_200), 720)
        XCTAssertLessThan(ChatColumnLayout.minimumWidth, 215)
    }

    func testARowBuiltAtAnotherWidthIsRebuilt() {
        XCTAssertTrue(ChatColumnLayout.needsRebuild(built: 1, column: 394))
        XCTAssertTrue(ChatColumnLayout.needsRebuild(built: 720, column: 394))
        XCTAssertFalse(ChatColumnLayout.needsRebuild(built: 394, column: 394))
    }

    func testNothingIsRebuiltUntilThereIsARealWidth() {
        XCTAssertFalse(ChatColumnLayout.needsRebuild(built: 394, column: nil))
        XCTAssertFalse(ChatColumnLayout.needsRebuild(built: 1, column: nil))
    }

    func testAHeightMeasuredAtAnotherWidthIsIgnored() {
        XCTAssertEqual(ChatColumnLayout.cachedHeight(120, measuredAt: 394, column: 394), 120)
        XCTAssertNil(ChatColumnLayout.cachedHeight(4_000, measuredAt: 1, column: 394))
        XCTAssertNil(ChatColumnLayout.cachedHeight(120, measuredAt: 720, column: 394))
    }
}
