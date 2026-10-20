import Foundation

/// What "Pause everything" (or pausing one project) turned off, so Resume
/// turns back on exactly that and nothing you had paused yourself. Agents are
/// stopped when it happens and never restarted by it; this only remembers
/// automations. Kept across launches, like the automations' own paused state.
public struct PauseState: Sendable, Hashable, Codable {
    /// Everything, or one project's chats and automations.
    public enum Scope: Sendable, Hashable {
        case all
        case project(String)
    }

    public private(set) var everythingPaused = false
    public private(set) var pausedProjectIds: Set<String> = []
    /// Automations a pause switched off, to switch back on at its resume.
    public private(set) var automationIds: Set<String> = []

    public init() {}

    public func isPaused(_ scope: Scope) -> Bool {
        switch scope {
        case .all: everythingPaused
        case .project(let id): everythingPaused || pausedProjectIds.contains(id)
        }
    }

    /// Whether anything at all is paused this way.
    public var isPaused: Bool { everythingPaused || !pausedProjectIds.isEmpty }

    /// Pause `scope`: returns the ids of the automations to switch off (the
    /// active ones in scope), remembering them. Ones already off — paused by
    /// hand, or by an earlier pause — are left out, so they're never restored.
    @discardableResult
    public mutating func pause(_ scope: Scope, automations: [Automation], sessions: [Session]) -> [String] {
        prune(automations)
        switch scope {
        case .all: everythingPaused = true
        case .project(let id): pausedProjectIds.insert(id)
        }
        let ids = automations.filter { $0.enabled && contains($0, in: scope, sessions: sessions) }.map(\.id)
        automationIds.formUnion(ids)
        return ids
    }

    /// Resume `scope`: returns the remembered ids to switch back on.
    /// Resuming everything clears every pause. Resuming one project while
    /// everything is paused only lifts its own mark; its automations come
    /// back when everything resumes.
    @discardableResult
    public mutating func resume(_ scope: Scope, automations: [Automation], sessions: [Session]) -> [String] {
        prune(automations)
        switch scope {
        case .all:
            defer { everythingPaused = false; pausedProjectIds = []; automationIds = [] }
            return Array(automationIds)
        case .project(let id):
            pausedProjectIds.remove(id)
            guard !everythingPaused else { return [] }
            let ids = automations.filter { automationIds.contains($0.id) && contains($0, in: scope, sessions: sessions) }.map(\.id)
            automationIds.subtract(ids)
            return ids
        }
    }

    /// You switched this automation yourself, so a later resume leaves it as you put it.
    public mutating func forget(automationId: String) { automationIds.remove(automationId) }

    /// The chats a pause of `scope` stops.
    public static func sessions(in scope: Scope, from sessions: [Session]) -> [Session] {
        switch scope {
        case .all: sessions
        case .project(let id): sessions.filter { $0.projectId == id }
        }
    }

    private func contains(_ a: Automation, in scope: Scope, sessions: [Session]) -> Bool {
        switch scope {
        case .all: true
        case .project(let id): AutomationListing.projectId(of: a, sessions: sessions) == id
        }
    }

    /// Forget automations that no longer exist, so resume never chases them.
    private mutating func prune(_ automations: [Automation]) {
        automationIds.formIntersection(Set(automations.map(\.id)))
    }
}
