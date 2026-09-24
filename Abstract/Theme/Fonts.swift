import SwiftUI
import AppKit
import CoreText

/// Abstract's two typefaces, bundled so every Mac reads the same.
///
/// Inter for the interface and prose: drawn for screens, with a tall
/// x-height, open shapes and distinct I/l/1, and optical sizes that switch
/// to its text design at reading sizes. JetBrains Mono for code, diffs and
/// the terminal: a tall x-height and clear 0/O, which is what keeps long
/// stretches of code from tiring the eye. Both ship under the SIL OFL.
extension Font.Weight {
    /// The next weight down.
    var lighter: Font.Weight {
        switch self {
        case .black: .heavy
        case .heavy: .bold
        case .bold: .semibold
        case .semibold: .medium
        case .medium: .regular
        case .regular: .light
        case .light: .thin
        default: .ultraLight
        }
    }
}

enum BTFont {
    static let interFamily = "Inter Variable"
    static let monoFamily = "JetBrains Mono"

    /// The interface's typeface as set in Settings › Appearance. The window
    /// redraws from scratch when it changes (see `RootView`).
    static var uiChoice = UIFontChoice.stored

    /// Makes the bundled faces available to this process. Call once, before
    /// the first view draws.
    static func registerBundled() {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil), !urls.isEmpty else { return }
        // Already-installed copies make registration report duplicates; harmless.
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
    }

    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        uiChoice.font(size, weight)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(monoFamily, fixedSize: size).weight(weight)
    }

    /// The chat's text, drawn one step lighter than named: read all day,
    /// Inter is calmer that way (regular draws light, medium regular…). The
    /// chat keeps its own font settings; the interface font leaves it be.
    static func chat(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(interFamily, fixedSize: size).weight(weight.lighter)
    }

    static func chatMono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(monoFamily, fixedSize: size).weight(weight.lighter)
    }

    /// For AppKit text measured or drawn by hand (diff columns, the file
    /// reader, the terminal).
    static func nsMono(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        // One step lighter, like `ui`; there is no lighter face than Regular.
        let face = switch weight {
        case .semibold: "JetBrainsMono-Medium"
        case .bold: "JetBrainsMono-SemiBold"
        case .heavy, .black: "JetBrainsMono-Bold"
        default: "JetBrainsMono-Regular"
        }
        return NSFont(name: face, size: size) ?? .monospacedSystemFont(ofSize: size, weight: weight)
    }
}
