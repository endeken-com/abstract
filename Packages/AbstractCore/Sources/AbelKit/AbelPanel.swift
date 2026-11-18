import AbstractCore
import AppKit
import SwiftUI

/// ABEL's colours, taken from the theme Abstract is drawn in, so the orb
/// looks like part of the app over any other.
public struct AbelPalette: Sendable, Equatable {
    public var surface: Swatch
    public var border: Swatch
    public var text: Swatch
    public var secondary: Swatch
    public var accent: Swatch
    public var isDark: Bool

    public init(theme: Theme) {
        surface = theme.swatch(.surfaceRaised)
        border = theme.swatch(.borderStrong)
        text = theme.swatch(.text)
        secondary = theme.swatch(.textSecondary)
        accent = theme.swatch(.accent)
        isDark = theme.isDark
    }

    /// Graphite, Paper and Ink, from Abstract's bundled theme plugins.
    public static func themes(in resources: URL?) -> ThemeCatalog {
        ThemeCatalog(listed: [], fallbacks: ThemeCatalog.themes(inFolders: PluginManager.bundledFolders(in: resources)))
    }

    /// The Abstract.app ABEL sits in, from inside `Contents/Library/LoginItems`.
    public static func containingAppResources(of bundle: Bundle = .main) -> URL? {
        let app = bundle.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let resources = app.appendingPathComponent("Contents/Resources")
        return FileManager.default.fileExists(atPath: resources.appendingPathComponent("Plugins").path) ? resources : nil
    }
}

extension Swatch {
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
}

/// What the floating widget shows and what its buttons do (ABS-203,
/// redrawn): ABEL itself, a pill of actions while you hover it, and what it
/// heard and says while it listens or answers.
@MainActor
@Observable
public final class AbelWidgetModel {
    public var display = AbelDisplay()
    public var palette: AbelPalette
    /// The pointer is over the widget: the actions show.
    public var hovered = false
    /// Chats waiting on you, for the bell's badge.
    public var needsYou = 0
    /// A fixed frame instead of the clock: snapshots.
    public var frozenTick: Int?

    @ObservationIgnored public var onOpen: () -> Void = {}
    @ObservationIgnored public var onNewChat: () -> Void = {}
    @ObservationIgnored public var onTalk: () -> Void = {}
    @ObservationIgnored public var onNeedsYou: () -> Void = {}

    public init(palette: AbelPalette) { self.palette = palette }

    var pose: AbelSprite.Pose {
        switch display.mode {
        case .idle: .idle
        case .listening: .listening
        case .thinking: .thinking
        case .answering: .answering
        case .paused: .paused
        }
    }
}

/// The widget: ABEL, standing on its shadow; below it, the actions while
/// hovered, or a bubble with what it heard and says.
public struct AbelWidgetView: View {
    @Bindable var model: AbelWidgetModel

    public init(model: AbelWidgetModel) { self.model = model }

    public static let mascotScale: CGFloat = 4

    public var body: some View {
        VStack(spacing: 6) {
            mascot
            if model.display.isExpanded {
                AbelBubble(display: model.display, palette: model.palette, offscreen: model.frozenTick != nil)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            } else if model.hovered {
                AbelActionPill(model: model)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
            }
        }
        .padding(10)
        .animation(.snappy(duration: 0.2), value: model.hovered)
        .animation(.snappy(duration: 0.2), value: model.display.isExpanded)
        .environment(\.colorScheme, model.palette.isDark ? .dark : .light)
    }

    private var mascot: some View {
        let size = CGFloat(AbelSprite.width) * Self.mascotScale
        return ZStack(alignment: .bottom) {
            Ellipse()
                .fill(.black.opacity(0.28))
                .frame(width: size * 0.55, height: 7)
                .blur(radius: 2.5)
                .offset(y: -1)
            Group {
                if let tick = model.frozenTick {
                    sprite(tick)
                } else {
                    TimelineView(.periodic(from: .now, by: 1 / AbelSprite.fps)) { context in
                        sprite(AbelSprite.tick(at: context.date))
                    }
                }
            }
            .frame(width: size, height: size)
            // A hop, not a zoom: pixel art stays crisp only at whole sizes.
            .offset(y: model.hovered && !model.display.isExpanded ? -4 : 0)
            .animation(.spring(duration: 0.25, bounce: 0.4), value: model.hovered)
        }
        .frame(width: size, height: size + 4)
        .overlay { MascotHit(onClick: { model.onOpen() }) }
        .help("ABEL: click to open Abstract, drag to move")
        .accessibilityElement()
        .accessibilityLabel("ABEL")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.onOpen() }
    }

    private func sprite(_ tick: Int) -> some View {
        Group {
            if let image = AbelSprite.image(model.pose, tick: tick) {
                Image(decorative: image, scale: 1).interpolation(.none).resizable()
            }
        }
    }
}

/// Glass, where macOS has it; a material before. Snapshots, drawn off
/// screen where neither renders, get the theme's surface instead.
extension View {
    @ViewBuilder
    func abelGlass(_ shape: some Shape, palette: AbelPalette, offscreen: Bool) -> some View {
        if offscreen {
            self.background(shape.fill(palette.surface.color.opacity(0.92)))
                .overlay(shape.stroke(palette.border.color, lineWidth: 1))
        } else if #available(macOS 26, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
                .overlay(shape.stroke(.white.opacity(0.12), lineWidth: 0.5))
        }
    }
}

/// The actions under ABEL while you hover it: a new chat, talking, and
/// what needs you.
struct AbelActionPill: View {
    @Bindable var model: AbelWidgetModel

    var body: some View {
        HStack(spacing: 2) {
            action("square.and.pencil", help: "New chat in Abstract", model.onNewChat)
            divider
            action(model.display.mode == .listening ? "waveform.circle.fill" : "waveform",
                   help: model.display.mode == .listening ? "Stop listening" : "Talk to ABEL", model.onTalk)
            divider
            action("bell", help: model.needsYou == 0 ? "Nothing needs you" : "Open what needs you", model.onNeedsYou)
                .overlay(alignment: .topTrailing) {
                    if model.needsYou > 0 {
                        Text(model.needsYou > 9 ? "9+" : "\(model.needsYou)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 15, minHeight: 15)
                            .background(Capsule().fill(Color(red: 0.98, green: 0.74, blue: 0.2)))
                            .offset(x: 1, y: 1)
                            .accessibilityLabel("\(model.needsYou) need you")
                    }
                }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .abelGlass(Capsule(), palette: model.palette, offscreen: model.frozenTick != nil)
    }

    private var divider: some View {
        Rectangle().fill(model.palette.text.color.opacity(0.18)).frame(width: 1, height: 18)
    }

    private func action(_ symbol: String, help: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(model.palette.text.color)
                .frame(width: 38, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// What ABEL heard and says, in a bubble under it.
struct AbelBubble: View {
    var display: AbelDisplay
    var palette: AbelPalette
    var offscreen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.secondary.color)
            if !display.words.isEmpty {
                Text(display.words)
                    .font(.system(size: 13))
                    .foregroundStyle(display.mode == .listening ? palette.text.color : palette.secondary.color)
                    .lineLimit(3)
            }
            if !display.detail.isEmpty {
                Text(display.detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(palette.text.color)
                    // Never cut: scripts longer than this are refused before they're shown.
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(palette.text.color.opacity(0.08)))
            }
            if !display.answer.isEmpty {
                Text(display.answer)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.text.color)
                    .lineLimit(5)
            }
        }
        .frame(width: display.detail.isEmpty ? 260 : 540, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(12)
        .abelGlass(RoundedRectangle(cornerRadius: 18, style: .continuous), palette: palette, offscreen: offscreen)
        .accessibilityElement(children: .combine)
    }

    var title: String {
        switch display.mode {
        case .idle: "ABEL"
        case .listening: "Listening…"
        case .thinking: "Working on it…"
        case .answering: "ABEL"
        case .paused: "Paused"
        }
    }
}

/// Over ABEL: a click opens Abstract; a drag moves the widget. The first
/// click counts even though the panel is never key.
struct MascotHit: NSViewRepresentable {
    var onClick: () -> Void

    func makeNSView(context: Context) -> HitView {
        let view = HitView()
        view.onClick = onClick
        return view
    }

    func updateNSView(_ view: HitView, context: Context) { view.onClick = onClick }

    final class HitView: NSView {
        var onClick: () -> Void = {}
        private var start: NSPoint?
        private var dragged = false

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }

        override func mouseDown(with event: NSEvent) {
            start = event.locationInWindow
            dragged = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard !dragged, let start else { return }
            let moved = hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y)
            guard moved > 3 else { return }
            dragged = true
            window?.performDrag(with: event)
        }

        override func mouseUp(with event: NSEvent) {
            defer { start = nil }
            if !dragged { onClick() }
        }
    }
}

/// Hosts the widget: takes the first click, and follows the pointer
/// while ABEL is never the active app.
public final class AbelWidgetHost: NSHostingView<AbelWidgetView> {
    private let model: AbelWidgetModel
    private var leave: Task<Void, Never>?

    public init(model: AbelWidgetModel) {
        self.model = model
        super.init(rootView: AbelWidgetView(model: model))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    @MainActor @preconcurrency required init(rootView: AbelWidgetView) { fatalError() }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self && area.userInfo?["abel"] != nil { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: ["abel": true]))
    }

    public override func mouseEntered(with event: NSEvent) {
        leave?.cancel()
        model.hovered = true
    }

    public override func mouseExited(with event: NSEvent) {
        // A moment's grace, so the pointer can cross a gap to the pill.
        leave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.model.hovered = false
        }
    }
}

/// The floating panel: over every app, on every Space and over full-screen
/// apps, and never the key window, so it never takes focus from the app
/// you're in (ABS-202 §7). Drag it anywhere; it remembers where.
public final class AbelPanel: NSPanel {
    public static let originKey = "orbOrigin"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init(contentRect: NSRect(x: 0, y: 0, width: 44, height: 44),
                   styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // ABEL handles dragging itself, so a click can mean "open Abstract".
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        backgroundColor = .clear
        isOpaque = false
        // ABEL draws its own shadow on the ground.
        hasShadow = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        NotificationCenter.default.addObserver(self, selector: #selector(moved), name: NSWindow.didMoveNotification, object: self)
    }

    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }

    /// The saved spot (the top center of the widget), or near the
    /// top-right corner of the main screen.
    public func restoreOrigin(on screen: NSScreen? = NSScreen.main) {
        if let saved = defaults.string(forKey: Self.originKey) {
            let anchor = NSPointFromString(saved)
            if NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -20, dy: -20).contains(anchor) }) {
                setFrameOrigin(NSPoint(x: anchor.x - frame.width / 2, y: anchor.y - frame.height))
                return
            }
        }
        guard let visible = screen?.visibleFrame else { return }
        setFrameOrigin(NSPoint(x: visible.maxX - frame.width - 24, y: visible.maxY - frame.height - 24))
    }

    /// Keeps ABEL where it stands (the top center) as the widget grows and
    /// shrinks around it.
    public func resize(to size: NSSize) {
        let top = frame.maxY, center = frame.midX
        setFrame(NSRect(x: (center - size.width / 2).rounded(), y: top - size.height, width: size.width, height: size.height),
                 display: true)
    }

    @objc private func moved() {
        defaults.set(NSStringFromPoint(NSPoint(x: frame.midX, y: frame.maxY)), forKey: Self.originKey)
    }
}

/// Draws the panel's content into a PNG without showing it: Settings'
/// preview, `Abel --snapshot`, and pull requests' screenshots. Needs no
/// Screen Recording permission.
@MainActor
public enum AbelSnapshot {
    public static func png(display: AbelDisplay, palette: AbelPalette, backdrop: Swatch? = nil,
                           hovered: Bool = false, needsYou: Int = 0, tick: Int = 4) -> Data? {
        let model = AbelWidgetModel(palette: palette)
        model.display = display
        model.hovered = hovered
        model.needsYou = needsYou
        model.frozenTick = tick
        let content = AbelWidgetView(model: model).padding(10).background(backdrop.map { $0.color } ?? .clear)
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.appearance = NSAppearance(named: palette.isDark ? .darkAqua : .aqua)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
