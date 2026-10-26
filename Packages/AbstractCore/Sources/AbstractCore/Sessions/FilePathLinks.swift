import Foundation

/// File paths in an agent's reply, turned into links that open the file:
/// an inline-code path (`` `assets/logo.png` ``), a bare relative path, or
/// an absolute one inside the chat's worktree, optionally with a `:line`.
/// Code blocks, links and URLs are left alone, as is anything that isn't a
/// file in the worktree.
public enum FilePathLinks {
    public static let scheme = "abstract-file"

    /// A file in the worktree, relative to its root, and the line to show.
    public struct Target: Hashable, Sendable {
        public var path: String
        public var line: Int?
        public init(path: String, line: Int? = nil) { self.path = path; self.line = line }
    }

    /// Every path in `markdown` that might be a file, relative to `root`:
    /// what to ask the worktree about before linking.
    public static func candidates(in markdown: String, root: String, limit: Int = 64) -> [String] {
        var found: [String] = []
        var seen: Set<String> = []
        _ = rewrite(markdown, root: root) { target in
            if found.count < limit, seen.insert(target.path).inserted { found.append(target.path) }
            return false
        }
        return found
    }

    /// `markdown` with each path that is one of `files` (relative to `root`) as a link.
    public static func link(_ markdown: String, root: String, files: Set<String>) -> String {
        guard !files.isEmpty else { return markdown }
        return rewrite(markdown, root: root) { files.contains($0.path) }
    }

    public static func url(_ target: Target) -> URL {
        var allowed = CharacterSet.urlPathAllowed
        // Kept out so the link's destination never closes early in Markdown.
        allowed.remove(charactersIn: "()<> ")
        let path = target.path.addingPercentEncoding(withAllowedCharacters: allowed) ?? target.path
        return URL(string: "\(scheme):///\(path)" + (target.line.map { "?line=\($0)" } ?? ""))!
    }

    public static func target(_ url: URL) -> Target? {
        guard url.scheme == scheme, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let path = String(components.path.drop { $0 == "/" })
        guard !path.isEmpty else { return nil }
        let line = components.queryItems?.first { $0.name == "line" }?.value.flatMap { Int($0) }
        return Target(path: path, line: line)
    }

    /// The path `text` names, relative to `root`, when it names one at all.
    static func resolve(_ text: String, root: String) -> Target? {
        var path = text.trimmingCharacters(in: .whitespaces)
        var line: Int?
        // `src/app.swift:42` or `src/app.swift:42:7`.
        let parts = path.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count >= 2, parts.count <= 3, parts.dropFirst().allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCIIDigit) }) {
            path = String(parts[0])
            line = Int(parts[1])
        }
        guard !path.isEmpty, !path.contains("://"), path.rangeOfCharacter(from: unwanted) == nil,
              let first = path.first, !"-@~$%#".contains(first) else { return nil }
        if path.hasPrefix("/") {
            var base = root
            while base.hasSuffix("/") { base.removeLast() }
            guard !base.isEmpty, path.hasPrefix(base + "/") else { return nil }
            path.removeFirst(base.count + 1)
        }
        while path.hasPrefix("./") { path.removeFirst(2) }
        while path.hasSuffix("/") { path.removeLast() }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        // A folder path, or a file name with an extension: "Makefile" alone is
        // too likely to be just a word.
        guard text.contains("/") || hasExtension(path) else { return nil }
        return Target(path: path, line: line)
    }

    private static let unwanted = CharacterSet(charactersIn: "`[]<>\\|*\"'(){}!?,;=")

    private static func hasExtension(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        let ext = name[name.index(after: dot)...]
        return (1...10).contains(ext.count) && ext.allSatisfy { $0.isASCIIDigit || $0.isLetter } && ext.contains { $0.isLetter }
    }

    // MARK: Scanning

    /// Walks the Markdown outside code blocks, links and autolinks, asking
    /// `link` about each path it finds and wrapping those it says yes to.
    private static func rewrite(_ markdown: String, root: String, link: (Target) -> Bool) -> String {
        var out = ""
        out.reserveCapacity(markdown.count)
        var fence: (marker: Character, length: Int)?
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if line.offset > 0 { out += "\n" }
            let text = line.element
            let opener = fenceMarker(text)
            if let open = fence {
                if let opener, opener.marker == open.marker, opener.length >= open.length,
                   text.drop { $0 == " " }.drop { $0 == open.marker }.allSatisfy(\.isWhitespace) {
                    fence = nil
                }
                out += text
                continue
            }
            if let opener {
                fence = opener
                out += text
                continue
            }
            out += rewriteLine(text, root: root, link: link)
        }
        return out
    }

    /// "```" or "~~~" (three or more), indented at most three spaces.
    private static func fenceMarker(_ line: Substring) -> (marker: Character, length: Int)? {
        let indent = line.prefix { $0 == " " }.count
        guard indent <= 3 else { return nil }
        let rest = line.dropFirst(indent)
        guard let marker = rest.first, marker == "`" || marker == "~" else { return nil }
        let length = rest.prefix { $0 == marker }.count
        return length >= 3 ? (marker, length) : nil
    }

    private static func rewriteLine(_ line: Substring, root: String, link: (Target) -> Bool) -> String {
        var out = ""
        var plain = ""
        func flushPlain() {
            out += rewritePlain(plain, root: root, link: link)
            plain = ""
        }
        var i = line.startIndex
        while i < line.endIndex {
            let c = line[i]
            if c == "\\", line.index(after: i) < line.endIndex {
                // An escaped character stays as written.
                let next = line.index(i, offsetBy: 2)
                plain += line[i..<next]
                i = next
            } else if c == "`" {
                let run = line[i...].prefix { $0 == "`" }
                let afterOpen = run.endIndex
                guard let close = closingRun(of: run.count, in: line[afterOpen...]) else {
                    plain += run
                    i = afterOpen
                    continue
                }
                flushPlain()
                let span = line[i..<close.upperBound]
                let content = String(line[afterOpen..<close.lowerBound])
                if let target = resolve(content, root: root), link(target) {
                    out += "[\(span)](\(url(target).absoluteString))"
                } else {
                    out += span
                }
                i = close.upperBound
            } else if c == "[" || c == "<" || (c == "!" && line[line.index(after: i)...].first == "["), let end = linkEnd(line, from: i) {
                // An existing link, image or autolink is copied as it is.
                flushPlain()
                out += line[i..<end]
                i = end
            } else {
                plain.append(c)
                i = line.index(after: i)
            }
        }
        flushPlain()
        return out
    }

    /// The closing backtick run of exactly `length`, as CommonMark matches code spans.
    private static func closingRun(of length: Int, in text: Substring) -> Range<Substring.Index>? {
        var i = text.startIndex
        while i < text.endIndex {
            guard text[i] == "`" else { i = text.index(after: i); continue }
            let run = text[i...].prefix { $0 == "`" }
            if run.count == length { return i..<run.endIndex }
            i = run.endIndex
        }
        return nil
    }

    /// Where a `[text](url)`, `![alt](url)`, `[text][ref]` or `<url>` starting at `start` ends.
    private static func linkEnd(_ line: Substring, from start: Substring.Index) -> Substring.Index? {
        var i = start
        if line[i] == "<" {
            guard let close = line[i...].firstIndex(of: ">") else { return nil }
            let inner = line[line.index(after: i)..<close]
            return inner.contains(":") && !inner.contains(" ") ? line.index(after: close) : nil
        }
        if line[i] == "!" { i = line.index(after: i) }
        guard let closeBracket = line[i...].firstIndex(of: "]") else { return nil }
        let after = line.index(after: closeBracket)
        guard after < line.endIndex else { return nil }
        let closer: Character
        switch line[after] {
        case "(": closer = ")"
        case "[": closer = "]"
        default: return nil
        }
        guard let end = line[line.index(after: after)...].firstIndex(of: closer) else { return nil }
        return line.index(after: end)
    }

    /// Prose between code spans and links: each word that names a path.
    private static func rewritePlain(_ text: String, root: String, link: (Target) -> Bool) -> String {
        guard text.contains(where: { $0 == "/" || $0 == "." }) else { return text }
        var out = ""
        var word = ""
        func flushWord() {
            out += rewriteWord(word, root: root, link: link)
            word = ""
        }
        for c in text {
            if c.isWhitespace { flushWord(); out.append(c) } else { word.append(c) }
        }
        flushWord()
        return out
    }

    private static let leading: Set<Character> = ["(", "\"", "'", "*", "|"]
    private static let trailing: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "\"", "'", "*", "|"]

    private static func rewriteWord(_ word: String, root: String, link: (Target) -> Bool) -> String {
        guard word.contains(where: { $0 == "/" || $0 == "." }) else { return word }
        let head = word.prefix { leading.contains($0) }
        var core = word.dropFirst(head.count)
        var tail = Substring("")
        while let last = core.last, trailing.contains(last) {
            core = core.dropLast()
            tail = word[core.endIndex...]
        }
        guard !core.isEmpty, let target = resolve(String(core), root: root), link(target) else { return word }
        return "\(head)[\(core)](\(url(target).absoluteString))\(tail)"
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
