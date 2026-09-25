import Foundation

/// Whether a just-started agent is working, from what it prints: the same
/// test wherever it runs, in the app or in `abstract`'s host. An agent prints
/// its setup before it ever reaches its model, so an error then (not signed
/// in, a limit reached) is a failed start.
public enum AgentStart {
    public enum Outcome: Equatable, Sendable {
        case up
        case failed(String)
    }

    /// How long an agent gets to show it's working; past it, it counts as up.
    public static let timeout: TimeInterval = 30

    /// From the events of one line the agent printed on stdout; nil while
    /// they say nothing either way.
    public static func outcome(of events: [AgentEvent], agentName: String) -> Outcome? {
        for event in events {
            switch event {
            case let .error(message):
                return .failed(message)
            case .status(.errored, _):
                return .failed("\(agentName) reported an error before it started.")
            case .status(.running, _), .status(.idle, _), .status(.waitingInput, _), .text, .thinking, .toolUse, .turnEnd,
                 .permissionRequest:
                return .up
            default:
                continue
            }
        }
        return nil
    }
}
