import Foundation

/// What ABEL reads aloud from an agent's reply (ABS-202 §3): one paragraph
/// at a time, as sentences. Code blocks, diffs and tables become one
/// sentence ("…and 40 lines of code"), long paths their file name, links
/// their text, and Markdown marks go.
public struct SpeakableText: Sendable, Equatable {
    /// The reply's paragraphs, each ready to speak; code and tables are
    /// folded into the paragraph before them.
    public let paragraphs: [String]

    public init(markdown: String) {
        var spoken: [String] = []
        for block in MarkdownBlocks.split(markdown) {
            if let summary = Self.summary(ofNonProse: block) {
                // "…and 40 lines of code" belongs to what came before it.
                if let last = spoken.popLast() {
                    spoken.append(Self.joined(last, summary))
                } else {
                    spoken.append(Self.capitalized(summary))
                }
                continue
            }
            let line = Self.prose(block)
            if !line.isEmpty { spoken.append(line) }
        }
        paragraphs = spoken
    }

    /// The first paragraph: what's read when a reply finishes.
    public var first: String? { paragraphs.first }

    /// The paragraph after `index`, for "continue"; nil at the end.
    public func paragraph(after index: Int) -> String? {
        paragraphs.indices.contains(index + 1) ? paragraphs[index + 1] : nil
    }

    // MARK: Blocks that aren't prose

    /// One sentence for a code block, diff or table; nil for prose.
    static func summary(ofNonProse block: String) -> String? {
        let lines = block.split(separator: "\n", omittingEmptySubsequences: false)
        guard let firstLine = lines.first else { return nil }
        let head = firstLine.drop { $0 == " " }
        if head.hasPrefix("```") || head.hasPrefix("~~~") {
            let language = head.drop { $0 == "`" || $0 == "~" }.trimmingCharacters(in: .whitespaces).lowercased()
            let body = lines.dropFirst().filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !(trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~"))
            }
            let count = body.count
            let isDiff = language == "diff" || language == "patch"
                || (count > 0 && body.allSatisfy { $0.hasPrefix("+") || $0.hasPrefix("-") || $0.hasPrefix(" ") || $0.hasPrefix("@@") || $0.isEmpty })
                    && body.contains { $0.hasPrefix("+") || $0.hasPrefix("-") }
            if isDiff { return "and a \(count)-line diff" }
            return count == 1 ? "and a line of code" : "and \(count) lines of code"
        }
        let trimmed = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if trimmed.count >= 2, trimmed.allSatisfy({ $0.hasPrefix("|") }) {
            let rows = trimmed.filter { !$0.allSatisfy { "|-: ".contains($0) } }.count - 1
            return rows == 1 ? "and a table with one row" : "and a table with \(max(rows, 0)) rows"
        }
        // Indented code: every line four spaces or a tab in.
        if lines.allSatisfy({ $0.hasPrefix("    ") || $0.hasPrefix("\t") || $0.allSatisfy(\.isWhitespace) }),
           lines.contains(where: { !$0.allSatisfy(\.isWhitespace) }) {
            let count = lines.filter { !$0.allSatisfy(\.isWhitespace) }.count
            return count == 1 ? "and a line of code" : "and \(count) lines of code"
        }
        return nil
    }

    // MARK: Prose

    /// A prose block as one line of speech.
    static func prose(_ block: String) -> String {
        let lines = block.split(separator: "\n").map { line -> String in
            var text = line.trimmingCharacters(in: .whitespaces)
            // Headings, quotes and list marks.
            while text.hasPrefix("#") { text.removeFirst() }
            if text.hasPrefix(">") { text.removeFirst() }
            if let range = text.range(of: #"^([-*+]|\d+[.)])\s+"#, options: .regularExpression) {
                text.removeSubrange(range)
            }
            if text.hasPrefix("[ ] ") || text.hasPrefix("[x] ") { text.removeFirst(4) }
            return sentence(text.trimmingCharacters(in: .whitespaces))
        }.filter { !$0.isEmpty }
        return lines.joined(separator: " ")
    }

    /// Inline Markdown read as words: links as their text, code as its
    /// words, long paths as their file name, emphasis marks dropped.
    static func inline(_ text: String) -> String {
        var s = text
        // Images go; links read as their text.
        s = s.replacingOccurrences(of: #"!\[[^\]]*\]\([^)]*\)"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<(https?://[^>]+)>"#, with: "$1", options: .regularExpression)
        // Bare URLs: their host.
        s = replacing(#"https?://([^/\s)]+)[^\s)]*"#, in: s) { groups in
            "a link to \(groups[1].replacingOccurrences(of: "www.", with: ""))"
        }
        // Inline code keeps its words; a path inside it is shortened below.
        s = s.replacingOccurrences(of: "`", with: "")
        s = s.replacingOccurrences(of: #"(\*\*|__|~~)"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?<![\w*])[*_](?=\S)([^*_]+?)(?<=\S)[*_](?![\w*])"#, with: "$1", options: .regularExpression)
        // Paths with two or more folders read as their last part.
        s = replacing(#"(?<![\w.])(?:~|\.{1,2})?/?(?:[\w.@+-]+/){2,}([\w.@+-]+)"#, in: s) { groups in groups[1] }
        s = s.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// A line as a sentence: inline Markdown read, a full stop added when
    /// it has none, so lines don't run into each other.
    static func sentence(_ line: String) -> String {
        let text = inline(line)
        guard let last = text.last else { return "" }
        return ".!?:;…".contains(last) ? text : text + "."
    }

    static func joined(_ paragraph: String, _ summary: String) -> String {
        var base = paragraph
        while let last = base.last, ".:;".contains(last) { base.removeLast() }
        return "\(base), \(summary)."
    }

    static func capitalized(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst() + "."
    }

    private static func replacing(_ pattern: String, in text: String, with build: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let groups = (0..<match.numberOfRanges).map { i -> String in
                let range = match.range(at: i)
                return range.location == NSNotFound ? "" : ns.substring(with: range)
            }
            result += build(groups)
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }
}
