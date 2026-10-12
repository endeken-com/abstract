import Foundation

/// One place the words you're finding appear in a review's diff.
public struct DiffMatch: Hashable, Sendable {
    /// The file it's in (its new path when it was renamed).
    public let path: String
    /// Its hunk, by position in the file's hunks, and its line in that hunk.
    public let hunk: Int
    public let line: Int
    public let origin: DiffLine.Origin
    /// The line's number in the old file (removed and unchanged lines) and
    /// in the new one (added and unchanged lines).
    public let oldLine: Int?
    public let newLine: Int?
    /// Which appearance of the words on that line, from 0.
    public let occurrence: Int

    public init(path: String, hunk: Int, line: Int, origin: DiffLine.Origin, oldLine: Int?, newLine: Int?, occurrence: Int) {
        self.path = path; self.hunk = hunk; self.line = line; self.origin = origin
        self.oldLine = oldLine; self.newLine = newLine; self.occurrence = occurrence
    }

    /// The same match after the diff is read again, wherever its hunk moves.
    var key: Key { Key(path: path, origin: origin, oldLine: oldLine, newLine: newLine, occurrence: occurrence) }
    struct Key: Hashable { let path: String; let origin: DiffLine.Origin; let oldLine: Int?; let newLine: Int?; let occurrence: Int }
}

/// What finding in a review looks through: every line of every file's
/// hunks, as the review shows them, whether the file is open or not.
public struct DiffSearch: Sendable, Hashable {
    /// Which lines count.
    public enum Lines: String, Sendable, Hashable, CaseIterable {
        case all, added, removed
    }

    public var caseSensitive: Bool
    public var lines: Lines

    public init(caseSensitive: Bool = false, lines: Lines = .all) {
        self.caseSensitive = caseSensitive
        self.lines = lines
    }

    /// Whether a line of this kind is searched.
    public func includes(_ origin: DiffLine.Origin) -> Bool {
        switch (origin, lines) {
        case (.noNewline, _): false
        case (_, .all): true
        case (.added, .added), (.removed, .removed): true
        default: false
        }
    }

    /// Every match, file by file in the order given, then line by line.
    public func matches(of query: String, in files: [FileDiff]) -> [DiffMatch] {
        guard !query.isEmpty else { return [] }
        var out: [DiffMatch] = []
        for file in files where !file.isBinary {
            for (h, hunk) in file.hunks.enumerated() {
                var old = hunk.oldStart, new = hunk.newStart
                for (l, line) in hunk.lines.enumerated() {
                    let numbers: (Int?, Int?) = switch line.origin {
                    case .context: (old, new)
                    case .removed: (old, nil)
                    case .added: (nil, new)
                    case .noNewline: (nil, nil)
                    }
                    if line.origin == .context || line.origin == .removed { old += 1 }
                    if line.origin == .context || line.origin == .added { new += 1 }
                    guard includes(line.origin) else { continue }
                    for i in ranges(of: query, in: Diff.display(line.content)).indices {
                        out.append(DiffMatch(path: file.path, hunk: h, line: l, origin: line.origin,
                                             oldLine: numbers.0, newLine: numbers.1, occurrence: i))
                    }
                }
            }
        }
        return out
    }

    /// Where `query` appears in `text`, without overlaps. Ignoring case also
    /// ignores accents; matching case matches exactly.
    public func ranges(of query: String, in text: String) -> [Range<String.Index>] {
        guard !query.isEmpty else { return [] }
        let options: String.CompareOptions = caseSensitive ? [.literal] : [.caseInsensitive, .diacriticInsensitive]
        var out: [Range<String.Index>] = []
        var start = text.startIndex
        while start < text.endIndex, let range = text.range(of: query, options: options, range: start..<text.endIndex) {
            out.append(range)
            start = range.upperBound
        }
        return out
    }
}

/// Finding in a review: the matches, which one you're on, and whether the
/// diff has been taken to it yet.
public struct DiffFind: Sendable, Equatable {
    public private(set) var query = ""
    public private(set) var matches: [DiffMatch] = []
    public private(set) var current: Int?
    /// Whether the diff has been taken to the current match. Until it has,
    /// the next match is that one.
    public private(set) var shown = false

    public init() {}

    public var currentMatch: DiffMatch? { current.map { matches[$0] } }

    /// "3 of 41", "No results", or nothing before you type.
    public var label: String {
        guard !query.isEmpty else { return "" }
        guard let current else { return "No results" }
        return "\(current + 1) of \(matches.count)"
    }

    /// Finds `query` afresh, starting at the first match.
    public mutating func search(_ query: String, in files: [FileDiff], using search: DiffSearch) {
        self.query = query
        matches = search.matches(of: query, in: files)
        shown = false
        current = matches.isEmpty ? nil : 0
    }

    /// The diff was read again: you stay on the match you were on, if it's still there.
    public mutating func refresh(_ files: [FileDiff], using search: DiffSearch) {
        guard !query.isEmpty else { return }
        let was = currentMatch
        let old = current
        matches = search.matches(of: query, in: files)
        guard !matches.isEmpty else { current = nil; shown = false; return }
        if let was, let same = matches.firstIndex(where: { $0.key == was.key }) {
            current = same
        } else {
            current = min(old ?? 0, matches.count - 1)
            shown = false
        }
    }

    /// The match to show next: the current one if it hasn't been shown yet,
    /// otherwise the one after it, round to the first.
    @discardableResult
    public mutating func next() -> DiffMatch? {
        guard let current else { return nil }
        if shown { self.current = (current + 1) % matches.count }
        shown = true
        return currentMatch
    }

    /// The match before the current one, round to the last.
    @discardableResult
    public mutating func previous() -> DiffMatch? {
        guard let current else { return nil }
        self.current = (current - 1 + matches.count) % matches.count
        shown = true
        return currentMatch
    }
}

extension Diff {
    /// A line as the review shows it: tabs as four spaces, no stray CR.
    public static func display(_ content: String) -> String {
        var text = content
        if text.hasSuffix("\r") { text.removeLast() }
        return text.contains("\t") ? text.replacingOccurrences(of: "\t", with: "    ") : text
    }
}
