import Foundation

// Link decorators (ABS-126): a plugin names the links it knows, like
// GitHub pull requests, and Abstract puts the status its background
// script reports after each one in a chat. The plugin is handed the link
// alone, cut to what its pattern names: never the chat, the message, or
// a query or fragment, which can carry tokens.

/// What a plugin's script says about one link: a short label and how it
/// stands. The host draws it; the plugin never draws in the transcript.
public struct PluginLinkStatus: Sendable, Hashable, Codable {
    /// How the status is coloured, from a closed list so every plugin's
    /// pills read the same in every theme.
    public enum Tone: String, Sendable, Hashable, Codable, CaseIterable {
        case open, draft, merged, closed, failing, neutral
    }

    public static let labelLimit = 40

    public var label: String
    public var tone: Tone

    public init(label: String, tone: Tone) {
        self.label = label; self.tone = tone
    }

    /// From a `links.result` payload. Nil unless the label is one short
    /// line and the tone is known.
    public init?(_ value: JSONValue?) {
        guard let label = value?["label"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !label.isEmpty, label.count <= Self.labelLimit, !label.contains(where: \.isNewline),
              let tone = value?["tone"]?.string.flatMap(Tone.init(rawValue:)) else { return nil }
        self.init(label: label, tone: tone)
    }
}

/// How one lookup ended: a status, nothing to show, or no answer.
public enum PluginLinkLookup: Sendable, Equatable {
    case status(PluginLinkStatus?)
    case failed
}

public enum PluginLinks {
    /// Patterns one decorator may list.
    public static let patternLimit = 8
    /// A status older than this is asked for again while its link shows.
    /// The view checks every `checkInterval`, so a change shows within
    /// five minutes of happening.
    public static let refreshAfter: TimeInterval = 270
    public static let checkInterval: TimeInterval = 30
    /// How long a script may take to answer one lookup.
    public static let timeout: TimeInterval = 20
    /// Links one message is looked up for, so a pasted list can't flood.
    public static let perTextLimit = 24

    /// One pattern: `https://` and an exact host, then path segments,
    /// where `*` is any one segment. A link matches when its path starts
    /// with those segments; whatever follows is dropped.
    public struct Pattern: Sendable, Hashable {
        public var host: String
        public var segments: [String]

        public init?(_ text: String) {
            guard text.count <= 200, text.hasPrefix("https://") else { return nil }
            let rest = text.dropFirst("https://".count)
            let parts = rest.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard let host = parts.first?.lowercased(), PluginManifest.isExactHost(host) else { return nil }
            let segments = Array(parts.dropFirst())
            guard !segments.isEmpty, segments.count <= 12,
                  segments.allSatisfy({ segment in
                      segment == "*" || (!segment.isEmpty && !segment.contains("*") && !segment.contains("?")
                                         && !segment.contains("#") && segment.count <= 60)
                  }) else { return nil }
            self.host = host
            self.segments = segments
        }

        /// The link as the plugin is handed it, or nil when it doesn't match.
        public func canonical(_ url: URL) -> String? {
            guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
                  url.port == nil || url.port == 443,
                  url.host?.lowercased() == host else { return nil }
            let path = url.path.split(separator: "/").map(String.init)
            guard path.count >= segments.count else { return nil }
            for (want, have) in zip(segments, path) where want != "*" && want != have { return nil }
            let kept = path.prefix(segments.count).map {
                $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? $0
            }
            return "https://\(host)/" + kept.joined(separator: "/")
        }
    }

    /// The sites a decorator's patterns cover, for the review screen.
    public static func sites(_ patterns: [String]) -> [String] {
        var seen: [String] = []
        for host in patterns.compactMap({ Pattern($0)?.host }) where !seen.contains(host) { seen.append(host) }
        return seen
    }

    /// One decorated link: which plugin's decorator, and the link as handed to it.
    public struct Match: Sendable, Hashable {
        public var pluginId: String
        public var contributionId: String
        public var url: String
        public init(pluginId: String, contributionId: String, url: String) {
            self.pluginId = pluginId; self.contributionId = contributionId; self.url = url
        }
    }

    /// The first decorator whose patterns take this link.
    public static func match(_ url: URL, decorators: [ResolvedPluginContribution]) -> Match? {
        for decorator in decorators where decorator.place == .link {
            for pattern in (decorator.contribution.patterns ?? []).compactMap(Pattern.init) {
                if let canonical = pattern.canonical(url) {
                    return Match(pluginId: decorator.pluginId, contributionId: decorator.contribution.id, url: canonical)
                }
            }
        }
        return nil
    }

    /// The decorated links in a message's text, in order and without
    /// repeats: bare links and Markdown links alike.
    public static func matches(in text: String, decorators: [ResolvedPluginContribution]) -> [Match] {
        guard !decorators.isEmpty, text.contains("https://") else { return [] }
        var out: [Match] = []
        for found in text.matches(of: #/https://[^\s<>()\[\]"'`]+/#) {
            var candidate = String(found.output)
            while let last = candidate.last, ".,;:!?*_~".contains(last) { candidate.removeLast() }
            guard let url = URL(string: candidate), let match = match(url, decorators: decorators),
                  !out.contains(match) else { continue }
            out.append(match)
            if out.count == perTextLimit { break }
        }
        return out
    }

    /// The text with `pill(url)` put after each link it has one for. A
    /// link split over several runs (part of it bold, say) gets one, after
    /// its end. What's put in takes the link's block, so it stays in its
    /// paragraph, list item or table cell.
    public static func decorate(_ text: AttributedString, pill: (URL) -> AttributedString?) -> AttributedString {
        var ends: [(AttributedString.Index, URL, PresentationIntent?)] = []
        var previous: URL?
        var lastEnd: AttributedString.Index?
        var lastIntent: PresentationIntent?
        for run in text.runs {
            if run.link != previous, let previous, let lastEnd { ends.append((lastEnd, previous, lastIntent)) }
            previous = run.link
            lastEnd = run.range.upperBound
            lastIntent = run.presentationIntent
        }
        if let previous, let lastEnd { ends.append((lastEnd, previous, lastIntent)) }
        var out = text
        for (end, url, intent) in ends.reversed() {
            guard var inserted = pill(url) else { continue }
            inserted.presentationIntent = intent
            out.insert(inserted, at: end)
        }
        return out
    }
}

/// The statuses links have shown, and when each was asked for. A status
/// stays until a newer answer replaces it, so a failed lookup or a
/// script turned off for a moment doesn't blank a pill.
public struct PluginLinkCache: Sendable {
    public struct Entry: Sendable, Equatable {
        public var status: PluginLinkStatus?
        public var askedAt: Date
        public var inFlight: Bool
    }

    public private(set) var entries: [PluginLinks.Match: Entry] = [:]

    public init() {}

    public func status(_ match: PluginLinks.Match) -> PluginLinkStatus? {
        entries[match]?.status
    }

    /// Whether to ask now: never asked, or asked long enough ago, and no
    /// answer still on its way.
    public func isDue(_ match: PluginLinks.Match, now: Date = Date()) -> Bool {
        guard let entry = entries[match] else { return true }
        return !entry.inFlight && now.timeIntervalSince(entry.askedAt) >= PluginLinks.refreshAfter
    }

    public mutating func asking(_ match: PluginLinks.Match, now: Date = Date()) {
        entries[match] = Entry(status: entries[match]?.status, askedAt: now, inFlight: true)
    }

    /// The answer. A failure keeps the status it had.
    public mutating func answered(_ match: PluginLinks.Match, _ lookup: PluginLinkLookup) {
        guard var entry = entries[match] else { return }
        entry.inFlight = false
        if case .status(let status) = lookup { entry.status = status }
        entries[match] = entry
    }

    /// Forgets a plugin's statuses: it was turned off or removed.
    public mutating func forget(pluginIds keep: Set<String>) {
        entries = entries.filter { keep.contains($0.key.pluginId) }
    }
}

/// The lookups a background script hasn't answered yet, each with its
/// time limit. Its `links.result`, the limit, or the script stopping ends one.
public actor PluginLinkLookups {
    private var waiting: [String: CheckedContinuation<PluginLinkLookup, Never>] = [:]
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = PluginLinks.timeout) {
        self.timeout = timeout
    }

    /// Sends a lookup through `send` (given its id) and waits for its end.
    /// `send` returns false when the script can't take it.
    public func lookUp(_ send: @Sendable @escaping (String) async -> Bool) async -> PluginLinkLookup {
        let id = UUID().uuidString
        let limit = timeout
        return await withCheckedContinuation { continuation in
            waiting[id] = continuation
            Task {
                guard await send(id) else { self.finish(id, .failed); return }
                try? await Task.sleep(for: .seconds(limit))
                self.finish(id, .failed)
            }
        }
    }

    public func finish(_ id: String, _ lookup: PluginLinkLookup) {
        waiting.removeValue(forKey: id)?.resume(returning: lookup)
    }

    public func failAll() {
        let all = waiting
        waiting = [:]
        for continuation in all.values { continuation.resume(returning: .failed) }
    }

    public var pending: Int { waiting.count }
}
