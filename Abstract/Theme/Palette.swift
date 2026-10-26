import AbstractCore
import AppKit
import Observation
import SwiftUI
import Synchronization

extension ThemeChoice {
    var title: String {
        switch self {
        case .system: "Match System"
        case .graphite: "Graphite"
        case .paper: "Paper"
        case .ink: "Ink"
        }
    }

    var colorScheme: ColorScheme? {
        isDark.map { $0 ? .dark : .light }
    }
}

/// The theme picked in Settings, readable from any thread: AppKit resolves
/// dynamic colours on whatever thread draws. SwiftUI views that read a
/// colour observe it, so they redraw when it changes even when the
/// appearance doesn't (Graphite and Ink are both dark).
nonisolated final class ThemeState: Observable, Sendable {
    static let shared = ThemeState()

    private let registrar = ObservationRegistrar()
    private let stored = Mutex(ThemeChoice(rawValue: UserDefaults.standard.string(forKey: "theme") ?? "") ?? .graphite)

    var choice: ThemeChoice {
        get {
            registrar.access(self, keyPath: \.choice)
            return stored.withLock { $0 }
        }
        set {
            guard newValue != current else { return }
            registrar.withMutation(of: self, keyPath: \.choice) { stored.withLock { $0 = newValue } }
        }
    }

    /// Posted when the choice changes, for AppKit views that hold resolved colours.
    static let didChange = Notification.Name("ThemeState.didChange")

    /// Takes a new choice: SwiftUI views follow by themselves; AppKit views
    /// redraw, since Graphite to Ink leaves the appearance as it was.
    @MainActor static func apply(_ choice: ThemeChoice) {
        guard choice != shared.current else { return }
        shared.choice = choice
        NotificationCenter.default.post(name: didChange, object: nil)
        for window in NSApp.windows {
            guard let root = window.contentView?.superview ?? window.contentView else { continue }
            var views = [root]
            while let view = views.popLast() {
                view.needsDisplay = true
                views.append(contentsOf: view.subviews)
            }
        }
    }

    /// The choice, without observing it: for drawing.
    var current: ThemeChoice { stored.withLock { $0 } }

    /// The palette an appearance draws in under the current choice.
    func theme(for appearance: NSAppearance) -> Theme {
        let look = Self.look(of: appearance)
        return current.theme(dark: look.dark, increasedContrast: look.increasedContrast)
    }

    static func look(of appearance: NSAppearance) -> (dark: Bool, increasedContrast: Bool) {
        let names: [NSAppearance.Name] = [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]
        let match = appearance.bestMatch(from: names)
        return (match == .darkAqua || match == .accessibilityHighContrastDarkAqua,
                match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua)
    }
}

/// Semantic colours. Each resolves per appearance and per the theme picked,
/// so a view written once reads well in Graphite (dark gray), Paper (white)
/// and Ink (black) alike. The values live in `PaletteRole`.
nonisolated extension Color {
    // Surfaces, back to front.
    static var btCanvas: Color { themed(.canvas) }
    static var btSidebar: Color { themed(.sidebar) }
    static var btSurface: Color { themed(.surface) }
    static var btSurfaceRaised: Color { themed(.surfaceRaised) }
    static var btCode: Color { themed(.code) }
    static var btInset: Color { themed(.inset) }

    // Interaction washes.
    static var btHover: Color { themed(.hover) }
    static var btSelection: Color { themed(.selection) }

    // Text inputs: a steady fill; only the border answers focus.
    static var btField: Color { themed(.field) }
    static var btFieldBorder: Color { themed(.fieldBorder) }
    static var btFieldBorderFocused: Color { themed(.fieldBorderFocused) }

    // Hairlines.
    static var btBorder: Color { themed(.border) }
    static var btBorderStrong: Color { themed(.borderStrong) }

    // Text.
    static var btText: Color { themed(.text) }
    /// Long-form prose: a touch softer than `btText` so paragraphs don't glare.
    static var btProse: Color { themed(.prose) }
    static var btTextSecondary: Color { themed(.textSecondary) }
    static var btTextTertiary: Color { themed(.textTertiary) }

    // Usage chart series: Claude's clay, a quiet slate for Codex, a muted teal for OpenCode.
    static var btUsageClaude: Color { themed(.usageClaude) }
    static var btUsageCodex: Color { themed(.usageCodex) }
    static var btUsageOpenCode: Color { themed(.usageOpenCode) }
    static var btUsageMuse: Color { themed(.usageMuse) }

    // Pull request states, as GitHub colours them (only the title's menu uses these, as a wash).
    static var btPullRequestOpen: Color { themed(.pullRequestOpen) }
    static var btPullRequestDraft: Color { themed(.pullRequestDraft) }
    static var btPullRequestMerged: Color { themed(.pullRequestMerged) }
    static var btPullRequestClosed: Color { themed(.pullRequestClosed) }
    /// Text on those colours' washes: the same hue, readable on the canvas.
    static var btPullRequestOpenInk: Color { themed(.pullRequestOpenInk) }
    static var btPullRequestDraftInk: Color { themed(.pullRequestDraftInk) }
    static var btPullRequestMergedInk: Color { themed(.pullRequestMergedInk) }
    static var btPullRequestClosedInk: Color { themed(.pullRequestClosedInk) }

    // Syntax: One Dark on Graphite, One Light on Paper, as Paseo colours code
    // (see `SyntaxStyle`), and a brightened One Dark on Ink.
    static var btSyntaxKeyword: Color { themed(.syntaxKeyword) }
    static var btSyntaxString: Color { themed(.syntaxString) }
    static var btSyntaxLiteral: Color { themed(.syntaxLiteral) }
    static var btSyntaxType: Color { themed(.syntaxType) }
    static var btSyntaxFunction: Color { themed(.syntaxFunction) }
    static var btSyntaxComment: Color { themed(.syntaxComment) }
    static var btSyntaxOperator: Color { themed(.syntaxOperator) }
    static var btSyntaxTag: Color { themed(.syntaxTag) }
    static var btSyntaxPlain: Color { themed(.syntaxPlain) }

    /// The single emphasis colour: near-black on Paper, near-white on
    /// Graphite, white on Ink. Primary buttons, the working spinner, focus,
    /// selection marks.
    static var btAccent: Color { themed(.accent) }
    /// Text and icons drawn on `btAccent`.
    static var btOnAccent: Color { themed(.onAccent) }

    // Meaning. Tuned per theme instead of raw system colours, so diffs and
    // status stay legible on white, gray and black.
    static var btAdded: Color { themed(.added) }
    static var btRemoved: Color { themed(.removed) }
    /// Caution, as a strong neutral: warnings carry an icon and plain words,
    /// never orange.
    static var btWarning: Color { themed(.warning) }
    /// "Needs you": the strongest neutral, not a colour. Abstract uses no
    /// orange or blue; emphasis comes from contrast and weight.
    static var btAttention: Color { themed(.attention) }
    static var btAddedWash: Color { themed(.addedWash) }
    static var btRemovedWash: Color { themed(.removedWash) }
    /// Every match of the words being found, and, brighter, the one you're on:
    /// find's yellow, the one place it's used, because that's how a Mac shows it.
    static var btFindMatch: Color { themed(.findMatch) }
    static var btFindCurrent: Color { themed(.findCurrent) }

    /// A colour as one theme draws it, whatever is picked: the settings previews.
    static func bt(_ role: PaletteRole, in theme: Theme) -> Color {
        Color(nsColor: NSColor(role.swatch(in: theme)))
    }

    /// Reading the choice here is what makes a view observe it. Each choice has
    /// its own copy of every colour, so a change hands SwiftUI a different
    /// value to resolve; all copies resolve from the current choice, so a
    /// colour AppKit already holds is right the next time it draws.
    private static func themed(_ role: PaletteRole) -> Color {
        ThemedColors.all[ThemeState.shared.choice]![role]!
    }
}

nonisolated private enum ThemedColors {
    static let all: [ThemeChoice: [PaletteRole: Color]] = Dictionary(uniqueKeysWithValues: ThemeChoice.allCases.map { choice in
        (choice, Dictionary(uniqueKeysWithValues: PaletteRole.allCases.map { ($0, dynamic($0)) }))
    })

    private static func dynamic(_ role: PaletteRole) -> Color {
        Color(nsColor: NSColor(name: nil) { @Sendable appearance in
            let look = ThemeState.look(of: appearance)
            let choice = ThemeState.shared.current
            let theme = choice.theme(dark: look.dark, increasedContrast: look.increasedContrast)
            return NSColor(role.swatch(in: theme, strongerBorders: choice.strongerBorders(dark: look.dark, increasedContrast: look.increasedContrast)))
        })
    }
}

nonisolated extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    convenience init(_ swatch: Swatch) {
        self.init(hex: swatch.hex, alpha: swatch.alpha)
    }
}
