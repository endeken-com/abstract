import SwiftUI

/// Type scale. macOS UI runs at 13pt; agent prose gets a larger size and
/// looser leading because it is read, not scanned.
extension Font {
    static var btProse: Font { BTFont.ui(15) }
    static var btBody: Font { BTFont.ui(13) }
    static var btBodyMedium: Font { BTFont.ui(13, .medium) }
    static var btCallout: Font { BTFont.ui(12) }
    /// What you type in fields and editors.
    static var btInput: Font { BTFont.ui(13) }
    static var btInputCompact: Font { BTFont.ui(12) }
    static var btCaption: Font { BTFont.ui(11.5) }
    static var btCaptionMedium: Font { BTFont.ui(11.5, .medium) }
    static var btSectionLabel: Font { BTFont.ui(11, .semibold) }
    static var btTitle: Font { BTFont.ui(20, .semibold) }
    static var btHeadline: Font { BTFont.ui(15, .semibold) }
    static let btMono = BTFont.mono(12)
    static let btMonoSmall = BTFont.mono(11)
    /// Tool activity: quieter than prose, still proportional so it reads as text.
    static var btTool: Font { BTFont.ui(13) }
    static var btToolMedium: Font { BTFont.ui(13, .medium) }

    // The chat's own, a step lighter (see `BTFont.chat`).
    static let btChatProse = BTFont.chat(15)
    static let btChatBody = BTFont.chat(13)
    static let btChatBodyMedium = BTFont.chat(13, .medium)
    static let btChatCallout = BTFont.chat(12)
    static let btChatInput = BTFont.chat(13)
    static let btChatInputCompact = BTFont.chat(12)
    static let btChatCaption = BTFont.chat(11.5)
    static let btChatCaptionMedium = BTFont.chat(11.5, .medium)
    static let btChatMono = BTFont.chatMono(12)
    static let btChatMonoSmall = BTFont.chatMono(11)
    static let btChatTool = BTFont.chat(13)
    static let btChatToolMedium = BTFont.chat(13, .medium)
}

/// The agent's prose, set by the reader under Settings › General › Chat.
enum ChatFont: String, CaseIterable, Identifiable {
    case inter, sans, serif
    var id: String { rawValue }
    var title: String {
        switch self {
        case .inter: "Inter"
        case .sans: "San Francisco"
        case .serif: "New York"
        }
    }
}

enum ChatTextSize: String, CaseIterable, Identifiable {
    case small, medium, large, larger
    var id: String { rawValue }
    var title: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        case .larger: "Extra Large"
        }
    }
    var points: CGFloat {
        switch self {
        case .small: 14
        case .medium: 15
        case .large: 16
        case .larger: 17
        }
    }
}

/// Size and leading for prose: about 1.6 line height, which long answers need.
struct ProseStyle: Equatable {
    var font: ChatFont = .inter
    var size: ChatTextSize = .medium

    var points: CGFloat { size.points }
    var body: Font { font(size: points) }

    func font(size: CGFloat) -> Font {
        switch font {
        case .inter: BTFont.chat(size)
        case .sans: .system(size: size, weight: .light)
        case .serif: .system(size: size, weight: .light, design: .serif)
        }
    }
    var lineSpacing: CGFloat { (points * (font == .serif ? 0.45 : 0.42)).rounded() }
}

private struct ProseStyleKey: EnvironmentKey {
    static let defaultValue = ProseStyle()
}

extension EnvironmentValues {
    var proseStyle: ProseStyle {
        get { self[ProseStyleKey.self] }
        set { self[ProseStyleKey.self] = newValue }
    }
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
