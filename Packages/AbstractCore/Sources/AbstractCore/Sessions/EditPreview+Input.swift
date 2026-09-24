import Foundation

extension EditPreview {
    /// The change a file tool is about to make, read from its input alone, so
    /// the diff shows while the tool runs or waits for approval. Covers
    /// Claude's Edit, MultiEdit and Write; nil for anything else.
    public static func fromToolInput(name: String, input: JSONValue) -> EditPreview? {
        guard let o = input.object else { return nil }
        let path = o["file_path"]?.string ?? o["path"]?.string ?? ""
        switch name.lowercased() {
        case "edit":
            guard let old = o["old_string"]?.string, let new = o["new_string"]?.string else { return nil }
            return make(path, lineDiff(old, new))
        case "multiedit":
            let parts = (o["edits"]?.array ?? []).compactMap { edit -> [Line]? in
                guard let old = edit["old_string"]?.string, let new = edit["new_string"]?.string else { return nil }
                return lineDiff(old, new)
            }
            let lines = parts.enumerated().flatMap { index, part in
                part.enumerated().map { i, line in
                    var l = line
                    if index > 0, i == 0 { l.startsHunk = true }
                    return l
                }
            }
            return lines.isEmpty ? nil : make(path, lines)
        case "write":
            guard let content = o["content"]?.string else { return nil }
            return make(path, splitLines(content).enumerated().map { i, text in Line(origin: .added, content: text, newLine: i + 1) })
        default:
            return nil
        }
    }

    private static let maxLines = 200

    private static func make(_ path: String, _ lines: [Line]) -> EditPreview {
        EditPreview(filePath: path,
                    additions: lines.count { $0.origin == .added },
                    deletions: lines.count { $0.origin == .removed },
                    lines: Array(lines.prefix(maxLines)))
    }

    /// Lines of `text`, without the empty one a trailing newline leaves.
    static func splitLines(_ text: String) -> [String] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.count > 1, lines.last == "" { lines.removeLast() }
        return lines
    }

    /// A line diff of two snippets: shared lines stay as context, the rest
    /// become removals and additions. Longest common subsequence on the
    /// middle, after trimming the shared head and tail; very large inputs
    /// fall back to "all old out, all new in".
    static func lineDiff(_ old: String, _ new: String) -> [Line] {
        let a = splitLines(old), b = splitLines(new)
        var head = 0
        while head < a.count, head < b.count, a[head] == b[head] { head += 1 }
        var tail = 0
        while tail < a.count - head, tail < b.count - head, a[a.count - 1 - tail] == b[b.count - 1 - tail] { tail += 1 }
        let midA = Array(a[head..<(a.count - tail)]), midB = Array(b[head..<(b.count - tail)])

        var middle: [Line] = []
        if midA.count * midB.count > 250_000 {
            middle = midA.map { Line(origin: .removed, content: $0) } + midB.map { Line(origin: .added, content: $0) }
        } else {
            // lcs[i][j] = length of the LCS of midA[i...] and midB[j...].
            var lcs = Array(repeating: Array(repeating: 0, count: midB.count + 1), count: midA.count + 1)
            for i in stride(from: midA.count - 1, through: 0, by: -1) {
                for j in stride(from: midB.count - 1, through: 0, by: -1) {
                    lcs[i][j] = midA[i] == midB[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
            var i = 0, j = 0
            while i < midA.count || j < midB.count {
                if i < midA.count, j < midB.count, midA[i] == midB[j] {
                    middle.append(Line(origin: .context, content: midA[i])); i += 1; j += 1
                } else if j == midB.count || (i < midA.count && lcs[i + 1][j] >= lcs[i][j + 1]) {
                    // Ties go to the removal, so "−" lines read before their "+".
                    middle.append(Line(origin: .removed, content: midA[i])); i += 1
                } else {
                    middle.append(Line(origin: .added, content: midB[j])); j += 1
                }
            }
        }
        return a[..<head].map { Line(origin: .context, content: $0) }
            + middle
            + a[(a.count - tail)...].map { Line(origin: .context, content: $0) }
    }
}
