import SwiftUI

/// Type scale. macOS UI runs at 13pt; agent prose gets a larger size and
/// looser leading because it is read, not scanned.
extension Font {
    static let btProse = Font.system(size: 14, weight: .regular)
    static let btBody = Font.system(size: 13)
    static let btBodyMedium = Font.system(size: 13, weight: .medium)
    static let btCallout = Font.system(size: 12)
    static let btCaption = Font.system(size: 11.5)
    static let btCaptionMedium = Font.system(size: 11.5, weight: .medium)
    static let btSectionLabel = Font.system(size: 11, weight: .semibold)
    static let btTitle = Font.system(size: 20, weight: .semibold)
    static let btHeadline = Font.system(size: 15, weight: .semibold)
    static let btMono = Font.system(size: 12, design: .monospaced)
    static let btMonoSmall = Font.system(size: 11, design: .monospaced)
}

/// Spacing on a 4pt grid, named by intent.
enum Space {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    /// Readable line length for agent prose.
    static let readingWidth: CGFloat = 720
}

enum Radius {
    static let sm: CGFloat = 6
    static let md: CGFloat = 8
    static let lg: CGFloat = 12
    static let xl: CGFloat = 16
}
