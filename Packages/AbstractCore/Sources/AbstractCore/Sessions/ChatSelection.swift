import Foundation

/// Chats picked out of a list the way Finder picks files: a click picks one,
/// ⌘-click adds or drops one, ⇧-click picks the run from the last click, and
/// Select All picks them all. Ids are kept in the list's order.
public struct ChatSelection: Sendable, Hashable {
    /// How a click picks.
    public enum Click: Sendable, Hashable {
        /// Just this one.
        case single
        /// Adds it, or drops it if it was picked (⌘).
        case toggle
        /// The run from the anchor to it (⇧).
        case extend
    }

    public private(set) var ids: [String] = []
    /// Where a ⇧-click's run starts: the last chat clicked without ⇧.
    public private(set) var anchor: String?

    public init(ids: [String] = [], anchor: String? = nil) {
        self.ids = ids
        self.anchor = anchor
    }

    public var isEmpty: Bool { ids.isEmpty }
    public var count: Int { ids.count }
    public func contains(_ id: String) -> Bool { ids.contains(id) }

    /// The selection after clicking `id` in `order`, the list as shown.
    public func clicking(_ id: String, _ click: Click, in order: [String]) -> ChatSelection {
        guard order.contains(id) else { return self }
        switch click {
        case .single:
            return ChatSelection(ids: [id], anchor: id)
        case .toggle:
            let picked = contains(id) ? Set(ids).subtracting([id]) : Set(ids).union([id])
            return ChatSelection(ids: order.filter(picked.contains), anchor: id)
        case .extend:
            guard let anchor, let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: id) else {
                return ChatSelection(ids: [id], anchor: id)
            }
            return ChatSelection(ids: Array(order[min(from, to)...max(from, to)]), anchor: anchor)
        }
    }

    /// Every chat in `order`.
    public static func all(_ order: [String]) -> ChatSelection {
        ChatSelection(ids: order, anchor: order.first)
    }

    /// Only the picked chats still in `order` (others were deleted, unarchived
    /// or filtered out), in its order.
    public func keeping(_ order: [String]) -> ChatSelection {
        let picked = Set(ids)
        let kept = order.filter(picked.contains)
        return ChatSelection(ids: kept, anchor: anchor.flatMap { order.contains($0) ? $0 : nil } ?? kept.first)
    }
}

/// Deleting several chats at once: each goes through the single delete, one
/// after another (worktrees of one repository are removed one at a time),
/// and what didn't go cleanly is reported once at the end.
public enum BulkChatDelete {
    /// How deleting one chat went.
    public enum Outcome: Sendable, Hashable {
        case deleted
        /// The chat is gone, but its worktree or folder stayed on disk.
        case leftFiles(String)
        /// The chat is still there.
        case failed(String)
    }

    public struct Report: Sendable, Hashable {
        public var requested: Int
        /// Chats that are gone, files and all.
        public var deleted: [String] = []
        /// Chats that are gone but left their worktree or folder, with why.
        public var leftFiles: [String: String] = [:]
        /// Chats that are still there, with why.
        public var failed: [String: String] = [:]

        public init(requested: Int) { self.requested = requested }

        public var removed: Int { deleted.count + leftFiles.count }
        public var isClean: Bool { leftFiles.isEmpty && failed.isEmpty }

        /// One line for the toast: "Deleted 3 chats", or what went wrong.
        public var summary: String {
            var parts = [failed.isEmpty
                ? "Deleted \(chats(removed))."
                : "Deleted \(removed) of \(chats(requested)); \(failed.count) couldn't be deleted."]
            if !leftFiles.isEmpty {
                parts.append(leftFiles.count == 1 ? "1 worktree or folder wasn't removed." : "\(leftFiles.count) worktrees or folders weren't removed.")
            }
            // The first reason, so there's something to act on.
            if let reason = failed.sorted(by: { $0.key < $1.key }).first?.value ?? leftFiles.sorted(by: { $0.key < $1.key }).first?.value {
                parts.append(reason)
            }
            return parts.joined(separator: " ")
        }
    }

    /// Deletes `ids` in order with `delete`, the single delete, on the
    /// caller's actor (the app's delete runs on the main actor).
    public static func run(_ ids: [String], isolation: isolated (any Actor)? = #isolation,
                           delete: (String) async -> Outcome) async -> Report {
        var report = Report(requested: ids.count)
        var seen = Set<String>()
        for id in ids where seen.insert(id).inserted {
            switch await delete(id) {
            case .deleted: report.deleted.append(id)
            case .leftFiles(let why): report.leftFiles[id] = why
            case .failed(let why): report.failed[id] = why
            }
        }
        report.requested = seen.count
        return report
    }

    /// The confirmation's title and text for deleting `count` chats, with
    /// how many hold submodule commits no remote has (lost with them).
    public static func confirmation(count: Int, losingSubmoduleWork: Int = 0) -> (title: String, message: String) {
        var message = (count == 1 ? "Its agent is stopped and its worktree or folder is removed."
                                  : "Their agents are stopped and their worktrees and folders are removed.")
            + " Uncommitted work in them is lost; branches are kept. This can't be undone."
        if losingSubmoduleWork > 0 {
            message += "\n\n" + (count == 1 ? "It has" : losingSubmoduleWork == 1 ? "1 of them has" : "\(losingSubmoduleWork) of them have")
                + " submodule commits no remote has, which are lost with the worktree."
        }
        return (title: "Delete \(chats(count))?", message: message)
    }

    static func chats(_ n: Int) -> String { n == 1 ? "1 chat" : "\(n) chats" }
}
