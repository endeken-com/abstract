import Foundation

/// What can be done to several picked chats at once (ABS-206), and which of
/// them each action fits: archiving skips the archived ones, pinning skips
/// chats on another Mac (pins are this Mac's), and so on.
public enum BulkChatAction: String, CaseIterable, Sendable, Hashable {
    case archive, unarchive, pin, unpin, delete

    /// A picked chat, as far as the actions care.
    public struct Item: Sendable, Hashable {
        public var id: String
        public var archived: Bool
        public var pinned: Bool
        /// On a paired Mac: it acts there, and can't be pinned here.
        public var remote: Bool
        /// Its agent is at work, and archiving stops it.
        public var working: Bool

        public init(id: String, archived: Bool, pinned: Bool, remote: Bool = false, working: Bool = false) {
            self.id = id; self.archived = archived; self.pinned = pinned; self.remote = remote; self.working = working
        }

        public init(_ session: Session, remote: Bool = false, working: Bool? = nil) {
            self.init(id: session.id, archived: session.archivedAt != nil, pinned: session.pinnedAt != nil,
                      remote: remote, working: working ?? [.running, .provisioning].contains(session.status))
        }
    }

    public func fits(_ item: Item) -> Bool {
        switch self {
        case .archive: !item.archived
        case .unarchive: item.archived
        case .pin: !item.pinned && !item.remote
        case .unpin: item.pinned && !item.remote
        case .delete: true
        }
    }

    /// The picked chats it acts on, in their order.
    public func targets(_ items: [Item]) -> [String] { items.filter(fits).map(\.id) }

    /// The actions offered for `items`: each one that fits any of them.
    public static func offered(_ items: [Item]) -> [BulkChatAction] {
        allCases.filter { action in items.contains(where: action.fits) }
    }

    /// Its menu title: "Archive" for one chat, "Archive 3 Chats" when it
    /// fits them all, "Archive 3 of 5" when it fits only some.
    public func title(fitting: Int, of picked: Int) -> String {
        let verb = switch self {
        case .archive: "Archive"
        case .unarchive: "Unarchive"
        case .pin: "Pin"
        case .unpin: "Unpin"
        case .delete: "Delete"
        }
        let ellipsis = self == .delete ? "…" : ""
        if picked <= 1 { return verb + ellipsis }
        if fitting == picked { return "\(verb) \(picked) Chats\(ellipsis)" }
        return "\(verb) \(fitting) of \(picked)\(ellipsis)"
    }

    public func title(for items: [Item]) -> String { title(fitting: targets(items).count, of: items.count) }

    /// The one question before archiving `count` chats, `working` of them at
    /// work (their agents are stopped).
    public static func archiveConfirmation(count: Int, working: Int) -> (title: String, message: String) {
        var message = count == 1 ? "It moves to Archived, and its worktree stays." : "They move to Archived, and their worktrees stay."
        if working > 0 {
            message += " " + (count == 1 ? "Its agent is working and will be stopped."
                : working == 1 ? "1 of them is working; its agent will be stopped."
                : "\(working) of them are working; their agents will be stopped.")
        }
        message += " You can unarchive \(count == 1 ? "it" : "them") at any time."
        return (title: "Archive \(BulkChatDelete.chats(count))?", message: message)
    }
}

extension SidebarChats {
    /// Every chat id the rail shows, top to bottom: what ⇧-click runs over
    /// and ⌘A picks. By status, each group's chats (Done's older ones when
    /// shown); by project, each expanded project's, then Standalone, then
    /// `remote`, the paired Macs' chats as their groups show them.
    public static func shownOrder(_ chats: [Chat], arrangement: Arrangement, showOlder: Bool = false,
                                  projects: [String] = [], collapsed: Set<String> = [], remote: [String] = []) -> [String] {
        let order: [String]
        switch arrangement {
        case .status:
            order = sections(chats).flatMap { $0.chats + (showOlder ? $0.older : []) }.map(\.id)
        case .project:
            let groups = groupedByProject(chats.filter { !$0.isRemote })
            order = projects.flatMap { collapsed.contains($0) ? [] : (groups[$0] ?? []).map(\.id) }
                + (groups[nil] ?? []).map(\.id) + remote
        }
        var seen = Set<String>()
        return order.filter { seen.insert($0).inserted }
    }
}
