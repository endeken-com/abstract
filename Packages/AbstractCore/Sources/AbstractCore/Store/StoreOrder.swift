import Foundation

/// The app's lists kept as the store lists them, so saving one record
/// updates its one entry instead of reading every table again (ABS-184).
public enum StoreOrder {
    /// `Store.sessions()`'s order: latest activity first, then newest.
    public static func sessionPrecedes(_ a: Session, _ b: Session) -> Bool {
        (a.lastEventAt ?? a.createdAt, a.createdAt) > (b.lastEventAt ?? b.createdAt, b.createdAt)
    }

    /// `Store.projects()`'s order: as arranged, then oldest first.
    public static func projectPrecedes(_ a: Project, _ b: Project) -> Bool {
        (a.sortOrder, a.createdAt) < (b.sortOrder, b.createdAt)
    }

    /// `Store.automations()`'s order: oldest first.
    public static func automationPrecedes(_ a: Automation, _ b: Automation) -> Bool {
        a.createdAt < b.createdAt
    }

    /// `list` with `item` saved: its entry replaced where it was, or a new
    /// one inserted before the first entry it precedes. Nothing else moves.
    public static func saving<T: Identifiable>(_ item: T, in list: [T], precedes: (T, T) -> Bool) -> [T] {
        var list = list
        if let i = list.firstIndex(where: { $0.id == item.id }) {
            list[i] = item
        } else {
            list.insert(item, at: list.firstIndex { precedes(item, $0) } ?? list.endIndex)
        }
        return list
    }

    /// `list` with the entries `changed` replaced, then put in order again:
    /// for changes to the order itself, as moving a project does.
    public static func reordering<T: Identifiable>(_ changed: [T], in list: [T], precedes: (T, T) -> Bool) -> [T] {
        let byId = Dictionary(changed.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        return list.map { byId[$0.id] ?? $0 }.sorted(by: precedes)
    }

    /// The chats left once `id` is deleted. The store lets go of it as their
    /// parent too, so a sub-task chat stays, standing alone.
    public static func deleting(_ id: String, from sessions: [Session]) -> [Session] {
        sessions.compactMap { s in
            guard s.id != id else { return nil }
            guard s.parentSessionId == id else { return s }
            var child = s
            child.parentSessionId = nil
            return child
        }
    }
}
