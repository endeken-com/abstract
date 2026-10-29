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
