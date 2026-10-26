import SwiftUI
import Textual
import AbstractCore

/// ⌘F in a chat: what you're finding, the matches over the chat's whole
/// timeline (not just the rows on screen), and which one you're on. Kept
/// with the chat, so it's there when you come back to it.
@MainActor
@Observable
final class ChatFind {
    private(set) var isOpen = false
    var query = "" {
        didSet { if query != oldValue { search() } }
    }
    private(set) var state = TranscriptFind()
    /// Bumped to put the cursor in the find field.
    private(set) var focusRequest = 0
    /// Bumped when the bar closes, which hands the keyboard back to the reply box.
    private(set) var closings = 0

    @ObservationIgnored private unowned let feed: ChatFeed
    /// Thinking is found only while the transcript shows it.
    @ObservationIgnored var includesThinking = false {
        didSet { if includesThinking != oldValue, isOpen { search() } }
    }
    /// The chat's worktree, so file paths are found as the transcript shows them.
    @ObservationIgnored var root: String?
    /// The block at the top of the transcript's view: a new search starts there.
    @ObservationIgnored var topBlock: (() -> Int?)?
    /// Takes the transcript to a match.
    @ObservationIgnored var reveal: ((TranscriptMatch) -> Void)?
    @ObservationIgnored private var refreshing: Task<Void, Never>?

    init(feed: ChatFeed) { self.feed = feed }

    func open() {
        if !isOpen {
            isOpen = true
            if !query.isEmpty { search() }
        }
        focusRequest += 1
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        refreshing?.cancel()
        refreshing = nil
        state = TranscriptFind()
        closings += 1
    }

    func next() {
        guard isOpen, let match = state.next() else { return }
        reveal?(match)
    }

    func previous() {
        guard isOpen, let match = state.previous() else { return }
        reveal?(match)
    }

    /// The chat grew. Streaming changes it many times a second, so the
    /// matches catch up a few times a second at most.
    func chatChanged() {
        guard isOpen, !query.isEmpty, refreshing == nil else { return }
        refreshing = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            self.refreshing = nil
            guard self.isOpen else { return }
            self.state.refresh(self.feed.timeline.blocks, using: self.scope)
        }
    }

    private func search() {
        guard isOpen else { return }
        state.search(query, in: feed.timeline.blocks, using: scope, from: topBlock?())
    }

    private var scope: TranscriptSearch {
        let root = root
        return TranscriptSearch(includesThinking: includesThinking) { call in
            MainActor.assumeIsolated { Self.fields(call, root: root) }
        }
    }

    /// A call's title as its row shows it (the command, or the file's path in
    /// the worktree), and what it returned where the row can show that.
    static func fields(_ call: ToolCall, root: String?) -> [(TranscriptField, String)] {
        var out: [(TranscriptField, String)] = []
        let title: String? = switch ToolPresentation.target(call, root: root) {
        case let .path(name, folder)?: [folder, name].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "/")
        case .command?: ToolPresentation.command(call)
        case let .text(text)?: text
        case nil: nil
        }
        if let title, !title.isEmpty { out.append((.toolTitle(callId: call.id), title)) }
        switch ToolKind(call.name) {
        case .command, .explore, .other, .delegate:
            if let output = call.result?.output, !output.isEmpty { out.append((.toolOutput(callId: call.id), output)) }
        case .plan:
            if let plan = call.input["plan"]?.string { out.append((.toolOutput(callId: call.id), plan)) }
        case .edit, .todo, .question:
            break
        }
        return out
    }
}

// MARK: - Highlights

/// The words being found, as a transcript row draws them, and which of its
/// matches is the one you're on.
struct RowFind: Equatable {
    let query: String
    let current: FindSpot?

    /// The appearance you're on in `field`, if it's in that field.
    func current(in field: String) -> Int? { current?.field == field ? current?.occurrence : nil }
}

/// A match within a row: which of its texts ("reply", "user", "thinking",
/// "title:<call>", "out:<call>"), and which appearance of the words there.
struct FindSpot: Equatable {
    let field: String
    let occurrence: Int

    static func field(_ field: TranscriptField) -> String {
        switch field {
        case .user: "user"
        case .reply: "reply"
        case .thinking: "thinking"
        case let .toolTitle(id): "title:\(id)"
        case let .toolOutput(id): "out:\(id)"
        }
    }
}

extension EnvironmentValues {
    @Entry var transcriptFind: RowFind? = nil
}

/// Marks the words being found in text about to be drawn.
enum FindMarks {
    /// Every appearance washed, the current one (by its place among them) brighter.
    static func mark(_ text: AttributedString, query: String, current: Int?) -> AttributedString {
        guard !query.isEmpty else { return text }
        return mark(text, ranges: { TranscriptSearch.ranges(of: query, in: $0) }, current: current)
    }

    /// The same, for words found by other rules (a review's diff can match case).
    static func mark(_ text: AttributedString, ranges: (String) -> [Range<String.Index>], current: Int?) -> AttributedString {
        var out = text
        let plain = String(text.characters)
        for (i, range) in ranges(plain).enumerated() {
            let start = plain.distance(from: plain.startIndex, to: range.lowerBound)
            let length = plain.distance(from: range.lowerBound, to: range.upperBound)
            let lower = out.characters.index(out.startIndex, offsetBy: start)
            let upper = out.characters.index(lower, offsetBy: length)
            out[lower..<upper].backgroundColor = i == current ? .btFindCurrent : .btFindMatch
        }
        return out
    }

    /// Lines of one text: the appearances counted across them all.
    static func mark(lines: [String], query: String, current: Int?) -> [AttributedString] {
        var seen = 0
        return lines.map { line in
            let count = TranscriptSearch.ranges(of: query, in: line).count
            defer { seen += count }
            guard count > 0 else { return AttributedString(line) }
            return mark(AttributedString(line), query: query, current: current.map { $0 - seen })
        }
    }
}

/// What a text's marks depend on, so it's parsed again when they change.
struct FindMarkKey: Hashable {
    let query: String
    let current: Int?
}

/// Markdown parsing that marks the words being found.
struct FindMarkParser: MarkupParser {
    let base: any MarkupParser
    let query: String
    let current: Int?

    func attributedString(for input: String) throws -> AttributedString {
        FindMarks.mark(try base.attributedString(for: input), query: query, current: current)
    }
}

// MARK: - The bar

/// The find bar over the transcript: the words, how many matches and which
/// one you're on, and the way between them.
struct TranscriptFindBar: View {
    @Bindable var find: ChatFind
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.btTextTertiary)
            TextField("Find in chat", text: $find.query)
                .textFieldStyle(.plain)
                .font(.btChatBody)
                .focused($focused)
                .onSubmit { find.next() }
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    find.previous()
                    return .handled
                }
                .onExitCommand { find.close() }
            if !find.state.label.isEmpty {
                Text(find.state.label)
                    .font(.btChatCaption)
                    .foregroundStyle(Color.btTextTertiary)
                    .monospacedDigit()
                    .fixedSize()
            }
            HStack(spacing: 0) {
                Button { find.previous() } label: { Image(systemName: "chevron.up") }
                    .help("Previous match (⇧⌘G)")
                Button { find.next() } label: { Image(systemName: "chevron.down") }
                    .help("Next match (⌘G)")
            }
            .buttonStyle(.icon(size: 22))
            .disabled(find.state.matches.isEmpty)
            Button("Done") { find.close() }
                .buttonStyle(.bt(.ghost, size: .small))
                .help("Close the find bar (Esc)")
        }
        .padding(.leading, Space.md)
        .padding(.trailing, Space.xs)
        .frame(height: 34)
        .background(Color.btSurfaceRaised, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Color.btBorderStrong))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .onAppear { focused = true }
        .onChange(of: find.focusRequest) { focused = true }
    }
}
