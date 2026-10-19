import Foundation

/// A plan an agent wrote in Plan mode (ABS-104), kept revision by
/// revision until you approve it, ask for changes, or discard it.
public struct PlanState: Sendable, Hashable {
    public enum Status: Sendable, Hashable {
        case waiting
        case approved
        case discarded
        case changesRequested
    }

    public var revisions: [String] = []
    public var status: Status = .waiting

    public init() {}

    public var current: String? { revisions.last }
    /// Every revision but the current one, oldest first.
    public var history: [String] { Array(revisions.dropLast()) }
    /// Shown while it still needs your decision, or is being revised.
    public var isVisible: Bool {
        current != nil && (status == .waiting || status == .changesRequested)
    }

    /// A new revision waits for a fresh decision. A repeat of the
    /// current one, or an empty one, changes nothing.
    @discardableResult
    public mutating func add(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != current else { return false }
        revisions.append(text)
        status = .waiting
        return true
    }

    public mutating func approve() { status = .approved }
    public mutating func discard() { status = .discarded }
    public mutating func requestChanges() { status = .changesRequested }
}

/// Where a plan's text comes from, and the words that go with it.
public enum Plan {
    /// Told to agents with no plan mode of their own (Codex, Muse),
    /// whose sandbox keeps the turn read-only while they write it.
    public static let instruction = "Write a plan for this task, then stop. "
        + "Do not change any files. Give the complete plan as Markdown in your final reply."

    /// Told to agents in Ask (read-only) mode that have no read-only
    /// agent of their own; their sandbox enforces it regardless.
    public static let readOnlyInstruction = "This is a read-only question: "
        + "look and answer, but do not change any files."

    /// Sent when a plan is approved and the agent's turn already ended.
    public static let approveMessage = "Implement the approved plan"

    public static func isExitPlanMode(_ toolName: String) -> Bool {
        toolName.lowercased() == "exitplanmode"
    }

    /// The plan in Claude's `ExitPlanMode` input (`plan`), if there is one.
    public static func text(fromExitPlanModeInput input: JSONValue) -> String? {
        input["plan"]?.string.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    /// The final reply of a Plan-mode turn is the plan, for agents
    /// without a plan tool. Any other mode's reply is just a reply.
    public static func text(fromFinalReply reply: String, policy: PermissionPolicy) -> String? {
        guard policy == .plan else { return nil }
        return reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : reply
    }

    /// The plan as a quote, waiting in the composer for your changes.
    public static func quoted(_ plan: String) -> String {
        plan.components(separatedBy: "\n").map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n")
    }
}
