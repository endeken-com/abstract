import XCTest
@testable import AbstractCore

final class TranscriptFollowTests: XCTestCase {
    func testStartsFollowing() {
        XCTAssertTrue(TranscriptFollow().following)
    }

    func testScrollingUpStopsFollowingAndOnlyTheEndResumesIt() {
        var follow = TranscriptFollow()
        follow.readerScrolled(distanceFromEnd: 600)
        XCTAssertFalse(follow.following)
        // Still short of the end: no resume, however close.
        follow.readerScrolled(distanceFromEnd: TranscriptFollow.endTolerance + 1)
        XCTAssertFalse(follow.following)
        follow.readerScrolled(distanceFromEnd: TranscriptFollow.endTolerance)
        XCTAssertTrue(follow.following)
    }

    func testUpwardMotionNearTheEndStillStopsFollowing() {
        var follow = TranscriptFollow()
        follow.readerScrolled(distanceFromEnd: 2, movedUp: true)
        XCTAssertFalse(follow.following)
        follow.readerScrolled(distanceFromEnd: 2)
        XCTAssertTrue(follow.following)
    }

    func testJumpResumesAndHoldStops() {
        var follow = TranscriptFollow()
        follow.readerScrolled(distanceFromEnd: 300)
        follow.jump()
        XCTAssertTrue(follow.following)
        follow.hold()
        XCTAssertFalse(follow.following)
    }

    func testScrolledPastTheEndStillFollows() {
        var follow = TranscriptFollow()
        follow.readerScrolled(distanceFromEnd: -40)
        XCTAssertTrue(follow.following)
    }
}

final class TranscriptAnchorTests: XCTestCase {
    // Four rows, 100pt each, starting at 20.
    private let tops: [Double] = [20, 120, 220, 320]
    private let heights: [Double] = [100, 100, 100, 100]

    func testAnchorIsFirstRowAtTheTopOfTheView() {
        let anchor = TranscriptAnchor.anchor(tops: tops, heights: heights, viewportTop: 150)
        XCTAssertEqual(anchor, .init(row: 1, offset: -30))
        // The view's top in a gap: the next row down anchors it.
        let gapTops: [Double] = [20, 140]
        XCTAssertEqual(TranscriptAnchor.anchor(tops: gapTops, heights: [100, 100], viewportTop: 130),
                       .init(row: 1, offset: 10))
        XCTAssertNil(TranscriptAnchor.anchor(tops: [], heights: [], viewportTop: 0))
    }

    func testAppendWhileReadingKeepsTheViewWhereItWas() {
        let anchor = TranscriptAnchor.anchor(tops: tops, heights: heights, viewportTop: 150)!
        // Two rows arrive below: every existing top is unchanged.
        XCTAssertEqual(TranscriptAnchor.target(anchor, tops: tops + [420, 520]), 150)
    }

    func testHeightChangeAboveTheAnchorMovesTheViewWithIt() {
        let anchor = TranscriptAnchor.anchor(tops: tops, heights: heights, viewportTop: 150)!
        // The row above grows 50pt (an image or card settling): the rows
        // below, and the view with them, move down exactly that much.
        XCTAssertEqual(TranscriptAnchor.target(anchor, tops: [20, 170, 270, 370]), 200)
    }

    func testHeightChangeBelowTheAnchorLeavesTheViewAlone() {
        let anchor = TranscriptAnchor.anchor(tops: tops, heights: heights, viewportTop: 150)!
        // The anchored row itself streams taller, and a card below opens:
        // neither moves the anchored row's top.
        XCTAssertEqual(TranscriptAnchor.target(anchor, tops: tops), 150)
        XCTAssertNil(TranscriptAnchor.target(.init(row: 9, offset: 0), tops: tops))
    }
}
