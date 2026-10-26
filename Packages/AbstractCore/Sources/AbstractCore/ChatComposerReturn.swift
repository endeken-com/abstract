import Foundation

/// What Return does in the Mac chat composer. The system keeps the key while
/// an input method is composing, and Shift-Return always enters a new line.
public enum ChatComposerReturnAction: Equatable {
    case system
    case consume
    case newline
    case selectSlashItem
    case send

    public static func resolve(isComposing: Bool, slashMenuOpen: Bool, shift: Bool,
                               command: Bool, option: Bool, control: Bool, repeated: Bool = false) -> Self {
        if isComposing || option || control { return .system }
        if shift { return .newline }
        if repeated { return .consume }
        if command { return .send }
        return slashMenuOpen ? .selectSlashItem : .send
    }
}

/// Replace the selected UTF-16 range, as NSTextView reports it, so a newline
/// lands at the caret instead of at the end of a draft.
public enum ChatComposerDraftEdit {
    public static func insertingNewline(into draft: String, selectedRange: NSRange?) -> (text: String, selection: NSRange) {
        let text = draft as NSString
        let range: NSRange
        if let selectedRange, selectedRange.location != NSNotFound,
           selectedRange.location <= text.length, selectedRange.length <= text.length - selectedRange.location {
            range = selectedRange
        } else {
            range = NSRange(location: text.length, length: 0)
        }
        return (text.replacingCharacters(in: range, with: "\n"), NSRange(location: range.location + 1, length: 0))
    }
}
