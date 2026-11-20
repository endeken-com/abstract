import Foundation

// Linking issues in a chat that runs on another Mac (ABS-215). Tracker links
// are kept per Mac, and the issue is for that Mac's agent, so the composer
// asks that Mac, through the requests the phone uses (ABS-211): its
// trackers, its links, its code host. This Mac's own are never used for it.

/// Where a composer's issue and pull request buttons ask.
public enum IssueLinkPlace: Equatable, Sendable {
    /// This Mac's trackers and code host.
    case here
    /// A paired Mac's, about its own project and chat (its ids, not this Mac's).
    case mac(device: String, projectId: String?, chatId: String?)

    /// A chat from another Mac links through that Mac, whatever project ids
    /// this Mac has; so does a new chat in a project that lives on another
    /// Mac. Anything else is this Mac's.
    public static func of(chat: (device: String, session: String)?, chatProjectId: String?, projectId: String?,
                          isLocalProject: (String) -> Bool, deviceOfProject: (String) -> String?) -> IssueLinkPlace {
        if let chat { return .mac(device: chat.device, projectId: projectId ?? chatProjectId, chatId: chat.session) }
        guard let id = projectId ?? chatProjectId, !isLocalProject(id), let device = deviceOfProject(id) else { return .here }
        return .mac(device: device, projectId: id, chatId: nil)
    }
}

/// Asks a paired Mac about one of its chats or projects.
public struct RemoteIssueLinking: Sendable {
    public typealias Ask = @Sendable (RemoteRequest) async throws -> RemoteResponse

    /// The other Mac's name, for the sentences that name it.
    public var macName: String
    public var projectId: String?
    public var chatId: String?
    private let ask: Ask

    public init(macName: String, projectId: String?, chatId: String?, ask: @escaping Ask) {
        self.macName = macName; self.projectId = projectId; self.chatId = chatId; self.ask = ask
    }

    /// Whether the Mac takes the issue requests. One that doesn't would
    /// drop the connection on them, so it isn't asked.
    public static func answers(_ snapshot: RemoteSnapshot?) -> Bool { snapshot?.issueSearch == true }

    /// What the buttons say, disabled, for a Mac that doesn't.
    public static func updateSentence(macName: String) -> String {
        "Update Abstract on \(macName) to link issues from here."
    }

    /// Its trackers for the project (its links, or every one when it has
    /// none) and its code host. `iconVersions` names the icons already here.
    public func sources(iconVersions: [String: String] = [:]) async throws -> RemoteIssueSources {
        switch try await ask(.issueSources(projectId: projectId, chatId: chatId, iconVersions: iconVersions)) {
        case .issueSources(let sources): return sources
        case let other: throw Self.problem(other)
        }
    }

    /// Its trackers' results, within the project's links unless `searchAll`.
    public func search(_ query: String, searchAll: Bool) async throws -> [RemoteIssueGroup] {
        switch try await ask(.searchIssues(projectId: projectId, chatId: chatId, trackerId: nil, query: query, searchAll: searchAll)) {
        case .issueGroups(let groups): return groups
        case let other: throw Self.problem(other)
        }
    }

    /// The picked issue whole, as its tracker there answers; as it was
    /// listed if that fails, like the Mac's own composer.
    public func complete(_ attachment: PromptAttachment) async -> PromptAttachment {
        guard case .attachment(let whole)? = try? await ask(.completeIssue(attachment)) else { return attachment }
        return whole
    }

    /// Its code host's issues or pull requests for the project.
    public func searchCodeHost(_ query: String, pullRequests: Bool) async throws -> RemoteIssueGroup {
        switch try await ask(.searchCodeHost(projectId: projectId, chatId: chatId, query: query, pullRequests: pullRequests)) {
        case .issueGroups(let groups):
            guard let group = groups.first else { throw AbstractError.message("\(macName) found no code host for this project.") }
            return group
        case let other: throw Self.problem(other)
        }
    }

    private static func problem(_ response: RemoteResponse) -> AbstractError {
        if case .failed(let message) = response { return .message(message) }
        return .message("The other Mac answered something unexpected.")
    }
}

/// Each chat's or project's sources from a paired Mac, kept until that Mac
/// says a tracker link changed, so the composer doesn't wait on the network
/// each time it opens.
public struct RemoteIssueSourceCache: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public var sources: RemoteIssueSources
        public var revision: Int?
        public var fetchedAt: Date
    }

    /// How long sources from a Mac that sends no revision are kept.
    public static let unversionedLifetime: TimeInterval = 60

    public private(set) var entries: [String: Entry] = [:]
    /// The tracker icons received, by plugin id: their versions.
    public private(set) var iconVersions: [String: String] = [:]

    public init() {}

    public static func key(projectId: String?, chatId: String?) -> String {
        chatId.map { "chat:" + $0 } ?? "project:" + (projectId ?? "")
    }

    /// The last answer, even one being asked for again.
    public func sources(_ key: String) -> RemoteIssueSources? { entries[key]?.sources }

    /// Whether the last answer still holds for the Mac's `revision` now.
    public func isFresh(_ key: String, revision: Int?, now: Date = Date()) -> Bool {
        guard let entry = entries[key] else { return false }
        if let revision { return entry.revision == revision }
        return entry.revision == nil && now.timeIntervalSince(entry.fetchedAt) < Self.unversionedLifetime
    }

    public mutating func store(_ sources: RemoteIssueSources, for key: String, revision: Int?, at date: Date = Date()) {
        entries[key] = Entry(sources: sources, revision: revision, fetchedAt: date)
        for tracker in sources.trackers + (sources.others ?? []) where tracker.icon != nil {
            iconVersions[tracker.id] = tracker.version
        }
    }
}

extension ProjectIssueTrackers {
    /// A paired Mac's trackers for one of its projects, as its composer
    /// shows them: its links, and every tracker that's on there.
    public init(_ sources: RemoteIssueSources) {
        let resolve = { (tracker: RemoteIssueTracker) in
            ResolvedIssueTracker(pluginId: tracker.id,
                                 declaration: PluginIssueTrackerDeclaration(title: tracker.title, keyExample: tracker.keyExample))
        }
        let all = (sources.trackers + (sources.others ?? [])).map(resolve)
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        var links: [String: TrackerProjectLink] = [:]
        if sources.linked {
            for tracker in sources.trackers {
                links[tracker.id] = TrackerProjectLink(project: .init(id: tracker.linkKey ?? tracker.link ?? tracker.id,
                                                                      name: tracker.link ?? tracker.title, key: tracker.linkKey))
            }
        }
        self.init(available: all, links: links)
    }
}
