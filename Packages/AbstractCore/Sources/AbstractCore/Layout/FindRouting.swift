import Foundation

/// The Edit menu's Find items.
public enum FindCommand: Sendable, CaseIterable {
    /// ⌘F
    case find
    /// ⌥⌘F
    case replace
    /// ⌘G
    case next
    /// ⇧⌘G
    case previous
    /// ⌘E
    case useSelection
}

/// What a Find item acts on.
public enum FindTarget: Hashable, Sendable {
    /// The terminal that has the keyboard, with its own find.
    case terminal
    case chat(sessionId: String)
    /// The file open in a tab, in the editor's find bar.
    case file(sessionId: String, path: String)
    /// The Review tab's find bar over the diff.
    case review(sessionId: String)
    /// ⌘G through the Files tab's search results (⇧⌘F).
    case fileSearch(sessionId: String)
}

/// What's in front when a Find item is chosen, and so where it goes: the
/// terminal when it has the keyboard, else whatever the main pane shows.
public struct FindFront: Sendable, Equatable {
    public var activeTab: MainTabKind?
    public var selectedSession: String?
    /// The keyboard is in a terminal, or in its find bar.
    public var terminalHasKeyboard = false
    public var chatFindOpen = false
    public var reviewFindOpen = false
    /// The editor's find bar shows over the file in front.
    public var fileFindOpen = false
    /// The Files tab's search has matches to step through.
    public var fileSearchHasMatches = false

    public init(activeTab: MainTabKind? = nil, selectedSession: String? = nil) {
        self.activeTab = activeTab
        self.selectedSession = selectedSession
    }

    /// What the main pane shows for the chat the window is on.
    public var reading: FindTarget? {
        guard let id = selectedSession else { return nil }
        switch activeTab {
        case let .file(sessionId, path)? where sessionId == id: return .file(sessionId: id, path: path)
        case let .diff(sessionId)? where sessionId == id: return .review(sessionId: id)
        default: return .chat(sessionId: id)
        }
    }

    public func target(for command: FindCommand) -> FindTarget? {
        if terminalHasKeyboard { return .terminal }
        guard let reading, let id = selectedSession else { return nil }
        let search: FindTarget? = fileSearchHasMatches ? .fileSearch(sessionId: id) : nil
        switch (command, reading) {
        case (.find, _):
            return reading
        // Only a file is edited here; the chat and the review are read.
        case (.replace, .file), (.useSelection, .file):
            return reading
        case (.replace, _), (.useSelection, _):
            return nil
        case (.next, .file), (.previous, .file):
            // With its find bar closed, the file still finds the last words found.
            return fileFindOpen || search == nil ? reading : search
        case (.next, .chat), (.previous, .chat):
            return chatFindOpen ? reading : search
        case (.next, .review), (.previous, .review):
            return reviewFindOpen ? reading : search
        case (.next, _), (.previous, _):
            return search
        }
    }
}
