import Foundation

/// How many sub-tasks one chat may start, set in Settings › Agents
/// (ABS-214). Depth stays at two and isn't a setting. Until per-tree
/// budgets exist (ABS-116) these caps are the spending guardrail (ABS-99 §4).
public enum SubtaskLimit {
    public static let range = 1...20
    public static let defaultPerChat = 5

    public static func clamped(_ value: Int) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// Why `parentId` can't start another sub-task under `limit`, or nil
    /// when it can. Lowering the limit never touches sub-tasks that already
    /// exist; it only refuses new ones over it.
    public static func refusal(parentId: String, sessions: [Session], limit: Int) -> String? {
        let limit = clamped(limit)
        guard sessions.count(where: { $0.parentSessionId == parentId }) >= limit else { return nil }
        return "A chat can have at most \(limit) \(limit == 1 ? "sub-task" : "sub-tasks") (Settings › Agents)."
    }
}
