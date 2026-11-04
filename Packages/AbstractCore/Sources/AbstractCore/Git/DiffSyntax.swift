import Foundation

/// Syntax colour for a diff, a hunk at a time so a comment or string that
/// spans lines reads right. Each side is coloured on its own: the old side
/// colours removed lines, the new side added and unchanged ones, with the
/// unchanged lines giving the grammar its context. Review and a chat's edit
/// rows both colour through this, so the two read the same.
public enum DiffSyntax {
    public enum Kind: Sendable, Hashable { case context, added, removed, other }

    /// Edits longer than this stay plain.
    public static let editLimit = 2_000
    /// An edit row clips lines longer than this (`TextClip`); those stay plain.
    public static let clippedLine = 2_000

    /// A hunk's lines coloured, one entry per line, nil for a line that stays
    /// plain. `tokenize` colours code (lines joined by "\n") into one array a
    /// line, nil for a language it doesn't know. Lines over `longest`
    /// characters stay plain and give no context.
    public static func hunk<Token: Sendable>(_ lines: [(kind: Kind, text: String)], longest: Int = .max,
                                             tokenize: @Sendable (String) async -> [[Token]]?) async -> [[Token]?] {
        var out = [[Token]?](repeating: nil, count: lines.count)
        let sides: [(side: Set<Kind>, keep: Set<Kind>)] = [([.context, .removed], [.removed]), ([.context, .added], [.context, .added])]
        for (side, keep) in sides {
            let indices = lines.indices.filter { side.contains(lines[$0].kind) }
            guard indices.contains(where: { keep.contains(lines[$0].kind) }) else { continue }
            let code = indices.map { lines[$0].text.count > longest ? "" : lines[$0].text }.joined(separator: "\n")
            guard let tokens = await tokenize(code) else { return out }
            for (index, line) in zip(indices, tokens) where keep.contains(lines[index].kind) && lines[index].text.count <= longest {
                out[index] = line
            }
        }
        return out
    }

    /// An edit's lines coloured, one entry per line, nil where plain. Each
    /// hunk (from a line that `startsHunk`) colours on its own.
    public static func edit<Token: Sendable>(_ edit: EditPreview,
                                             tokenize: @Sendable (String) async -> [[Token]]?) async -> [[Token]?] {
        guard edit.lines.count <= editLimit else { return Array(repeating: nil, count: edit.lines.count) }
        var out: [[Token]?] = []
        var start = 0
        for end in edit.lines.indices.dropFirst().filter({ edit.lines[$0].startsHunk == true }) + [edit.lines.count] {
            let hunk = edit.lines[start..<end].map { (kind: Kind($0.origin), text: $0.content) }
            out += await self.hunk(hunk, longest: clippedLine, tokenize: tokenize)
            start = end
        }
        return out
    }

    /// What a coloured edit is kept under: the edit (its path picks the
    /// language) and the theme its colours come from.
    public struct EditKey: Hashable, Sendable {
        public let edit: EditPreview
        public let theme: String
        public init(edit: EditPreview, theme: String) { self.edit = edit; self.theme = theme }
    }
}

extension DiffSyntax.Kind {
    public init(_ origin: EditPreview.Origin) {
        switch origin {
        case .context: self = .context
        case .added: self = .added
        case .removed: self = .removed
        }
    }
}
