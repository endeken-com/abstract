import SwiftUI
import AbstractCore

/// A line of code a comment is about: in the Review pane (either side of a
/// change) or in the Files pane.
nonisolated struct LineRef: Hashable, Sendable {
    enum Side: Hashable, Sendable {
        /// The file as it is now: a context, added or unchanged line.
        case new
        /// A line the agent removed.
        case old
    }
    let path: String
    let line: Int
    let side: Side
}

/// Where a commented line sits in its change: the hunk's header and up to
/// three lines either side of it, as Paseo sends them.
nonisolated struct ReviewLineContext: Hashable, Sendable {
    struct Line: Hashable, Sendable {
        let old: Int?
        let new: Int?
        let kind: NumberedLine.Kind
        let text: String
        let isTarget: Bool
    }
    let hunkHeader: String
    let lines: [Line]
}

/// A note on one line, kept with the chat until it goes to the agent with
/// the others.
nonisolated struct LineComment: Identifiable, Hashable, Sendable {
    let id: UUID
    let ref: LineRef
    /// The line's code, quoted back to the agent.
    let code: String
    var text: String
    /// The lines around it in the change, for comments made in the review.
    var context: ReviewLineContext? = nil
    /// What the review compared when it was written: "uncommitted", "committed", a commit.
    var source: String? = nil
}

extension AppModel {
    func comments(_ sessionId: String) -> [LineComment] { lineComments[sessionId] ?? [] }

    func comments(_ sessionId: String, on ref: LineRef) -> [LineComment] {
        comments(sessionId).filter { $0.ref == ref }
    }

    func addComment(_ sessionId: String, on ref: LineRef, code: String, text: String,
                    context: ReviewLineContext? = nil, source: String? = nil) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        lineComments[sessionId, default: []].append(LineComment(id: UUID(), ref: ref, code: code, text: text,
                                                                context: context, source: source))
    }

    func updateComment(_ sessionId: String, _ id: UUID, text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let i = lineComments[sessionId]?.firstIndex(where: { $0.id == id }) else { return }
        if text.isEmpty { lineComments[sessionId]?.remove(at: i) } else { lineComments[sessionId]?[i].text = text }
    }

    func removeComment(_ sessionId: String, _ id: UUID) {
        lineComments[sessionId]?.removeAll { $0.id == id }
    }

    func discardComments(_ sessionId: String) { lineComments[sessionId] = nil }

    /// Your message with the review attached after it, as the agent gets it.
    /// Sending clears the comments.
    func messageWithReview(_ sessionId: String, text: String) -> String {
        let comments = comments(sessionId)
        guard !comments.isEmpty else { return text }
        let attachment = Self.reviewAttachment(comments, cwd: session(sessionId)?.worktreePath)
        return text.isEmpty ? attachment : text + "\n\n" + attachment
    }

    /// The review as text for the agent: each comment's place, what it says,
    /// and the lines around it with their numbers, the commented one marked.
    /// Paseo's review attachment format (Apache-2.0, Copyright (c)
    /// 2025-present Mohamed Boudra).
    nonisolated static func reviewAttachment(_ comments: [LineComment], cwd: String?) -> String {
        let ordered = comments.sorted { ($0.ref.path, $0.ref.line) < ($1.ref.path, $1.ref.line) }
        let sources = Set(ordered.compactMap(\.source))
        var lines = ["Review attachment (\(sources.count == 1 ? sources.first! : "review"))"]
        if let cwd { lines.append("CWD: \(cwd)") }
        for (i, c) in ordered.enumerated() {
            lines.append("")
            lines.append("Comment \(i + 1): \(c.ref.path):\(c.ref.side == .old ? "old" : "new"):\(c.ref.line)")
            lines.append(c.text)
            if let context = c.context {
                lines.append(context.hunkHeader)
                for line in context.lines {
                    let old = line.old.map(String.init) ?? "-", new = line.new.map(String.init) ?? "-"
                    let marker = line.kind == .added ? "+" : line.kind == .removed ? "-" : " "
                    lines.append((line.isTarget ? "> " : "  ") + pad(old) + " " + pad(new) + " " + marker + line.text)
                }
            } else if !c.code.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append("> " + pad(String(c.ref.line)) + " " + c.code)
            }
        }
        return lines.joined(separator: "\n")
    }

    private nonisolated static func pad(_ s: String) -> String { s.count >= 2 ? s : String(repeating: " ", count: 2 - s.count) + s }
}

/// Which line has its comment editor open, shared by a pane's rows.
@Observable
final class CommentDrafting {
    var ref: LineRef?
}

private struct CommentDraftingKey: EnvironmentKey { static let defaultValue: CommentDrafting? = nil }

extension EnvironmentValues {
    var commentDrafting: CommentDrafting? {
        get { self[CommentDraftingKey.self] }
        set { self[CommentDraftingKey.self] = newValue }
    }
}

// MARK: - Views

/// The small "add a comment" button that shows in a line's gutter on hover.
struct AddCommentButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.btCanvas)
                .frame(width: 15, height: 15)
                .background(Color.btText, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Comment on this line")
    }
}

/// A line's comments and, when open, the editor for a new one. Sits under
/// the line it belongs to.
struct LineCommentThread: View {
    @Environment(AppModel.self) private var model
    @Environment(\.commentDrafting) private var drafting
    let sessionId: String
    let ref: LineRef
    let code: String
    /// Widest the thread gets; a pane that scrolls sideways passes what it shows.
    var maxWidth: CGFloat = 560
    /// The lines around this one, worked out when a comment is saved.
    var context: (() -> ReviewLineContext?)? = nil
    var source: String? = nil

    var body: some View {
        let comments = model.comments(sessionId, on: ref)
        let composing = drafting?.ref == ref
        if !comments.isEmpty || composing {
            VStack(alignment: .leading, spacing: Space.sm) {
                ForEach(comments) { comment in
                    SavedComment(sessionId: sessionId, comment: comment)
                }
                if composing {
                    CommentEditor(initial: "", confirm: "Comment") { text in
                        model.addComment(sessionId, on: ref, code: code, text: text, context: context?(), source: source)
                        drafting?.ref = nil
                    } cancel: {
                        drafting?.ref = nil
                    }
                }
            }
            .padding(.vertical, Space.sm)
            .padding(.horizontal, Space.md)
            .frame(maxWidth: maxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.btSurface)
        }
    }
}

private struct SavedComment: View {
    @Environment(AppModel.self) private var model
    let sessionId: String
    let comment: LineComment
    @State private var editing = false
    @State private var hovering = false

    var body: some View {
        if editing {
            CommentEditor(initial: comment.text, confirm: "Save") { text in
                model.updateComment(sessionId, comment.id, text: text)
                editing = false
            } cancel: {
                editing = false
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                Text(comment.text)
                    .font(.btBody)
                    .foregroundStyle(Color.btText)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 2) {
                    Button { editing = true } label: { Image(systemName: "pencil") }
                        .help("Edit comment")
                    Button { model.removeComment(sessionId, comment.id) } label: { Image(systemName: "trash") }
                        .help("Delete comment")
                }
                .buttonStyle(.icon(size: 22))
                .opacity(hovering ? 1 : 0)
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
        }
    }
}

private struct CommentEditor: View {
    let initial: String
    let confirm: String
    let save: (String) -> Void
    let cancel: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    init(initial: String, confirm: String, save: @escaping (String) -> Void, cancel: @escaping () -> Void) {
        self.initial = initial; self.confirm = confirm; self.save = save; self.cancel = cancel
        _text = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: Space.sm) {
            TextField("Leave a comment", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.btInput)
                .lineLimit(2...8)
                .focused($focused)
                .padding(.horizontal, Field.inset)
                .padding(.vertical, 7)
                .btFieldChrome(focused: focused)
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    save(text)
                    return .handled
                }
                .onExitCommand(perform: cancel)
            HStack(spacing: Space.sm) {
                Button("Cancel", action: cancel).buttonStyle(.bt(.ghost, size: .small))
                Button(confirm) { save(text) }
                    .buttonStyle(.bt(.primary, size: .small))
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("\(confirm) (⌘↩)")
            }
        }
        .onAppear { focused = true }
    }
}

/// The review riding along with your next message, in the composer: its
/// comments go to the agent with whatever you send, as in Paseo. Click to
/// see them in the review; × drops them.
struct ReviewPill: View {
    @Environment(AppModel.self) private var model
    let sessionId: String
    @State private var hovering = false

    var body: some View {
        let count = model.comments(sessionId).count
        if count > 0 {
            HStack(spacing: 6) {
                Button { model.openDiffTab(in: sessionId) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "text.bubble").font(.system(size: 10.5))
                        Text("Review").font(BTFont.ui(12, .medium)).foregroundStyle(Color.btText)
                        Text("\(count) comment\(count == 1 ? "" : "s")").font(.btCaption).foregroundStyle(Color.btTextSecondary)
                    }
                }
                .buttonStyle(.plain)
                .help("Sent with your next message. Click to see the comments.")
                Button { model.discardComments(sessionId) } label: {
                    Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(hovering ? Color.btText : Color.btTextTertiary)
                .help("Remove the review comments")
            }
            .foregroundStyle(Color.btTextSecondary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Color.btSurface, in: Capsule())
            .onHover { hovering = $0 }
            .transition(.opacity)
        }
    }
}
