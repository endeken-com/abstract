import SwiftUI
import AppKit
import AbstractCore

/// ⌘F in the Review tab: what you're finding, the matches over every file
/// of the changes shown (open, collapsed or not drawn yet), and which one
/// you're on. Kept with the chat's review, so it's there when you come back.
@MainActor
@Observable
final class ReviewFind {
    private(set) var isOpen = false
    var query = "" {
        didSet { if query != oldValue { search() } }
    }
    var options = DiffSearch() {
        didSet { if options != oldValue { search() } }
    }
    private(set) var state = DiffFind()
    /// Bumped to put the cursor in the find field.
    private(set) var focusRequest = 0

    /// The review's files, in the order it lists them.
    @ObservationIgnored private var files: [FileDiff] = []
    /// Takes the diff to a match.
    @ObservationIgnored var reveal: ((DiffMatch) -> Void)?
    /// Where the keyboard was before the bar opened, to hand it back on close.
    @ObservationIgnored private weak var returnTo: NSResponder?

    func open() {
        if !isOpen {
            returnTo = NSApp.keyWindow?.firstResponder
            isOpen = true
            if !query.isEmpty { search() }
        }
        focusRequest += 1
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        state = DiffFind()
        // A text field's editor stands in for the field: hand the keyboard back to the field.
        let responder = (returnTo as? NSTextView).flatMap { $0.isFieldEditor ? $0.delegate as? NSResponder : nil } ?? returnTo
        if let responder, let window = (responder as? NSView)?.window ?? NSApp.keyWindow {
            window.makeFirstResponder(responder)
        }
        returnTo = nil
    }

    func next() {
        guard isOpen, let match = state.next() else { return }
        reveal?(match)
    }

    func previous() {
        guard isOpen, let match = state.previous() else { return }
        reveal?(match)
    }

    /// The review read its changes again, or shows other ones.
    func filesChanged(_ files: [FileDiff]) {
        self.files = files
        guard isOpen else { return }
        state.refresh(files, using: options)
    }

    private func search() {
        guard isOpen else { return }
        state.search(query, in: files, using: options)
    }

    /// What the rows mark, while the bar is open with words in it.
    var rowFind: DiffRowFind? {
        guard isOpen, !query.isEmpty else { return nil }
        return DiffRowFind(query: query, options: options, current: state.currentMatch)
    }
}

// MARK: - Highlights

/// The words being found, as the diff's rows draw them, and the match you're on.
struct DiffRowFind: Equatable {
    let query: String
    let options: DiffSearch
    let current: DiffMatch?

    /// `line` marked: every appearance washed, the current one brighter.
    func mark(_ text: AttributedString, line: NumberedLine, in file: ReviewFile) -> AttributedString {
        guard let origin = line.origin, options.includes(origin) else { return text }
        return FindMarks.mark(text, ranges: { options.ranges(of: query, in: $0) },
                              current: isCurrent(line, in: file) ? current?.occurrence : nil)
    }

    private func isCurrent(_ line: NumberedLine, in file: ReviewFile) -> Bool {
        guard let current, current.path == file.path, current.origin == line.origin else { return false }
        return current.oldLine == Int(line.old) && current.newLine == Int(line.new)
    }
}

extension NumberedLine {
    var origin: DiffLine.Origin? {
        switch kind {
        case .context: .context
        case .added: .added
        case .removed: .removed
        case .note: nil
        }
    }
}

extension ReviewFile {
    /// The row a match is on, in the layout shown.
    func row(of match: DiffMatch, split: Bool) -> DiffRowID? {
        func same(_ line: NumberedLine?) -> Bool {
            guard let line, line.origin == match.origin else { return false }
            return Int(line.old) == match.oldLine && Int(line.new) == match.newLine
        }
        let rows = split ? self.split : unified
        return rows.first { row in
            switch row.content {
            case .hunk: false
            case .line(let line): same(line)
            case .pair(let left, let right): same(left) || same(right)
            }
        }?.id
    }
}

extension EnvironmentValues {
    @Entry var diffFind: DiffRowFind? = nil
}

// MARK: - The bar

/// The find bar above the diff: the words, how many matches and which one
/// you're on, the way between them, and which lines to look in.
struct ReviewFindBar: View {
    @Bindable var find: ReviewFind
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.btTextTertiary)
            TextField("Find in changes", text: $find.query)
                .textFieldStyle(.plain)
                .font(.btBody)
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
                    .font(.btCaption)
                    .foregroundStyle(Color.btTextTertiary)
                    .monospacedDigit()
                    .fixedSize()
            }
            Button { find.options.caseSensitive.toggle() } label: {
                Text(verbatim: "Aa")
                    .font(BTFont.ui(12, .semibold))
                    .foregroundStyle(find.options.caseSensitive ? Color.btText : Color.btTextTertiary)
            }
            .buttonStyle(.icon(size: 22))
            .help(find.options.caseSensitive ? "Matching case: click to ignore it" : "Ignoring case: click to match it")
            Picker("Lines", selection: $find.options.lines) {
                Text("All Lines").tag(DiffSearch.Lines.all)
                Text("Added Lines").tag(DiffSearch.Lines.added)
                Text("Removed Lines").tag(DiffSearch.Lines.removed)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
            .help("Which lines to look in")
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
        .padding(.trailing, Space.sm)
        .frame(height: 36)
        .background(Color.btCanvas)
        .overlay(alignment: .bottom) { Hairline() }
        .onAppear { focused = true }
        .onChange(of: find.focusRequest) { focused = true }
    }
}
