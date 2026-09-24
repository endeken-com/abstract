import Foundation

/// Cuts a reply into its Markdown blocks (paragraphs, headings, lists, code
/// blocks, tables), so each renders on its own and a streaming reply only
/// re-renders the block still being written. Split on blank lines, except
/// where a blank line belongs to the block around it: inside a fenced code
/// block, or between the items and paragraphs of one list.
///
/// Ported from Paseo's `split-markdown-blocks.ts` (Apache-2.0,
/// Copyright (c) 2025-present Mohamed Boudra); rewritten for Swift without a
/// Markdown parser.
public enum MarkdownBlocks {
    public static func split(_ text: String) -> [String] {
        var blocks: [[Substring]] = []
        var current: [Substring] = []
        var fence: (char: Character, count: Int)?
        var blankBefore = false

        func flush() {
            if !current.isEmpty { blocks.append(current) }
            current = []
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let body = line.drop { $0 == " " }
            if let open = fence {
                // Everything up to the closing fence, blank lines included.
                current.append(line)
                if let close = fenceMarker(body), close.char == open.char, close.count >= open.count,
                   body.drop(while: { $0 == open.char }).allSatisfy(\.isWhitespace) {
                    fence = nil
                }
                continue
            }
            if line.allSatisfy(\.isWhitespace) {
                blankBefore = !current.isEmpty
                continue
            }
            if blankBefore {
                if continuesList(line, block: current) { current.append("") } else { flush() }
                blankBefore = false
            }
            if let open = fenceMarker(body) { fence = open }
            current.append(line)
        }
        flush()

        // A block of only link definitions belongs with the text that uses them.
        var out: [String] = []
        for block in blocks {
            let joined = block.joined(separator: "\n")
            if !out.isEmpty, block.allSatisfy(isLinkDefinition) {
                out[out.count - 1] += "\n\n" + joined
            } else {
                out.append(joined)
            }
        }
        return out
    }

    /// "```" or "~~~" (three or more), with an optional info string.
    private static func fenceMarker(_ line: Substring) -> (char: Character, count: Int)? {
        guard let first = line.first, first == "`" || first == "~" else { return nil }
        let count = line.prefix { $0 == first }.count
        return count >= 3 ? (first, count) : nil
    }

    /// After a blank line, a line that is still part of the list above: an
    /// indented continuation, or the list's next item.
    private static func continuesList(_ line: Substring, block: [Substring]) -> Bool {
        guard let first = block.first, isListItem(first) else { return false }
        return line.hasPrefix("  ") || line.hasPrefix("\t") || isListItem(line)
    }

    static func isListItem(_ line: Substring) -> Bool {
        let body = line.drop { $0 == " " }
        if let first = body.first, "-*+".contains(first), body.dropFirst().first == " " { return true }
        let digits = body.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9 else { return false }
        let rest = body.dropFirst(digits.count)
        return (rest.first == "." || rest.first == ")") && (rest.dropFirst().first == " " || rest.count == 1)
    }

    private static func isLinkDefinition(_ line: Substring) -> Bool {
        let body = line.drop { $0 == " " }
        guard body.first == "[", let close = body.firstIndex(of: "]") else { return false }
        return body[body.index(after: close)...].hasPrefix(":")
    }
}
