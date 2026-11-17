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

/// The panel's content: a small orb while idle; while listening or
/// answering, the orb and what ABEL heard and says.
public struct AbelPanelView: View {
    public var display: AbelDisplay
    public var palette: AbelPalette

    public init(display: AbelDisplay, palette: AbelPalette) {
        self.display = display; self.palette = palette
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Orb(mode: display.mode, palette: palette)
            if display.isExpanded {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.secondary.color)
                    if !display.words.isEmpty {
                        Text(display.words)
                            .font(.system(size: 13))
                            .foregroundStyle(display.mode == .listening ? palette.text.color : palette.secondary.color)
                            .lineLimit(3)
                    }
                    if !display.answer.isEmpty {
                        Text(display.answer)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(palette.text.color)
                            .lineLimit(5)
                    }
                }
                .frame(width: 280, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(display.isExpanded ? 12 : 6)
        .background(
            shape.fill(palette.surface.color)
                .overlay(shape.strokeBorder(palette.border.color, lineWidth: 1))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("ABEL, \(title)")
    }

    /// A round orb while idle, a card while it listens or answers.
    var shape: AnyInsettableShape {
        display.isExpanded ? AnyInsettableShape(RoundedRectangle(cornerRadius: 16, style: .continuous)) : AnyInsettableShape(Circle())
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

/// Any shape that can be inset, so the orb's outline sits inside its edge.
public struct AnyInsettableShape: InsettableShape {
    private let path: @Sendable (CGRect) -> Path
    private let inset: @Sendable (CGFloat) -> AnyInsettableShape

    public init<S: InsettableShape>(_ shape: S) where S: Sendable {
        path = { shape.path(in: $0) }
        inset = { AnyInsettableShape(shape.inset(by: $0)) }
    }

    public func path(in rect: CGRect) -> Path { path(rect) }
    public func inset(by amount: CGFloat) -> AnyInsettableShape { inset(amount) }
}

/// The orb: still while idle, breathing while it listens.
struct Orb: View {
    var mode: AbelDisplay.Mode
    var palette: AbelPalette

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [palette.accent.color.opacity(0.95), palette.accent.color.opacity(0.55)],
                                     center: .topLeading, startRadius: 1, endRadius: 30))
            if mode == .listening {
                Circle().strokeBorder(palette.accent.color.opacity(0.5), lineWidth: 3).padding(-4)
            }
            if mode == .paused {
                Image(systemName: "pause.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(palette.surface.color)
            }
        }
        .frame(width: 30, height: 30)
        .opacity(mode == .paused ? 0.6 : 1)
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
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        NotificationCenter.default.addObserver(self, selector: #selector(moved), name: NSWindow.didMoveNotification, object: self)
    }

    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }

    /// The saved spot, or the top-right corner of the main screen.
    public func restoreOrigin(on screen: NSScreen? = NSScreen.main) {
        if let saved = defaults.string(forKey: Self.originKey) {
            let point = NSPointFromString(saved)
            if NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -20, dy: -20).contains(point) }) {
                setFrameOrigin(point)
                return
            }
        }
        guard let visible = screen?.visibleFrame else { return }
        setFrameOrigin(NSPoint(x: visible.maxX - frame.width - 24, y: visible.maxY - frame.height - 24))
    }

    /// Keeps the top-left corner where it was as the panel grows and shrinks.
    public func resize(to size: NSSize) {
        let top = frame.maxY
        setFrame(NSRect(x: frame.minX, y: top - size.height, width: size.width, height: size.height), display: true)
    }

    @objc private func moved() {
        defaults.set(NSStringFromPoint(frame.origin), forKey: Self.originKey)
    }
}

/// Draws the panel's content into a PNG without showing it: Settings'
/// preview, `Abel --snapshot`, and pull requests' screenshots. Needs no
/// Screen Recording permission.
@MainActor
public enum AbelSnapshot {
    public static func png(display: AbelDisplay, palette: AbelPalette, backdrop: Swatch? = nil) -> Data? {
        let content = AbelPanelView(display: display, palette: palette).padding(20)
            .background(backdrop.map { $0.color } ?? .clear)
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.appearance = NSAppearance(named: palette.isDark ? .darkAqua : .aqua)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
