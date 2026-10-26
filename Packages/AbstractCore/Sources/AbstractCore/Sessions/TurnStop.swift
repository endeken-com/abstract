import Foundation

/// What Stop does to a chat's agent. Stopping is something you ask for, so
/// it never reads as a failure: the transcript gets a quiet "Stopped" rule
/// and the chat waits for your next message.
public enum TurnStop {
    public enum Action: Sendable, Equatable {
        /// Write this line: the agent ends its turn and stays alive.
        case interrupt(String)
        /// End the agent's process.
        case terminate
    }

    /// How long an interrupted agent has to end its turn before its process is ended.
    public static let grace: Duration = .seconds(5)

    public static let rule: AgentEvent = .turnEnd(durationMs: nil, costUsd: nil, usage: nil, summary: "Stopped")

    /// A turn you stopped, as the chat reads it.
    public static let events: [AgentEvent] = [rule, .status(.idle, detail: nil)]

    /// Mid-turn, an agent that can be interrupted (Claude) ends just the
    /// turn. Any other agent, or one between turns, has its process ended.
    public static func action(_ provider: any ProviderDefinition, status: SessionStatus, requestId: String) -> Action {
        guard provider.followUpMode == .stdin, status == .running || status == .waitingInput,
              let line = provider.buildInterrupt(requestId: requestId) else { return .terminate }
        return .interrupt(line)
    }
}
