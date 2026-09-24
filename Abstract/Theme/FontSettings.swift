import AppKit
import CoreText
import SwiftUI

/// A weight to set text in, as Settings › Appearance offers it.
enum FontWeightChoice: String, CaseIterable, Identifiable {
    case light, regular, medium, semibold, bold
    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    /// Steps from Regular.
    var steps: Int {
        switch self {
        case .light: -1
        case .regular: 0
        case .medium: 1
        case .semibold: 2
        case .bold: 3
        }
    }

    var nsWeight: NSFont.Weight {
        switch self {
        case .light: .light
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
    }
}

extension Font.Weight {
    private static let ladder: [Font.Weight] = [.ultraLight, .thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black]

    /// This weight moved `steps` along the scale, staying on it.
    func shifted(_ steps: Int) -> Font.Weight {
        guard steps != 0, let i = Self.ladder.firstIndex(of: self) else { return self }
        return Self.ladder[min(max(i + steps, 0), Self.ladder.count - 1)]
    }
}

/// The interface's typeface. Sizes throughout the app scale with `size`
/// from the 13 pt they're drawn for; weights move with `weight` from Regular.
struct UIFontChoice: Hashable {
    static let familyKey = "font.ui.family", sizeKey = "font.ui.size", weightKey = "font.ui.weight"
    static let system = "System"
    static let defaults = UIFontChoice(family: BTFont.interFamily, size: 13, weight: .regular)
    static let sizes: ClosedRange<Double> = 11...16

    var family: String
    var size: Double
    var weight: FontWeightChoice

    var scale: CGFloat { CGFloat(size / Self.defaults.size) }

    static var stored: UIFontChoice {
        let d = UserDefaults.standard
        return UIFontChoice(family: d.string(forKey: familyKey) ?? defaults.family,
                            size: (d.object(forKey: sizeKey) as? Double).map { min(max($0, sizes.lowerBound), sizes.upperBound) } ?? defaults.size,
                            weight: d.string(forKey: weightKey).flatMap(FontWeightChoice.init(rawValue:)) ?? defaults.weight)
    }

    func font(_ size: CGFloat, _ weight: Font.Weight) -> Font {
        let size = size * scale, weight = weight.shifted(self.weight.steps)
        return family == Self.system ? .system(size: size, weight: weight) : .custom(family, fixedSize: size).weight(weight)
    }
}

/// The code editor's typeface.
struct EditorFontChoice: Hashable {
    static let familyKey = "font.editor.family", sizeKey = "font.editor.size", weightKey = "font.editor.weight"
    static let ligaturesKey = "font.editor.ligatures", lineHeightKey = "font.editor.lineHeight"
    static let systemMono = "SF Mono"
    static let defaults = EditorFontChoice(family: BTFont.monoFamily, size: 12.5, weight: .regular, ligatures: true, lineHeight: 1.3)
    static let sizes: ClosedRange<Double> = 9...24
    static let lineHeights: ClosedRange<Double> = 1...2.4

    var family: String
    var size: Double
    var weight: FontWeightChoice
    var ligatures: Bool
    var lineHeight: Double

    static var stored: EditorFontChoice {
        let d = UserDefaults.standard
        return EditorFontChoice(
            family: d.string(forKey: familyKey) ?? defaults.family,
            size: (d.object(forKey: sizeKey) as? Double).map { min(max($0, sizes.lowerBound), sizes.upperBound) } ?? defaults.size,
            weight: d.string(forKey: weightKey).flatMap(FontWeightChoice.init(rawValue:)) ?? defaults.weight,
            ligatures: d.object(forKey: ligaturesKey) as? Bool ?? defaults.ligatures,
            lineHeight: (d.object(forKey: lineHeightKey) as? Double).map { min(max($0, lineHeights.lowerBound), lineHeights.upperBound) }
                ?? defaults.lineHeight)
    }

    /// The face nearest the chosen family and weight; with ligatures off,
    /// contextual alternates go too, since that's how most coding fonts
    /// (JetBrains Mono, Fira Code) draw theirs.
    var nsFont: NSFont {
        let size = CGFloat(self.size)
        var font: NSFont = if family == Self.systemMono {
            .monospacedSystemFont(ofSize: size, weight: weight.nsWeight)
        } else {
            NSFont(descriptor: NSFontDescriptor(fontAttributes: [
                .family: family, .traits: [NSFontDescriptor.TraitKey.weight: weight.nsWeight],
            ]), size: size) ?? BTFont.nsMono(size)
        }
        if !ligatures {
            let off = font.fontDescriptor.addingAttributes([.featureSettings: [
                [NSFontDescriptor.FeatureKey.typeIdentifier: kLigaturesType, .selectorIdentifier: kCommonLigaturesOffSelector],
                [NSFontDescriptor.FeatureKey.typeIdentifier: kContextualAlternatesType, .selectorIdentifier: kContextualAlternatesOffSelector],
            ]])
            font = NSFont(descriptor: off, size: size) ?? font
        }
        return font
    }

    var paragraph: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = CGFloat(lineHeight)
        return p
    }

    /// The gutter's numbers: the same face, a size down.
    var gutterFont: NSFont {
        NSFontManager.shared.convert(nsFont, toSize: max(CGFloat(size) - 1, 8))
    }
}

/// Installed font families to choose from.
enum FontFamilies {
    static let all: [String] = NSFontManager.shared.availableFontFamilies
        .filter { !$0.hasPrefix(".") }
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

    /// Families whose faces are fixed-pitch.
    static let monospaced: [String] = all.filter { family in
        guard let member = NSFontManager.shared.availableMembers(ofFontFamily: family)?.first, member.count > 3,
              let traits = (member[3] as? NSNumber)?.uintValue else { return false }
        return NSFontTraitMask(rawValue: traits).contains(.fixedPitchFontMask)
    }
}
