import AppKit
import SwiftUI
import AbstractCore

/// The editor's text: an NSTextView with a line-number gutter, syntax colour
/// that follows your typing, the find bar (⌘F), and a comment on any line
/// from its context menu. Looks after Paseo's CodeMirror setup: a quiet
/// gutter with the caret's line number lit, nothing highlighted behind the
/// caret line.
struct CodeTextView: NSViewRepresentable {
    @Environment(AppModel.self) private var model
    let document: EditorDocument
    let sessionId: String
    /// Lines with comments waiting for the agent, marked in the gutter.
    let commented: Set<Int>

    func makeCoordinator() -> Coordinator { Coordinator(document: document, sessionId: sessionId, model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let c = context.coordinator
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay

        let text = EditorTextView(usingTextLayoutManager: false)
        text.coordinator = c
        text.isRichText = false
        text.importsGraphics = false
        text.allowsUndo = true
        text.usesFindBar = true
        text.isIncrementalSearchingEnabled = true
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.isContinuousSpellCheckingEnabled = false
        text.isGrammarCheckingEnabled = false
        text.smartInsertDeleteEnabled = false
        text.drawsBackground = false
        text.insertionPointColor = NSColor(Color.btText)
        text.selectedTextAttributes = [.backgroundColor: NSColor(Color.btSelection)]
        text.textContainerInset = NSSize(width: 10, height: 16)
        text.font = c.font
        text.typingAttributes = c.baseAttributes
        text.defaultParagraphStyle = c.paragraph
        // Long lines scroll sideways rather than wrap, as code does.
        text.isHorizontallyResizable = true
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.delegate = c
        scroll.documentView = text

        let ruler = LineNumberRuler(textView: text, coordinator: c)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true

        c.textView = text
        c.ruler = ruler
        c.show(document.text, editable: isEditable)
        c.startAtFirstColumn(scroll)
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        let c = context.coordinator
        c.commented = commented
        c.textView?.isEditable = isEditable
        if c.revision != document.revision { c.show(document.text, editable: isEditable) }
        if document.goToLine != nil { c.goToLine() }
        c.ruler?.needsDisplay = true
    }

    private var isEditable: Bool {
        if case .text(let editable) = document.content { return editable }
        return false
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let document: EditorDocument
        let sessionId: String
        let model: AppModel
        weak var textView: EditorTextView?
        weak var ruler: LineNumberRuler?
        var revision = -1
        var commented: Set<Int> = []
        /// UTF-16 offset where each line starts.
        private(set) var lineStarts: [Int] = [0]
        private var highlight: Task<Void, Never>?
        private var popover: NSPopover?

        /// Settings › Appearance › Editor font, as it was when the editor opened.
        let fonts = EditorFontChoice.stored
        lazy var font = fonts.nsFont
        lazy var gutterFont = fonts.gutterFont
        lazy var paragraph = fonts.paragraph
        lazy var digitWidth = ("0" as NSString).size(withAttributes: [.font: gutterFont]).width
        var baseAttributes: [NSAttributedString.Key: Any] {
            [.font: font, .foregroundColor: NSColor(Color.btSyntaxPlain), .paragraphStyle: paragraph,
             .ligature: fonts.ligatures ? 1 : 0]
        }

        /// A new editor opens at its first column. Its clip view starts at x 0
        /// and, once the gutter's inset applies, AppKit clamps that to the
        /// right end of the range whenever a line is wider than the view.
        func startAtFirstColumn(_ scroll: NSScrollView) {
            let clip = scroll.contentView
            clip.postsFrameChangedNotifications = true
            firstColumn = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: clip,
                                                                 queue: .main) { [weak self, weak scroll] _ in
                MainActor.assumeIsolated {
                    guard let self, let scroll, scroll.contentView.frame.width > 0, let observer = self.firstColumn else { return }
                    NotificationCenter.default.removeObserver(observer)
                    self.firstColumn = nil
                    DispatchQueue.main.async {
                        let clip = scroll.contentView
                        clip.scroll(to: NSPoint(x: -clip.contentInsets.left, y: clip.bounds.origin.y))
                        scroll.reflectScrolledClipView(clip)
                        self.goToLine()
                    }
                }
            }
        }
        private var firstColumn: NSObjectProtocol?

        /// Puts the caret on the line asked for and scrolls it into the middle,
        /// once the text is in and the editor has its size.
        func goToLine() {
            guard let line = document.goToLine, firstColumn == nil, revision == document.revision,
                  let textView, line >= 1, line <= lineStarts.count else { return }
            let location = lineStarts[line - 1]
            textView.setSelectedRange(NSRange(location: location, length: 0))
            if let layout = textView.layoutManager {
                let glyph = layout.glyphIndexForCharacter(at: min(location, max((textView.string as NSString).length - 1, 0)))
                let rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                let visible = textView.visibleRect
                textView.scroll(NSPoint(x: visible.minX, y: max(rect.midY + textView.textContainerOrigin.y - visible.height / 2, 0)))
            }
            textView.window?.makeFirstResponder(textView)
            let document = document
            DispatchQueue.main.async { document.goToLine = nil }
        }

        init(document: EditorDocument, sessionId: String, model: AppModel) {
            self.document = document
            self.sessionId = sessionId
            self.model = model
        }

        /// Replace the whole text, as read from disk.
        func show(_ string: String, editable: Bool) {
            guard let textView else { return }
            revision = document.revision
            let selection = textView.selectedRange()
            textView.textStorage?.setAttributedString(NSAttributedString(string: string, attributes: baseAttributes))
            textView.isEditable = editable
            textView.setSelectedRange(NSRange(location: min(selection.location, (string as NSString).length), length: 0))
            textView.undoManager?.removeAllActions()
            indexLines(string)
            recolour(after: .zero)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            let string = textView.string
            indexLines(string)
            document.edited(string)
            ruler?.needsDisplay = true
            recolour(after: .milliseconds(150))
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            let location = textView.selectedRange().location
            let line = self.line(at: location)
            document.line = line
            document.column = location - lineStarts[line - 1] + 1
            ruler?.needsDisplay = true
        }

        private func indexLines(_ string: String) {
            var starts = [0]
            var offset = 0
            for unit in string.utf16 {
                offset += 1
                if unit == 0x0A { starts.append(offset) }
            }
            lineStarts = starts
        }

        /// The 1-based line holding a UTF-16 offset.
        func line(at offset: Int) -> Int {
            var lo = 0, hi = lineStarts.count - 1
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if lineStarts[mid] <= offset { lo = mid } else { hi = mid - 1 }
            }
            return lo + 1
        }

        /// Colours the text a moment after typing pauses. Big files stay plain.
        private func recolour(after delay: Duration) {
            highlight?.cancel()
            guard let textView, let language = CodeHighlighter.language(for: document.path),
                  (textView.string as NSString).length < 600_000 else { return }
            let snapshot = textView.string
            highlight = Task { [weak self] in
                if delay > .zero { try? await Task.sleep(for: delay) }
                guard !Task.isCancelled, let lines = await CodeHighlighter.shared.lines(snapshot, language: language) else { return }
                self?.apply(lines, to: snapshot)
            }
        }

        private func apply(_ lines: [[CodeHighlighter.Token]], to snapshot: String) {
            guard let textView, let storage = textView.textStorage, textView.string == snapshot else { return }
            let length = storage.length
            storage.beginEditing()
            storage.addAttribute(.foregroundColor, value: NSColor(Color.btSyntaxPlain), range: NSRange(location: 0, length: length))
            var offset = 0
            for (i, tokens) in lines.enumerated() {
                if i > 0 { offset += 1 }
                for token in tokens {
                    let count = token.text.utf16.count
                    guard offset + count <= length else { break }
                    if let color = SyntaxStyle.color(token.kind) {
                        storage.addAttribute(.foregroundColor, value: NSColor(color), range: NSRange(location: offset, length: count))
                    }
                    offset += count
                }
            }
            storage.endEditing()
        }

        // MARK: Comments

        func comment(onLine line: Int) {
            guard let textView, let layout = textView.layoutManager, let container = textView.textContainer,
                  line - 1 < lineStarts.count else { return }
            let ns = textView.string as NSString
            let start = lineStarts[line - 1]
            let end = line < lineStarts.count ? lineStarts[line] - 1 : ns.length
            let code = ns.substring(with: NSRange(location: start, length: max(0, end - start)))
            let ref = LineRef(path: document.path, line: line, side: .new)
            let context = fileContext(line)
            let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: start, length: max(1, end - start)), actualCharacterRange: nil)
            var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.x += textView.textContainerOrigin.x
            rect.origin.y += textView.textContainerOrigin.y
            rect.size.width = min(rect.width, 240)

            popover?.close()
            let drafting = CommentDrafting()
            drafting.ref = ref
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = NSHostingController(rootView:
                LineCommentThread(sessionId: sessionId, ref: ref, code: code, maxWidth: 380, context: { context }, source: "file")
                    .frame(width: 380)
                    .environment(model)
                    .environment(\.commentDrafting, drafting)
                    .onChange(of: drafting.ref) { _, now in if now == nil { popover.close() } })
            popover.show(relativeTo: rect, of: textView, preferredEdge: .maxY)
            self.popover = popover
        }

        /// The line and three either side, as a file comment's context.
        private func fileContext(_ line: Int) -> ReviewLineContext {
            let ns = (textView?.string ?? "") as NSString
            let lines = (max(1, line - 3)...min(lineStarts.count, line + 3)).map { n -> ReviewLineContext.Line in
                let start = lineStarts[n - 1]
                let end = n < lineStarts.count ? lineStarts[n] - 1 : ns.length
                return .init(old: nil, new: n, kind: .context, text: ns.substring(with: NSRange(location: start, length: max(0, end - start))), isTarget: n == line)
            }
            return ReviewLineContext(hunkHeader: "", lines: lines)
        }
    }
}

/// The text view, with ⌘S and a comment item at the top of its menu.
final class EditorTextView: NSTextView {
    weak var coordinator: CodeTextView.Coordinator?

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard let coordinator else { return menu }
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        let line = coordinator.line(at: index)
        let item = NSMenuItem(title: "Comment on Line \(line)…", action: #selector(commentFromMenu(_:)), keyEquivalent: "")
        item.target = self
        item.tag = line
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }

    @objc private func commentFromMenu(_ sender: NSMenuItem) {
        coordinator?.comment(onLine: sender.tag)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.charactersIgnoringModifiers == "s",
           let document = coordinator?.document {
            Task { await document.save() }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Line numbers beside the text: muted, the caret's line lit, and a mark on
/// lines with comments (click it to read or edit them).
final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?
    private weak var coordinator: CodeTextView.Coordinator?

    init(textView: NSTextView, coordinator: CodeTextView.Coordinator) {
        self.textView = textView
        self.coordinator = coordinator
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        // Wide enough for three digits from the start, so the text never shifts once drawn.
        ruleThickness = 3 * (coordinator.digitWidth + 0.7) + 22
        NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: NSView.boundsDidChangeNotification,
                                               object: textView.enclosingScrollView?.contentView)
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func redraw() { needsDisplay = true }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(Color.btCanvas).setFill()
        bounds.fill()
        NSColor(Color.btBorder).setFill()
        NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer, let coordinator else { return }
        let starts = coordinator.lineStarts
        let digits = max(3, String(starts.count).count)
        let thickness = CGFloat(digits) * (coordinator.digitWidth + 0.7) + 22
        if abs(ruleThickness - thickness) > 0.5 { ruleThickness = thickness }

        let visible = textView.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let caretLine = coordinator.document.line
        let font = coordinator.gutterFont
        let origin = convert(NSPoint.zero, from: textView).y + textView.textContainerOrigin.y
        // Numbers sit on their line's baseline, however tall lines are set
        // (a taller line puts its extra space above the text).
        let baseline: CGFloat? = layout.numberOfGlyphs > 0 ? layout.location(forGlyphAt: 0).y : nil
        var line = coordinator.line(at: characters.location)
        while line <= starts.count {
            let start = starts[line - 1]
            if start > NSMaxRange(characters) { break }
            let length = (textView.string as NSString).length
            // The empty line after a final newline has no glyph: it's the extra fragment.
            let fragment = start >= length
                ? layout.extraLineFragmentRect
                : layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: start), effectiveRange: nil)
            let y = fragment.minY + origin
            let color = line == caretLine ? NSColor(Color.btText) : NSColor(Color.btTextTertiary)
            let label = NSAttributedString(string: "\(line)", attributes: [.font: font, .foregroundColor: color])
            let size = label.size()
            let top = baseline.map { y + $0 - font.ascender } ?? y + (fragment.height - size.height) / 2
            label.draw(at: NSPoint(x: ruleThickness - 12 - size.width, y: top))
            if coordinator.commented.contains(line) {
                let middle = baseline.map { y + $0 - font.xHeight / 2 } ?? y + fragment.height / 2
                NSColor(Color.btText).setFill()
                NSBezierPath(roundedRect: NSRect(x: 5, y: middle - 3, width: 6, height: 6), xRadius: 3, yRadius: 3).fill()
            }
            line += 1
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let textView, let coordinator, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        let point = convert(event.locationInWindow, from: nil)
        let inText = NSPoint(x: 0, y: point.y - (convert(NSPoint.zero, from: textView).y + textView.textContainerOrigin.y))
        let glyph = layout.glyphIndex(for: inText, in: container)
        let line = coordinator.line(at: layout.characterIndexForGlyph(at: glyph))
        // A click on a line's number comments on it.
        coordinator.comment(onLine: line)
    }
}
