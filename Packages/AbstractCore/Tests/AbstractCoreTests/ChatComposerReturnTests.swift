import XCTest
@testable import AbstractCore

final class ChatComposerReturnTests: XCTestCase {
    func testReturnSendsAndShiftReturnInsertsNewline() {
        XCTAssertEqual(action(), .send)
        XCTAssertEqual(action(shift: true), .newline)
        XCTAssertEqual(action(command: true), .send)
    }

    func testSlashMenuTakesReturnButNotShiftReturn() {
        XCTAssertEqual(action(slashMenuOpen: true), .selectSlashItem)
        XCTAssertEqual(action(slashMenuOpen: true, shift: true), .newline)
    }

    func testInputMethodKeepsReturnEvenWithSlashMenuOpen() {
        XCTAssertEqual(action(isComposing: true), .system)
        XCTAssertEqual(action(isComposing: true, slashMenuOpen: true), .system)
        XCTAssertEqual(action(isComposing: true, command: true), .system)
    }

    func testOtherModifiedReturnKeepsSystemBehavior() {
        XCTAssertEqual(action(option: true), .system)
        XCTAssertEqual(action(control: true), .system)
    }

    func testHeldReturnDoesNotSendAgainOrSelectAnotherCommand() {
        XCTAssertEqual(action(repeated: true), .consume)
        XCTAssertEqual(action(slashMenuOpen: true, repeated: true), .consume)
        XCTAssertEqual(action(shift: true, repeated: true), .newline)
    }

    func testShiftReturnReplacesSelectionAtTheCaret() {
        let edit = ChatComposerDraftEdit.insertingNewline(into: "first last", selectedRange: NSRange(location: 6, length: 0))
        XCTAssertEqual(edit.text, "first \nlast")
        XCTAssertEqual(edit.selection, NSRange(location: 7, length: 0))

        let replacing = ChatComposerDraftEdit.insertingNewline(into: "before middle after", selectedRange: NSRange(location: 7, length: 6))
        XCTAssertEqual(replacing.text, "before \n after")
    }

    func testShiftReturnUsesUTF16SelectionAndFallsBackToTheEnd() {
        let edit = ChatComposerDraftEdit.insertingNewline(into: "😀there", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertEqual(edit.text, "😀\nthere")
        XCTAssertEqual(edit.selection.location, 3)
        XCTAssertEqual(ChatComposerDraftEdit.insertingNewline(into: "text", selectedRange: nil).text, "text\n")
    }

    func testShiftReturnBreaksAnEmptyNewChatPrompt() {
        let edit = ChatComposerDraftEdit.insertingNewline(into: "", selectedRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(edit.text, "\n")
        XCTAssertEqual(edit.selection, NSRange(location: 1, length: 0))
    }

    private func action(isComposing: Bool = false, slashMenuOpen: Bool = false,
                        shift: Bool = false, command: Bool = false, option: Bool = false,
                        control: Bool = false, repeated: Bool = false) -> ChatComposerReturnAction {
        .resolve(isComposing: isComposing, slashMenuOpen: slashMenuOpen, shift: shift,
                 command: command, option: option, control: control, repeated: repeated)
    }
}
