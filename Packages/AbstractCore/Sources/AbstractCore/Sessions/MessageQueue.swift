import Foundation

/// A message you sent while the agent worked. It waits above the composer,
/// where you can edit or remove it, and goes as the next turn.
public struct QueuedMessage: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var text: String
    public var attachments: [PromptAttachment]
    public var queuedAt: Date
    /// Being written to the chat's log. A relaunch that finds this set looks
    /// in the log to tell whether it went.
    public var sending: Bool?

    public init(id: String = UUID().uuidString, text: String, attachments: [PromptAttachment] = [], queuedAt: Date = Date()) {
        self.id = id
        self.text = text
        self.attachments = attachments
        self.queuedAt = queuedAt
    }
}

/// What happens to a message you send, by how the agent reads them.
public enum FollowUp {
    public enum Route: Sendable, Equatable {
        /// The agent is between turns: it goes now.
        case send
        /// The agent is mid-turn: it waits for the turn to end.
        case queue
    }

    /// Mid-turn, a message waits. An agent that reads stdin (Claude) is
    /// mid-turn while it runs or asks you something, or while it restarts;
    /// one that runs a process per turn (Codex) for as long as that process
    /// lives. `mode` is the agent whose process it is.
    public static func route(_ mode: FollowUpMode, alive: Bool, status: SessionStatus, handingOff: Bool = false) -> Route {
        if handingOff { return .queue }
        switch mode {
        case .stdin: return alive ? (working(status) ? .queue : .send) : (status == .running ? .queue : .send)
        case .respawn: return alive || status == .running ? .queue : .send
        }
    }

    /// Steer reaches only an agent that reads messages mid-turn.
    public static func canSteer(_ mode: FollowUpMode, alive: Bool, status: SessionStatus) -> Bool {
        mode == .stdin && alive && working(status)
    }

    /// Why Steer is greyed out for an agent, or nil when it can steer.
    public static func steerUnavailable(_ provider: any ProviderDefinition) -> String? {
        provider.followUpMode == .stdin ? nil : "\(provider.name) reads messages between turns"
    }

    /// Whether the queue goes when a turn ends: after one that finished or
    /// one you interrupted. After Stop or a failure it waits for you.
    public static func sendsQueue(after status: SessionStatus, stopped: Bool, interrupting: Bool) -> Bool {
        guard status == .idle || status == .finished else { return false }
        return !stopped || interrupting
    }

    private static func working(_ status: SessionStatus) -> Bool {
        status == .running || status == .waitingInput
    }

    /// The queue as one message: in order, a blank line apart, with all their attachments.
    public static func joined(_ messages: [QueuedMessage]) -> (text: String, attachments: [PromptAttachment]) {
        let text = messages.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return (text.joined(separator: "\n\n"), messages.flatMap(\.attachments))
    }
}
