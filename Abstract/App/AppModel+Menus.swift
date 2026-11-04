import Foundation
import AbstractCore

/// What the menu bar's items show and allow. SwiftUI rebuilds every menu
/// whenever anything their commands read changes, so they read only this,
/// which changes only when an item does: not each time a chat is opened or
/// an agent writes (ABS-184). Actions read the model when chosen.
struct MenuFacts: Equatable {
    struct Chat: Equatable {
        let id: String
        let name: String
    }

    /// The window is on a chat: Find goes to it.
    var onChat = false
    /// A chat shows: its menu items apply.
    var hasChat = false
    var canStop = false
    var canResume = false
    var canRunInBackground = false
    var hasBackgroundTasks = false
    var hasFile = false
    /// An image shows: ⌘0 and ⌘1 zoom it.
    var hasImage = false
    var everythingPaused = false
    /// ⌘1 to ⌘9.
    var chats: [Chat] = []
}

extension AppModel {
    /// Keeps `menuFacts` current, from now on.
    func watchMenuFacts() {
        let facts = withObservationTracking { currentMenuFacts() } onChange: {
            Task { @MainActor [weak self] in self?.watchMenuFacts() }
        }
        if facts != menuFacts { menuFacts = facts }
    }

    private func currentMenuFacts() -> MenuFacts {
        let shown = selectedSessionId.flatMap { chatName($0) == nil ? nil : $0 }
        var facts = MenuFacts()
        facts.onChat = selectedSessionId != nil
        facts.hasChat = shown != nil
        if let shown {
            let working = isAlive(shown) || isCompactingAside(shown)
            facts.canStop = working
            facts.canResume = !working
            facts.canRunInBackground = !foregroundTasks(shown).isEmpty
            facts.hasBackgroundTasks = !backgroundTasks(shown).isEmpty
        }
        let file = activeFileDocument
        facts.hasFile = file != nil
        if let file, case .image = file.content { facts.hasImage = true }
        facts.everythingPaused = everythingPaused
        facts.chats = menuChats.map { MenuFacts.Chat(id: $0, name: chatName($0) ?? "") }
        return facts
    }
}
