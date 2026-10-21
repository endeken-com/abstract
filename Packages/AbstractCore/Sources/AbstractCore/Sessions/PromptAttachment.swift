import Foundation

/// Something sent along with a message besides its text: a file or image
/// from this Mac, a GitHub issue or pull request, an issue from a tracker
/// plugin such as Linear (ABS-141). The agent
/// gets each one as text after the message, in Paseo's attachment formats
/// (Apache-2.0, Copyright (c) 2025-present Mohamed Boudra). Images also go
/// to the agent as images, where it can take them.
public struct PromptAttachment: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable {
        case file, image, githubIssue, pullRequest
        /// An issue an issue tracker plugin found; `tracker` says which.
        case trackerIssue
        /// Findings from a Revund review.
        case revundReview

        /// Linear issues attached before trackers were plugins (ABS-141).
        static let legacyLinear = "linearIssue"

        /// Reads the old Linear kind as a tracker issue.
        public init?(rawValue: String) {
            switch rawValue {
            case "file": self = .file
            case "image": self = .image
            case "githubIssue": self = .githubIssue
            case "pullRequest": self = .pullRequest
            case "trackerIssue", Self.legacyLinear: self = .trackerIssue
            case "revundReview": self = .revundReview
            default: return nil
            }
        }
    }

    /// The official Linear plugin, which old Linear attachments belong to.
    public static let linearTrackerId = "sh.abstract.linear"

    public var id: String
    public var kind: Kind
    /// A file's name; an issue's or pull request's title.
    public var title: String
    /// Files: where the file is on the Mac that runs the agent.
    public var path: String?
    /// Issues and pull requests: "#12", "ENG-123".
    public var reference: String?
    public var url: String?
    public var body: String?
    /// More lines worth giving the agent, e.g. "Base: main", "State: Todo".
    public var details: [String]
    /// Tracker issues: the plugin that found it, and the tracker's name.
    public var tracker: String?
    public var trackerName: String?

    public init(id: String = UUID().uuidString, kind: Kind, title: String, path: String? = nil, reference: String? = nil,
                url: String? = nil, body: String? = nil, details: [String] = [],
                tracker: String? = nil, trackerName: String? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.path = path; self.reference = reference
        self.url = url; self.body = body; self.details = details
        self.tracker = tracker; self.trackerName = trackerName
    }

    // Queued messages and remote sends saved before ABS-141 carry
    // `linearIssue` and no tracker: they're the Linear plugin's.
    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        let rawKind = try box.decode(String.self, forKey: .kind)
        guard let kind = Kind(rawValue: rawKind) else {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: box, debugDescription: "Unknown attachment kind \(rawKind)")
        }
        let legacy = rawKind == Kind.legacyLinear
        self.init(id: try box.decode(String.self, forKey: .id), kind: kind, title: try box.decode(String.self, forKey: .title),
                  path: try box.decodeIfPresent(String.self, forKey: .path),
                  reference: try box.decodeIfPresent(String.self, forKey: .reference),
                  url: try box.decodeIfPresent(String.self, forKey: .url), body: try box.decodeIfPresent(String.self, forKey: .body),
                  details: try box.decodeIfPresent([String].self, forKey: .details) ?? [],
                  tracker: legacy ? Self.linearTrackerId : try box.decodeIfPresent(String.self, forKey: .tracker),
                  trackerName: legacy ? "Linear" : try box.decodeIfPresent(String.self, forKey: .trackerName))
    }

    /// How it's named in the composer and the transcript.
    public var label: String {
        kind == .revundReview ? "Revund · \(title)" : reference.map { "\($0) \(title)" } ?? title
    }

    /// Longer descriptions are cut here; the link has the rest.
    static let maxBody = 12_000

    /// What the agent reads.
    public var promptText: String {
        var lines: [String]
        switch kind {
        case .file: lines = ["Attached file: \(title)"] + (path.map { ["Path: \($0)"] } ?? [])
        case .image: lines = ["Attached image: \(title)"] + (path.map { ["Path: \($0)"] } ?? [])
        case .githubIssue: lines = ["GitHub Issue \(reference ?? ""): \(title)"]
        case .pullRequest: lines = ["GitHub PR \(reference ?? ""): \(title)"]
        case .trackerIssue: lines = ["\(trackerName ?? "Tracker") Issue \(reference ?? ""): \(title)"]
        case .revundReview: lines = ["Revund review: \(title)"]
        }
        if let url { lines.append(url) }
        lines += details
        if let body = body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
            // An issue's description can be cut, its link has the rest; review findings can't.
            let cut = kind != .revundReview && body.count > Self.maxBody ? String(body.prefix(Self.maxBody)) + "\n…" : body
            lines += ["", cut]
        }
        return lines.joined(separator: "\n")
    }
}

/// A message with its attachments, as one text: the message, then each
/// attachment in a tag the transcript can find again to show it as a chip.
public enum PromptAttachments {
    public struct Chip: Sendable, Hashable {
        public var kind: PromptAttachment.Kind
        public var label: String
        /// A web link, or the file's path.
        public var target: String?
        /// Tracker issues: the plugin that found it.
        public var tracker: String?

        public init(kind: PromptAttachment.Kind, label: String, target: String? = nil, tracker: String? = nil) {
            self.kind = kind; self.label = label; self.target = target; self.tracker = tracker
        }
    }

    public static func message(_ text: String, _ attachments: [PromptAttachment]) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !attachments.isEmpty else { return text }
        let blocks = attachments.map { a in
            let target = a.url ?? a.path
            return "<attachment kind=\"\(a.kind.rawValue)\""
                + (a.tracker.map { " tracker=\"\(attribute($0))\"" } ?? "")
                + " label=\"\(attribute(a.label))\""
                + (target.map { " target=\"\(attribute($0))\"" } ?? "") + ">\n"
                // A description can't close the tag early.
                + a.promptText.replacingOccurrences(of: "</attachment>", with: "<\\/attachment>")
                + "\n</attachment>"
        }
        return ([text].filter { !$0.isEmpty } + blocks).joined(separator: "\n\n")
    }

    /// The message's own text and its attachments' chips.
    public static func split(_ message: String) -> (text: String, chips: [Chip]) {
        guard message.contains("<attachment kind=\"") else { return (message, []) }
        var chips: [Chip] = []
        var text = message
        for match in message.matches(of: block).reversed() {
            let rawKind = String(match.output.1)
            guard let kind = PromptAttachment.Kind(rawValue: rawKind) else { continue }
            // Messages sent before ABS-141 name Linear by their kind alone.
            let tracker = rawKind == PromptAttachment.Kind.legacyLinear
                ? PromptAttachment.linearTrackerId : match.output.2.map { unattribute(String($0)) }
            chips.insert(Chip(kind: kind, label: unattribute(String(match.output.3)),
                              target: match.output.4.map { unattribute(String($0)) }, tracker: tracker), at: 0)
            text.removeSubrange(match.range)
        }
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), chips)
    }

    /// Paths of the attached images, for agents that take images.
    public static func images(_ attachments: [PromptAttachment]) -> [String] {
        attachments.filter { $0.kind == .image }.compactMap(\.path)
    }

    nonisolated(unsafe) private static let block = #/<attachment kind="([A-Za-z]+)"(?: tracker="([^"]*)")? label="([^"]*)"(?: target="([^"]*)")?>\n[\s\S]*?\n</attachment>/#

    private static func attribute(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func unattribute(_ value: String) -> String {
        value.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&amp;", with: "&")
    }
}

/// Image types agents take as they are.
public enum ImageMedia {
    public static func type(ofPath path: String) -> String? {
        switch (path as NSString).pathExtension.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        default: nil
        }
    }
}
