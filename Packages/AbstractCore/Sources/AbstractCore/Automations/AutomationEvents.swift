import Foundation

/// Something that happened to a chat, as automations hear of it.
public struct AutomationEventOccurrence: Sendable, Hashable {
    public var event: AutomationEvent
    public var sessionId: String
    public var projectId: String?
    /// Automations whose runs led to this chat's latest turn, directly or
    /// through other runs. None of them is started again by it, so
    /// automations can't keep starting each other.
    public var chain: Set<String>

    public init(event: AutomationEvent, sessionId: String, projectId: String?, chain: Set<String> = []) {
        self.event = event; self.sessionId = sessionId; self.projectId = projectId; self.chain = chain
    }
}

/// Which automations an event starts, apart from starting them.
public enum AutomationEvents {
    /// Enabled automations listening for the event, in the chat's project
    /// (or any, for one with no project), that didn't lead to it.
    public static func automations(for occurrence: AutomationEventOccurrence, in automations: [Automation]) -> [Automation] {
        automations.filter { a in
            a.enabled && a.events.contains(occurrence.event)
                && (a.projectId == nil || a.projectId == occurrence.projectId)
                && !occurrence.chain.contains(a.id)
        }
    }

    /// A chat's pull request as the events read it.
    public struct PullRequestMark: Sendable, Hashable {
        public var number: Int
        public var state: PullRequest.State
        /// When it was opened, and last changed on GitHub.
        public var createdAt: Date?
        public var updatedAt: Date?

        public init(number: Int, state: PullRequest.State, createdAt: Date? = nil, updatedAt: Date? = nil) {
            self.number = number; self.state = state; self.createdAt = createdAt; self.updatedAt = updatedAt
        }

        var seen: String { "\(number):\(state.rawValue)" }
    }

    /// Pull request changes worth an event, from what was seen of each
    /// chat's pull request before (`"<number>:<STATE>"` by chat id) and
    /// what is known now. One not seen before counts only when it opened
    /// (or, merged, last changed) after `since`, when Abstract started
    /// watching: the ones already there aren't news. Returns the events
    /// and what is seen now; a chat missing from `now` (not listed yet)
    /// keeps what was seen of it.
    public static func pullRequestChanges(seen: [String: String], now: [String: PullRequestMark], since: Date)
        -> (events: [(sessionId: String, event: AutomationEvent)], seen: [String: String]) {
        var updated = seen
        var events: [(String, AutomationEvent)] = []
        for (sessionId, pr) in now.sorted(by: { $0.key < $1.key }) {
            let before = seen[sessionId]
            updated[sessionId] = pr.seen
            guard before != pr.seen else { continue }
            let beforeNumber = before?.split(separator: ":").first.flatMap { Int($0) }
            switch pr.state {
            case .open where beforeNumber != pr.number:
                if before != nil || (pr.createdAt ?? .distantPast) > since { events.append((sessionId, .pullRequestOpened)) }
            case .merged:
                if before != nil || (pr.updatedAt ?? .distantPast) > since { events.append((sessionId, .pullRequestMerged)) }
            default: break
            }
        }
        return (events, updated)
    }

    /// One line for the run history and the list, e.g. "When a chat is archived".
    public static func summary(_ events: [AutomationEvent]) -> String? {
        guard !events.isEmpty else { return nil }
        let phrases = events.map(\.phrase)
        let joined = phrases.count == 1 ? phrases[0]
            : phrases.dropLast().joined(separator: ", ") + " or " + phrases.last!
        return "When a chat \(joined)"
    }
}
