import AppKit
@preconcurrency import SwiftTerm

/// The persistent AppKit side of a terminal pane: the terminal, inset on the
/// canvas colour, themed for whatever appearance it is shown under. SwiftUI
/// mounts and unmounts this view; it is never recreated while its shell lives.
final class TerminalContainerView: NSView {
    /// SwiftTerm keeps a scroller-wide strip (15pt) on the terminal's right,
    /// which already reads as the right inset.
    static let insets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 0)
    static let scrollback = 10_000

    let terminal: AbstractTerminalView
    weak var host: TerminalHost?
    /// Shown only while scrolled back into history; replaces SwiftTerm's
    /// always-on legacy scroller (a boxed track).
    private let scrollIndicator = ScrollIndicatorView()
    private var scrollUpdatePending = false
    /// True once the terminal has been laid out in a window at a real size.
    private(set) var hasUsableSize = false
    private var themeKey = ""

    init() {
        terminal = AbstractTerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 400))
        super.init(frame: CGRect(x: 0, y: 0, width: 652, height: 420))
        wantsLayer = true
        // The terminal keeps its size when the pane is squeezed; never let it
        // spill over neighbouring panes.
        clipsToBounds = true
        terminal.container = self
        terminal.caretViewTracksFocus = false
        terminal.font = TerminalTheme.font
        let engine = terminal.getTerminal()
        engine.changeHistorySize(Self.scrollback)
        // Keep the standard 256-colour cube; tools that pick from it expect it.
        engine.options.ansi256PaletteStrategy = .xterm
        engine.setCursorStyle(.steadyBar)
        // Detached, it still takes SwiftTerm's per-line updates, but cheaply.
        for case let scroller as NSScroller in terminal.subviews { scroller.removeFromSuperview() }
        addSubview(terminal)
        scrollIndicator.alphaValue = 0
        addSubview(scrollIndicator)
        applyTheme()
        NotificationCenter.default.addObserver(self, selector: #selector(systemColorsChanged),
                                               name: NSColor.systemColorsDidChangeNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Layout

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        layoutTerminal()
    }

    /// Sizes the terminal to the inset bounds. Collapsed or mid-transition
    /// sizes are ignored so the shell never sees a 2-column window and
    /// reflows its screen into garbage.
    func layoutTerminal() {
        let i = Self.insets
        let frame = NSRect(x: i.left, y: i.bottom,
                           width: bounds.width - i.left - i.right, height: bounds.height - i.top - i.bottom)
        guard window != nil, frame.width >= 120, frame.height >= 40 else { return }
        if terminal.frame != frame {
            terminal.frame = frame
            updateScrollIndicator(animated: false)
        }
        if !hasUsableSize {
            hasUsableSize = true
            host?.startIfReady()
        }
    }

    // MARK: Scroll indicator

    /// Called for every scrolled line of output, so coalesce to one update.
    func scrollChanged() {
        guard !scrollUpdatePending else { return }
        scrollUpdatePending = true
        DispatchQueue.main.async { [weak self] in
            self?.scrollUpdatePending = false
            self?.updateScrollIndicator(animated: true)
        }
    }

    private func updateScrollIndicator(animated: Bool) {
        let position = terminal.scrollPosition
        let visible = terminal.canScroll && position < 1
        // The strip SwiftTerm reserves for its scroller, at the right edge.
        let track = NSRect(x: terminal.frame.maxX - 9, y: terminal.frame.minY + 2, width: 5, height: terminal.frame.height - 4)
        let height = min(track.height, max(24, track.height * terminal.scrollThumbsize))
        scrollIndicator.frame = NSRect(x: track.minX, y: track.minY + (track.height - height) * (1 - position),
                                       width: track.width, height: height)
        let alpha: CGFloat = visible ? 1 : 0
        guard scrollIndicator.alphaValue != alpha else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = visible ? 0.12 : 0.35
                scrollIndicator.animator().alphaValue = alpha
            }
        } else {
            scrollIndicator.alphaValue = alpha
        }
    }

    /// A click in the inset around the text focuses the terminal too.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(terminal)
    }

    // MARK: Window

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, let window { host?.willHide(from: window) }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        applyTheme()
        layoutTerminal()
        host?.didShow(in: window)
    }

    // MARK: Theme

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    @objc private func systemColorsChanged(_ note: Notification) {
        applyTheme()
    }

    private func applyTheme() {
        let theme = TerminalTheme.resolve(for: effectiveAppearance)
        guard theme.key != themeKey else { return }
        themeKey = theme.key
        layer?.backgroundColor = theme.background.cgColor
        terminal.layer?.backgroundColor = theme.background.cgColor
        // Default colours first: the palette install derives from them.
        terminal.nativeForegroundColor = theme.foreground
        terminal.nativeBackgroundColor = theme.background
        terminal.caretAccent = theme.cursor
        terminal.caretTextColor = theme.cursorText
        terminal.selectedTextBackgroundColor = theme.selection
        terminal.installColors(theme.ansi)
        scrollIndicator.layer?.backgroundColor = theme.foreground.withAlphaComponent(theme.isDark ? 0.3 : 0.25).cgColor
    }
}

/// A slim rounded knob that never takes clicks.
private final class ScrollIndicatorView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 2.5
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
