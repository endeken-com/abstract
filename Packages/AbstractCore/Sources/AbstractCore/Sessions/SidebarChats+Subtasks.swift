import Foundation

/// Folding a chat's sub-tasks away in the rail (ABS-213). The rail lays its
/// chats out as before, sub-tasks and all, then leaves out the ones under a
/// collapsed chat, so a chain keeps the group its most urgent member gives it
/// and a collapsed chat can still say what it hides.
extension SidebarChats {
    /// What a chat with sub-tasks shows about them: its chevron, and while
    /// they're hidden, what among them needs you or is at work.
    public struct Fold: Sendable, Hashable {
        /// Kept collapsed: its chevron points right.
        public var collapsed: Bool
        /// Its sub-tasks, at every depth, left out of the rail right now.
        public var hidden: Int = 0
        /// Hidden sub-tasks waiting for you, failed or stalled.
        public var needYou: Int = 0
        /// A hidden sub-task is at work.
        public var working = false

        public init(collapsed: Bool, hidden: Int = 0, needYou: Int = 0, working: Bool = false) {
            self.collapsed = collapsed; self.hidden = hidden; self.needYou = needYou; self.working = working
        }

        /// The collapsed chat's own line about them: "1 sub-task needs you".
        public var summary: String? {
            switch needYou {
            case 0: nil
            case 1: "1 sub-task needs you"
            default: "\(needYou) sub-tasks need you"
            }
        }
    }

    /// Which of the rail's chats a collapsed chat hides, and each parent's `Fold`.
    public struct Folding: Sendable, Hashable {
        /// Chats left out of the rail.
        public var hidden: Set<String> = []
        /// Every chat with sub-tasks among the rail's chats, by id.
        public var folds: [String: Fold] = [:]

        public init(hidden: Set<String> = [], folds: [String: Fold] = [:]) { self.hidden = hidden; self.folds = folds }
    }

    /// `chats` (the rail's, after search and filters) folded by `collapsed`:
    /// a collapsed chat hides its whole subtree. While a search or filter
    /// narrows the rail (`narrowed`), every chat it let through shows, since
    /// each is a match or leads to one; what's remembered doesn't change.
    public static func folding(_ chats: [Chat], collapsed: Set<String>, narrowed: Bool = false) -> Folding {
        let byID = Dictionary(chats.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var children: [String: [Chat]] = [:]
        for chat in chats {
            if let parent = chat.session.parentSessionId, parent != chat.id, byID[parent] != nil {
                children[parent, default: []].append(chat)
            }
        }

        /// Everything under `id`, once each, however its links loop.
        func subtree(_ id: String) -> [Chat] {
            var seen: Set<String> = [id], result: [Chat] = [], stack = children[id] ?? []
            while let chat = stack.popLast() {
                guard seen.insert(chat.id).inserted else { continue }
                result.append(chat)
                stack.append(contentsOf: children[chat.id] ?? [])
            }
            return result
        }

        var folding = Folding()
        for id in children.keys {
            let isCollapsed = collapsed.contains(id)
            var fold = Fold(collapsed: isCollapsed)
            if isCollapsed && !narrowed {
                let under = subtree(id)
                fold.hidden = under.count
                fold.needYou = under.count(where: needsYou)
                fold.working = under.contains(where: isWorking)
                folding.hidden.formUnion(under.map(\.id))
            }
            folding.folds[id] = fold
        }
        return folding
    }

    /// Waiting for an answer or permission, failed, or stalled.
    static func needsYou(_ chat: Chat) -> Bool {
        chat.stalled || chat.session.status == .waitingInput || chat.session.status == .errored
    }

    static func isWorking(_ chat: Chat) -> Bool {
        chat.session.status == .running || chat.session.status == .provisioning || chat.backgroundTasks > 0
    }

    /// `collapsed` with every ancestor of `id` taken out, so `id` shows:
    /// opening a hidden sub-task unfolds the chats above it.
    public static func revealing(_ id: String, in collapsed: Set<String>, parent: (String) -> String?) -> Set<String> {
        var result = collapsed, seen: Set<String> = [id], next = parent(id)
        while let ancestor = next, seen.insert(ancestor).inserted {
            result.remove(ancestor)
            next = parent(ancestor)
        }
        return result
    }

    /// Remembered collapsed chats that still exist: deleted chats' ids go.
    public static func pruned(_ collapsed: Set<String>, existing: some Sequence<String>) -> Set<String> {
        collapsed.intersection(existing)
    }
}
