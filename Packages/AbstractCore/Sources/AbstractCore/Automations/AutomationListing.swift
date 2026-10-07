import Foundation

/// Which automations the Automations list shows.
public struct AutomationFilter: Sendable, Hashable {
    public enum ProjectChoice: Sendable, Hashable {
        case all
        /// Automations whose chats stand alone.
        case noProject
        case only(String)

        /// "" for all, "none" for No project, otherwise the project's id.
        public init(stored: String) {
            switch stored {
            case "": self = .all
            case "none": self = .noProject
            default: self = .only(stored)
            }
        }

        public var stored: String {
            switch self {
            case .all: ""
            case .noProject: "none"
            case .only(let id): id
            }
        }
    }

    public enum State: String, Sendable, CaseIterable {
        case all, active, paused
        /// On, but with no schedule: it runs only when started by hand.
        case manual
    }

    public var project: ProjectChoice
    /// nil for every agent.
    public var providerId: String?
    public var state: State

    public init(project: ProjectChoice = .all, providerId: String? = nil, state: State = .all) {
        self.project = project; self.providerId = providerId; self.state = state
    }

    /// Whether anything is hidden by choice.
    public var isOn: Bool { self != AutomationFilter() }
}

/// The automations of one project, as the list shows them.
public struct AutomationSection: Sendable, Hashable, Identifiable {
    /// nil for "No project".
    public let project: Project?
    public let automations: [Automation]
    public var id: String { project?.id ?? "" }
}

/// The Automations list as a pure function: grouped by project in the
/// sidebar's order, filtered, and sorted within each project.
public enum AutomationListing {
    /// The project an automation belongs to: a pinned chat's own project,
    /// otherwise where its new chats start.
    public static func projectId(of a: Automation, sessions: [Session]) -> String? {
        if a.workspaceMode == .pinned, let id = a.pinnedSessionId, let chat = sessions.first(where: { $0.id == id }) {
            return chat.projectId
        }
        return a.projectId
    }

    /// One section per project with automations left after `filter`, in the
    /// order of `projects`, then "No project". Unknown projects count as none.
    public static func sections(_ automations: [Automation], projects: [Project], sessions: [Session],
                                filter: AutomationFilter) -> [AutomationSection] {
        let known = Set(projects.map(\.id))
        let byProject = Dictionary(grouping: automations) { a in
            projectId(of: a, sessions: sessions).flatMap { known.contains($0) ? $0 : nil }
        }
        let groups: [(Project?, [Automation])] = projects.map { ($0, byProject[$0.id] ?? []) } + [(nil, byProject[nil] ?? [])]
        return groups.compactMap { project, automations in
            guard matches(project?.id, filter.project) else { return nil }
            let shown = automations.filter { matches($0, filter) }.sorted(by: listOrder)
            return shown.isEmpty ? nil : AutomationSection(project: project, automations: shown)
        }
    }

    private static func matches(_ projectId: String?, _ choice: AutomationFilter.ProjectChoice) -> Bool {
        switch choice {
        case .all: true
        case .noProject: projectId == nil
        case .only(let id): projectId == id
        }
    }

    private static func matches(_ a: Automation, _ filter: AutomationFilter) -> Bool {
        if let providerId = filter.providerId, a.providerId != providerId { return false }
        return switch filter.state {
        case .all: true
        case .active: isScheduled(a)
        case .paused: !a.enabled
        case .manual: a.enabled && a.triggers.isEmpty
        }
    }

    /// On and with a schedule to keep.
    private static func isScheduled(_ a: Automation) -> Bool { a.enabled && !a.triggers.isEmpty }

    /// Scheduled ones first, soonest run first (none yet last); then the
    /// paused and hand-run ones by name.
    private static func listOrder(_ a: Automation, _ b: Automation) -> Bool {
        let (sa, sb) = (isScheduled(a), isScheduled(b))
        if sa != sb { return sa }
        if sa, a.nextRunAt != b.nextRunAt {
            guard let na = a.nextRunAt else { return false }
            guard let nb = b.nextRunAt else { return true }
            return na < nb
        }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}
