import AppKit
import SwiftUI
import AbstractCore
@preconcurrency import SwiftTerm

/// The terminal's colours and type, resolved for one appearance.
///
/// Surfaces and text come from the app palette, so a terminal pane reads as
/// part of the window rather than a black box dropped into it. The 16 ANSI
/// colours are the theme's own `terminal*` roles (ABS-185): on a dark theme
/// bright enough to read on its canvas, on a light one deep enough to read on
/// white (so "yellow" is amber and "white" is a readable gray, the way light
/// editor themes do).
struct TerminalTheme {
    let isDark: Bool
    let background: NSColor
    let foreground: NSColor
    let cursor: NSColor
    let cursorText: NSColor
    let selection: NSColor
    let ansi: [SwiftTerm.Color]
    /// Identifies what was resolved, so re-applying an unchanged theme is free.
    let key: String

    static let font = BTFont.nsMono(12.5)

    static func resolve(for appearance: NSAppearance) -> TerminalTheme {
        let palette = ThemeState.shared.theme(for: appearance)
        let isDark = palette.isDark
        var background = NSColor.white, foreground = NSColor.black, accent = NSColor.systemBlue
        appearance.performAsCurrentDrawingAppearance {
            background = srgb(NSColor(SwiftUI.Color.btCanvas))
            foreground = srgb(NSColor(SwiftUI.Color.btText))
            accent = srgb(NSColor(SwiftUI.Color.btAccent))
        }
        let selection = blend(accent, over: background, amount: isDark ? 0.28 : 0.2)
        let hexes = PaletteRole.terminal.map { $0.swatch(in: palette).hex }
        return TerminalTheme(
            isDark: isDark, background: background, foreground: foreground, cursor: accent,
            cursorText: background, selection: selection,
            ansi: hexes.map(terminalColor),
            key: [palette.id, String(ThemeState.shared.currentGeneration), hex(background), hex(foreground), hex(accent)]
                .joined(separator: "-"))
    }

    // MARK: Colour plumbing

    private static func srgb(_ color: NSColor) -> NSColor {
        color.usingColorSpace(.sRGB) ?? color
    }

    private static func blend(_ top: NSColor, over bottom: NSColor, amount: CGFloat) -> NSColor {
        let a = srgb(top), b = srgb(bottom)
        return NSColor(srgbRed: b.redComponent + (a.redComponent - b.redComponent) * amount,
                       green: b.greenComponent + (a.greenComponent - b.greenComponent) * amount,
                       blue: b.blueComponent + (a.blueComponent - b.blueComponent) * amount,
                       alpha: 1)
    }

    /// SwiftTerm draws palette entries as device RGB; convert from sRGB so the
    /// colours look the same as the rest of the app on wide-gamut displays.
    private static func terminalColor(_ hex: UInt32) -> SwiftTerm.Color {
        let device = NSColor(hex: hex).usingColorSpace(.deviceRGB) ?? NSColor(hex: hex)
        func channel(_ value: CGFloat) -> UInt16 { UInt16((min(max(value, 0), 1) * 65535).rounded()) }
        return SwiftTerm.Color(red: channel(device.redComponent), green: channel(device.greenComponent),
                               blue: channel(device.blueComponent))
    }

    private static func hex(_ color: NSColor) -> String {
        let c = srgb(color)
        return String(format: "%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}
