import Foundation

// Issue trackers (ABS-141): a plugin declares `contributes.issueTracker`
// and answers four questions over the bridge — whether it can reach its
// tracker, a search, one issue by key or link, and the tracker's teams and
// projects. Abstract keeps the composer's search, the attachment chip and
// the line the agent reads; the plugin only finds issues.

/// What a plugin's manifest says about the tracker it answers for.
public struct PluginIssueTrackerDeclaration: Sendable, Hashable, Codable {
    /// "Linear": the tracker's name in the composer and the agent's line.
    public var title: String
    /// An SVG or PNG in the package, drawn in the text colour.
    public var icon: String?
    /// What a key looks like, for the search field: "ENG-123".
    public var keyExample: String
    /// A key, whole: `[A-Z][A-Z0-9]*-[0-9]+`. A query that is one, or a
    /// link, is asked for as one issue instead of searched for.
    public var keyPattern: String?

    public init(title: String, icon: String? = nil, keyExample: String, keyPattern: String? = nil) {
        self.title = title; self.icon = icon; self.keyExample = keyExample; self.keyPattern = keyPattern
    }

    public static let titleLimit = 30
    public static let keyPatternLimit = 100

    func validate() throws {
        let title = title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, title.count <= Self.titleLimit, !title.contains(where: \.isNewline) else {
            throw PluginValidationError.invalidManifest("issueTracker needs a title of at most \(Self.titleLimit) characters")
        }
        guard !keyExample.isEmpty, keyExample.count <= 20 else {
            throw PluginValidationError.invalidManifest("issueTracker needs a short keyExample like ABC-123")
        }
        if let icon {
            let ext = (icon as NSString).pathExtension.lowercased()
            guard ["svg", "png"].contains(ext), PluginPackage.isContained(relativePath: icon) else {
                throw PluginValidationError.invalidManifest("issueTracker's icon is an .svg or .png inside the package")
            }
        }
        if let keyPattern {
            guard keyPattern.count <= Self.keyPatternLimit, (try? Regex(keyPattern)) != nil else {
                throw PluginValidationError.invalidManifest("issueTracker's keyPattern must be a short regular expression")
            }
        }
    }

    /// Whether the query is one key, as the tracker writes them. Keys are
    /// short, so a long query is never matched against the plugin's pattern.
    public func isKey(_ query: String) -> Bool {
        guard query.count <= TrackerIssue.keyLimit, !query.contains(where: \.isWhitespace),
              let keyPattern, let regex = try? Regex(keyPattern).ignoresCase() else { return false }
        return query.wholeMatch(of: regex) != nil
    }
}

/// One issue a tracker found.
public struct TrackerIssue: Sendable, Hashable, Identifiable {
    /// "ENG-123".
    public var key: String
    public var title: String
    /// The state's name: "In Progress".
    public var state: String?
    public var assignee: String?
    public var url: String
    /// The start of its description.
    public var excerpt: String?

    public var id: String { key }

    public init(key: String, title: String, state: String? = nil, assignee: String? = nil, url: String, excerpt: String? = nil) {
        self.key = key; self.title = title; self.state = state; self.assignee = assignee
        self.url = url; self.excerpt = excerpt
    }

    public static let keyLimit = 40
    public static let titleLimit = 500
    public static let shortLimit = 80

    /// From a plugin's answer. Nil unless it has a short key, a title and
    /// a secure link.
    public init?(_ value: JSONValue?) {
        func text(_ key: String, limit: Int) -> String? {
            guard let raw = value?[key]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
            return String(raw.prefix(limit))
        }
        guard let key = text("key", limit: Self.keyLimit), !key.contains(where: \.isWhitespace),
              let title = text("title", limit: Self.titleLimit),
              let url = value?["url"]?.string, url.count <= 2_000,
              let parsed = URL(string: url), parsed.scheme?.lowercased() == "https", parsed.host != nil else { return nil }
        self.init(key: key, title: title.replacingOccurrences(of: "\n", with: " "),
                  state: text("state", limit: Self.shortLimit), assignee: text("assignee", limit: Self.shortLimit),
                  url: url, excerpt: value?["excerpt"]?.string.map { String($0.prefix(PromptAttachment.maxBody)) })
    }

    public func jsonValue() -> JSONValue {
        var object: [String: JSONValue] = ["key": .string(key), "title": .string(title), "url": .string(url)]
        if let state { object["state"] = .string(state) }
        if let assignee { object["assignee"] = .string(assignee) }
        if let excerpt { object["excerpt"] = .string(excerpt) }
        return .object(object)
    }

    /// What goes with the message: the line the agent reads is Abstract's.
    public func attachment(trackerId: String, trackerName: String) -> PromptAttachment {
        PromptAttachment(kind: .trackerIssue, title: title, reference: key, url: url, body: excerpt,
                         details: state.map { ["State: \($0)"] } ?? [], tracker: trackerId, trackerName: trackerName)
    }
}

/// A team or project issues belong to, for scoping searches (ABS-143).
public struct TrackerProject: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable, Codable { case team, project }

    public var id: String
    public var name: String
    public var kind: Kind
    /// A team's key: "ENG".
    public var key: String?

    public init(id: String, name: String, kind: Kind, key: String? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.key = key
    }

    public init?(_ value: JSONValue?) {
        guard let id = value?["id"]?.string, !id.isEmpty, id.count <= 200,
              let name = value?["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
              let kind = value?["kind"]?.string.flatMap(Kind.init(rawValue:)) else { return nil }
        self.init(id: id, name: String(name.prefix(200)), kind: kind,
                  key: value?["key"]?.string.map { String($0.prefix(TrackerIssue.keyLimit)) })
    }

    public func jsonValue() -> JSONValue {
        var object: [String: JSONValue] = ["id": .string(id), "name": .string(name), "kind": .string(kind.rawValue)]
        if let key { object["key"] = .string(key) }
        return .object(object)
    }
}

/// Whether a tracker can be asked: signed in, or why not, in a sentence
/// the composer shows.
public struct TrackerAccess: Sendable, Hashable {
    public var ready: Bool
    /// Whose sign-in it uses: "Ada Lovelace".
    public var account: String?
    /// What to do: "Enter your Linear API key in Linear's settings."
    public var problem: String?

    public init(ready: Bool, account: String? = nil, problem: String? = nil) {
        self.ready = ready; self.account = account; self.problem = problem
    }

    public init?(_ value: JSONValue?) {
        guard let ready = value?["ready"]?.bool else { return nil }
        self.init(ready: ready, account: value?["account"]?.string.map { String($0.prefix(TrackerIssue.shortLimit)) },
                  problem: value?["problem"]?.string.map { String($0.prefix(300)) })
    }
}

/// The four questions core asks a tracker.
public enum TrackerRequest: Sendable, Hashable {
    case access
    case searchIssues(query: String, project: String?)
    /// A key or a link.
    case issue(String)
    case listProjects

    public var operation: String {
        switch self {
        case .access: "access"
        case .searchIssues: "searchIssues"
        case .issue: "issue"
        case .listProjects: "listProjects"
        }
    }

    public var input: JSONValue {
        switch self {
        case .access, .listProjects: .object([:])
        case .searchIssues(let query, let project):
            .object(["query": .string(query)].merging(project.map { ["project": .string($0)] } ?? [:]) { a, _ in a })
        case .issue(let reference): .object(["reference": .string(reference)])
        }
    }
}

/// A tracker's answer, checked against what was asked.
public enum TrackerAnswer: Sendable, Hashable {
    case access(TrackerAccess)
    case issues([TrackerIssue])
    case issue(TrackerIssue?)
    case projects([TrackerProject])
    case failed(String)

    public static let issueLimit = 50
    public static let projectLimit = 500

    /// What a `tracker.result` payload says, for this request. An answer
    /// of the wrong shape fails rather than showing half of it.
    public static func parse(_ request: TrackerRequest, _ payload: JSONValue?) -> TrackerAnswer {
        if let error = payload?["error"], error != .null {
            return .failed(String((error.string ?? error.compact()).prefix(300)))
        }
        let result = payload?["result"]
        switch request {
        case .access:
            return TrackerAccess(result).map(TrackerAnswer.access) ?? .failed("The tracker's answer couldn't be read.")
        case .searchIssues:
            guard let list = result?["issues"]?.array else { return .failed("The tracker's answer couldn't be read.") }
            return .issues(Array(list.compactMap(TrackerIssue.init).prefix(issueLimit)))
        case .issue:
            guard let found = result?["issue"], found != .null else { return .issue(nil) }
            return .issue(TrackerIssue(found))
        case .listProjects:
            guard let list = result?["projects"]?.array else { return .failed("The tracker's answer couldn't be read.") }
            return .projects(Array(list.compactMap(TrackerProject.init).prefix(projectLimit)))
        }
    }

    public var issues: [TrackerIssue] {
        switch self {
        case .issues(let issues): issues
        case .issue(let issue): issue.map { [$0] } ?? []
        default: []
        }
    }
}

/// One usable plugin's tracker, as the composer lists it.
public struct ResolvedIssueTracker: Sendable, Hashable, Identifiable {
    public var pluginId: String
    public var declaration: PluginIssueTrackerDeclaration
    public var id: String { pluginId }
    public var title: String { declaration.title }

    public init(pluginId: String, declaration: PluginIssueTrackerDeclaration) {
        self.pluginId = pluginId; self.declaration = declaration
    }
}

public enum PluginIssueTrackers {
    /// How long a tracker may take to answer.
    public static let timeout: TimeInterval = 20

    /// The trackers of plugins that can run now, in name order.
    public static func resolve(_ plugins: [InstalledPlugin]) -> [ResolvedIssueTracker] {
        plugins.filter { $0.isUsable && $0.record.grantedBackground }
            .compactMap { plugin in
                plugin.manifest?.contributes.issueTracker.map { ResolvedIssueTracker(pluginId: plugin.id, declaration: $0) }
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// What to ask a tracker for what was typed: a key or a link is one
    /// issue, anything else a search.
    public static func request(for query: String, tracker: PluginIssueTrackerDeclaration, project: String? = nil) -> TrackerRequest {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if tracker.isKey(q) || (q.hasPrefix("https://") && !q.contains(where: \.isWhitespace)) { return .issue(q) }
        return .searchIssues(query: q, project: project)
    }

    /// Every tracker's results for one query, grouped by tracker in the
    /// trackers' order. A tracker that can't be reached says why instead.
    public struct Group: Sendable, Hashable, Identifiable {
        public var tracker: ResolvedIssueTracker
        public var issues: [TrackerIssue]
        public var problem: String?
        public var id: String { tracker.id }
    }

    public static func search(_ query: String, trackers: [ResolvedIssueTracker],
                              ask: @Sendable @escaping (ResolvedIssueTracker, TrackerRequest) async -> TrackerAnswer) async -> [Group] {
        await withTaskGroup(of: (Int, Group).self) { group in
            for (index, tracker) in trackers.enumerated() {
                group.addTask {
                    if case .access(let access) = await ask(tracker, .access), !access.ready {
                        return (index, Group(tracker: tracker, issues: [], problem: access.problem
                                             ?? "\(tracker.title) isn't connected yet."))
                    }
                    let answer = await ask(tracker, request(for: query, tracker: tracker.declaration))
                    if case .failed(let why) = answer { return (index, Group(tracker: tracker, issues: [], problem: why)) }
                    return (index, Group(tracker: tracker, issues: answer.issues))
                }
            }
            var out: [(Int, Group)] = []
            for await result in group { out.append(result) }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }
}

/// The calls a background script hasn't answered yet, each with its time
/// limit. Its `tracker.result`, the limit, or the script stopping ends one.
public actor PluginTrackerCalls {
    private var waiting: [String: (TrackerRequest, CheckedContinuation<TrackerAnswer, Never>)] = [:]
    private let timeout: TimeInterval
    private let pluginName: String

    public init(pluginName: String, timeout: TimeInterval = PluginIssueTrackers.timeout) {
        self.pluginName = pluginName; self.timeout = timeout
    }

    /// Sends a request through `send` (given its id) and waits for its end.
    /// `send` returns false when the script can't take it.
    public func call(_ request: TrackerRequest, _ send: @Sendable @escaping (String) async -> Bool) async -> TrackerAnswer {
        let id = UUID().uuidString
        let limit = timeout
        let name = pluginName
        return await withCheckedContinuation { continuation in
            waiting[id] = (request, continuation)
            Task {
                guard await send(id) else { self.end(id, .failed("\(name) isn't running.")); return }
                try? await Task.sleep(for: .seconds(limit))
                self.end(id, .failed("\(name) didn't answer within \(Int(limit)) seconds."))
            }
        }
    }

    /// The script's answer, read for the request it answers.
    public func finish(_ id: String, payload: JSONValue?) {
        guard let request = waiting[id]?.0 else { return }
        end(id, TrackerAnswer.parse(request, payload))
    }

    private func end(_ id: String, _ answer: TrackerAnswer) {
        waiting.removeValue(forKey: id)?.1.resume(returning: answer)
    }

    public func failAll() {
        let all = waiting
        waiting = [:]
        for (_, continuation) in all.values { continuation.resume(returning: .failed("\(pluginName) stopped before it answered.")) }
    }

    public var pending: Int { waiting.count }
}
