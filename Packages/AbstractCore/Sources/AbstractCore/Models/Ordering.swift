import Foundation

/// Reordering by drag and drop, as a pure function of ids.
public enum Ordering {
    /// `ids` with `moving` placed just before `target`, or just after it.
    /// Unknown ids, or dropping something on itself, change nothing.
    public static func move(_ moving: String, in ids: [String], to target: String, after: Bool) -> [String] {
        guard moving != target, let from = ids.firstIndex(of: moving), ids.contains(target) else { return ids }
        var order = ids
        order.remove(at: from)
        guard let index = order.firstIndex(of: target) else { return ids }
        order.insert(moving, at: after ? index + 1 : index)
        return order
    }

    /// Pinned chats first, in the order they were pinned; the rest keep their order.
    public static func pinnedFirst(_ sessions: [Session]) -> [Session] {
        let pinned = sessions.filter { $0.pinnedAt != nil }.sorted { $0.pinnedAt! < $1.pinnedAt! }
        return pinned + sessions.filter { $0.pinnedAt == nil }
    }
}
