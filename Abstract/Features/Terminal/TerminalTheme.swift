import AppKit
import SwiftUI
@preconcurrency import SwiftTerm

/// The terminal's colours and type, resolved for one appearance.
///
/// Surfaces and text come from the app palette, so a terminal pane reads as
/// part of the window rather than a black box dropped into it. The 16 ANSI
/// colours are tuned per theme: on Graphite they are bright enough to read
/// on #1E1E21, on Paper they are deep enough to read on white (so "yellow"
/// is amber and "white" is a readable gray, the way light editor themes do).
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
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        var background = NSColor.white, foreground = NSColor.black, accent = NSColor.systemBlue
        appearance.performAsCurrentDrawingAppearance {
            background = srgb(NSColor(SwiftUI.Color.btCanvas))
            foreground = srgb(NSColor(SwiftUI.Color.btText))
            accent = srgb(NSColor(SwiftUI.Color.btAccent))
        }
        let selection = blend(accent, over: background, amount: isDark ? 0.28 : 0.2)
        let hexes = isDark ? graphite : paper
        return TerminalTheme(
            isDark: isDark, background: background, foreground: foreground, cursor: accent,
            cursorText: background, selection: selection,
            ansi: hexes.map(terminalColor),
            key: [isDark ? "dark" : "light", hex(background), hex(foreground), hex(accent)].joined(separator: "-"))
    }

    // MARK: Palettes (black, red, green, yellow, blue, magenta, cyan, white, then bright)

    /// On Graphite (#1E1E21). Normal colours clear 5:1; bright black is the
    /// deliberate dim one (autosuggestions, comments).
    private static let graphite: [UInt32] = [
        0x3E3E46, 0xEF6461, 0x4CC38A, 0xE5A33A, 0x5B9CF6, 0xC080E8, 0x4EBFC7, 0xC8C8CE,
        0x74747E, 0xFF8A86, 0x72DBA6, 0xF5C26B, 0x88B9FF, 0xD8A8F8, 0x7DD8DE, 0xF4F4F6,
    ]

    /// On Paper (#FFFFFF). Normal colours clear 4.8:1. Bold text is drawn with
    /// the bright set, so on white "bright" means deeper, not lighter.
    private static let paper: [UInt32] = [
        0x1D1D1F, 0xCF222E, 0x1A7F37, 0x9A6700, 0x0969DA, 0x8250DF, 0x1B7C83, 0x6E6E78,
        0x8E8E98, 0xB31D28, 0x116329, 0x7D4E00, 0x0550AE, 0x6E40C9, 0x136A73, 0x7A7A84,
    ]

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
