import AppKit
import SwiftTerm
import AbstractCore

/// The Edit menu's Find items go to whatever is in front: the terminal while
/// it has the keyboard, else the chat, the file or the review the main pane
/// shows, whichever part of the window has the keyboard.
extension AppModel {
    /// Read when an item is chosen: where the keyboard is isn't observed.
    var findFront: FindFront {
        var front = FindFront(activeTab: activeTab?.kind, selectedSession: selectedSessionId)
        front.terminalHasKeyboard = Self.terminalWithKeyboard != nil
        if let id = selectedSessionId {
            front.chatFindOpen = feed(id).find.isOpen
            front.reviewFindOpen = ReviewStore.shared.existing(id)?.find.isOpen == true
        }
        front.fileFindOpen = activeFileDocument?.textView?.enclosingScrollView?.isFindBarVisible == true
        front.fileSearchHasMatches = fileSearchInFront != nil
        return front
    }

    func performFind(_ command: FindCommand) {
        switch findFront.target(for: command) {
        case .terminal?:
            guard let terminal = Self.terminalWithKeyboard else { return }
            // The terminal finds but doesn't replace.
            terminal.performTextFinderAction(Self.finderItem(command == .replace ? .showFindInterface : command.finderAction))
        case let .chat(id)?:
            let find = feed(id).find
            switch command {
            case .find: find.open()
            case .next: find.next()
            case .previous: find.previous()
            case .replace, .useSelection: break
            }
        case let .review(id)?:
            let find = ReviewStore.shared.review(id).find
            switch command {
            case .find: find.open()
            case .next: find.next()
            case .previous: find.previous()
            case .replace, .useSelection: break
            }
        case .file?:
            guard let text = activeFileDocument?.textView else { NSSound.beep(); return }
            // Stepping with the bar closed selects in the text, so the keyboard goes there too.
            if command == .next || command == .previous, text.enclosingScrollView?.isFindBarVisible != true {
                text.window?.makeFirstResponder(text)
            }
            text.performTextFinderAction(Self.finderItem(command.finderAction))
        case .fileSearch?:
            stepFileSearch(command == .previous ? -1 : 1)
        case nil:
            NSSound.beep()
        }
    }

    /// The terminal the keyboard is in, its find bar included.
    private static var terminalWithKeyboard: TerminalView? {
        var view = NSApp.keyWindow?.firstResponder as? NSView
        while let current = view {
            if let terminal = current as? TerminalView { return terminal }
            view = current.superview
        }
        return nil
    }

    /// AppKit's find actions read what to do from the sender's tag.
    private static func finderItem(_ action: NSTextFinder.Action) -> NSMenuItem {
        let item = NSMenuItem()
        item.tag = action.rawValue
        return item
    }
}

private extension FindCommand {
    var finderAction: NSTextFinder.Action {
        switch self {
        case .find: .showFindInterface
        case .replace: .showReplaceInterface
        case .next: .nextMatch
        case .previous: .previousMatch
        case .useSelection: .setSearchString
        }
    }
}
