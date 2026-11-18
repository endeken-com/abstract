import Foundation

// Linking issues from a paired phone (ABS-211). Tracker plugins never run on
// the phone (ABS-84 §6), so it asks the Mac: which trackers and code host a
// project offers, a search, and the picked issue whole. The Mac answers with
// the same searches its own composer runs.

/// One tracker a paired device's composer offers for a project.
public struct RemoteIssueTracker: Codable, Sendable, Hashable {
    /// The tracker's plugin id: what a `trackerIssue` attachment names.
    public var id: String
    /// "Jira".
    public var title: String
    /// "DGDEV-1381": what a key looks like, for the search field.
    public var keyExample: String
    /// The plugin's version, which its icon is kept by.
    public var version: String
    /// What the project links it to ("DGDEV", "ENG · Core"); nil when it
    /// links none and every tracker is offered.
    public var link: String?
    /// The linked team's or project's key, for the chat's header ("DGDEV").
    public var linkKey: String?
    /// The icon's SVG text or PNG bytes; nil when the asking device already
    /// has this version's, or the plugin has none a phone may draw.
    public var icon: Data?
    /// "svg" or "png".
    public var iconFormat: String?
    /// Drawn in the text colour (no colours of its own), as on the Mac.
    public var iconIsTemplate: Bool?

    public init(id: String, title: String, keyExample: String, version: String, link: String? = nil, linkKey: String? = nil,
                icon: Data? = nil, iconFormat: String? = nil, iconIsTemplate: Bool? = nil) {
        self.id = id; self.title = title; self.keyExample = keyExample; self.version = version
        self.link = link; self.linkKey = linkKey
        self.icon = icon; self.iconFormat = iconFormat; self.iconIsTemplate = iconIsTemplate
    }

    /// The largest icon sent.
    public static let maxIconBytes = 32_768

    /// An icon a phone may draw: a small PNG, or an SVG that loads nothing
    /// from outside itself (gradients it defines are fine).
    public static func safeIcon(_ data: Data, path: String) -> (data: Data, format: String)? {
        guard data.count <= maxIconBytes else { return nil }
        switch (path as NSString).pathExtension.lowercased() {
        case "png":
            return data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? (data, "png") : nil
        case "svg":
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            let lower = text.lowercased()
            guard lower.contains("<svg"), !["<script", "<foreignobject", "<image", "<!", "javascript:"].contains(where: lower.contains) else { return nil }
            // Only references to its own definitions: url(#id), href="#id".
            let outside = #/url\(\s*['"]?\s*[^#'"\s]|href\s*=\s*["']\s*[^#"']/#
            guard lower.firstMatch(of: outside) == nil else { return nil }
            return (data, "svg")
        default:
            return nil
        }
    }
}

/// What a paired device's composer offers to link for a project or chat.
public struct RemoteIssueSources: Codable, Sendable, Hashable {
    /// The trackers it searches: the project's linked ones, else every
    /// tracker that's on, in name order.
    public var trackers: [RemoteIssueTracker]
    /// Whether `trackers` are the project's own links.
    public var linked: Bool
    /// The project's code host ("GitHub", "Bitbucket"), when it has a
    /// repository; nil for a chat outside any project.
    public var codeHost: String?
    /// Whether "Link a GitHub issue" is offered: only for GitHub projects.
    public var githubIssues: Bool
    /// Whether "Link a pull request" is offered: any project with a repository.
    public var pullRequests: Bool

    public init(trackers: [RemoteIssueTracker], linked: Bool, codeHost: String? = nil,
                githubIssues: Bool = false, pullRequests: Bool = false) {
        self.trackers = trackers; self.linked = linked; self.codeHost = codeHost
        self.githubIssues = githubIssues; self.pullRequests = pullRequests
    }

    /// A project's trackers as its Mac's composer shows them. `known` holds
    /// the icon versions the asking device already has, by plugin id; those
    /// icons aren't sent again.
    public init(_ project: ProjectIssueTrackers, installed: [InstalledPlugin], known: [String: String] = [:],
                codeHost: String? = nil, githubIssues: Bool = false, pullRequests: Bool = false) {
        let links = Dictionary(project.linked.map { ($0.tracker.pluginId, $0.link) }) { a, _ in a }
        let plugins = Dictionary(installed.map { ($0.id, $0) }) { a, _ in a }
        let trackers = project.shown().map { tracker -> RemoteIssueTracker in
            let plugin = plugins[tracker.pluginId]
            let version = plugin?.record.version ?? ""
            var out = RemoteIssueTracker(id: tracker.pluginId, title: tracker.title,
                                         keyExample: tracker.declaration.keyExample, version: version,
                                         link: links[tracker.pluginId].map(\.title),
                                         linkKey: links[tracker.pluginId].flatMap { ($0.project ?? $0.team)?.key })
            if known[tracker.pluginId] != version, let plugin, let path = tracker.declaration.icon,
               let data = PluginPackage.fileData(in: plugin.packageURL, relativePath: path),
               let icon = RemoteIssueTracker.safeIcon(data, path: path) {
                out.icon = icon.data
                out.iconFormat = icon.format
                out.iconIsTemplate = PluginIssueTrackerDeclaration.iconIsTemplate(data, path: path)
            }
            return out
        }
        self.init(trackers: trackers, linked: !project.linked.isEmpty, codeHost: codeHost,
                  githubIssues: githubIssues, pullRequests: pullRequests)
    }
}

/// One issue or pull request found, ready to attach as it is listed.
public struct RemoteIssueResult: Codable, Sendable, Hashable {
    /// "DGDEV-1381", "#12".
    public var reference: String
    public var title: String
    /// "In Progress", "Open", "Draft".
    public var state: String?
    public var attachment: PromptAttachment

    public init(reference: String, title: String, state: String?, attachment: PromptAttachment) {
        self.reference = reference; self.title = title; self.state = state; self.attachment = attachment
    }
}

/// One tracker's (or the code host's) results, or why it has none.
public struct RemoteIssueGroup: Codable, Sendable, Hashable {
    /// The tracker's or code host's plugin id.
    public var sourceId: String
    public var title: String
    public var results: [RemoteIssueResult]
    /// A sentence saying why there are no results: signed out, failed.
    public var problem: String?

    public init(sourceId: String, title: String, results: [RemoteIssueResult], problem: String? = nil) {
        self.sourceId = sourceId; self.title = title; self.results = results; self.problem = problem
    }

    /// A tracker's answer, as the Mac's composer would list it. A tracker
    /// that isn't signed in says so, naming the Mac it isn't signed in on.
    public init(_ group: PluginIssueTrackers.Group, macName: String) {
        let tracker = group.tracker
        var problem = group.problem
        if group.signedOut {
            problem = (["\(tracker.title) isn't signed in on \(macName)."] + [group.hint].compactMap { $0 }.filter { !$0.isEmpty })
                .joined(separator: " ")
        }
        self.init(sourceId: tracker.pluginId, title: tracker.title, results: group.issues.map { issue in
            RemoteIssueResult(reference: issue.key, title: issue.title, state: issue.state,
                              attachment: issue.attachment(trackerId: tracker.pluginId, trackerName: tracker.title))
        }, problem: problem)
    }

    /// A code host's issues or pull requests.
    public init(codeHost pluginId: String, title: String, items: [ForgeItem]) {
        self.init(sourceId: pluginId, title: title, results: items.map { item in
            var attachment = item.attachment
            if item.isPullRequest { attachment.trackerName = title }
            return RemoteIssueResult(reference: "#\(item.number)", title: item.title,
                                     state: item.isDraft ? "Draft" : item.state.capitalized, attachment: attachment)
        })
    }
}
