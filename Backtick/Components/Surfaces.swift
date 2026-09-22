import SwiftUI

extension View {
    /// A quiet filled surface. Kept for the few places that need one (a code
    /// area, a floating panel); Backtick's layout is otherwise unboxed and
    /// nothing boxed should ever sit inside one of these.
    func btCard(radius: CGFloat = Radius.lg, fill: Color = .btSurface) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    /// A floating panel (palette, toast): raised fill, hairline, neutral drop
    /// shadow for separation. No coloured shadow, no glow.
    func btRaised(radius: CGFloat = Radius.xl) -> some View {
        background(Color.btSurfaceRaised, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.btBorderStrong, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.14), radius: 14, y: 6)
    }

    /// A thin vertical rule on the leading edge, used instead of a box to set
    /// a block apart.
    func btLeadingRule(_ color: Color = .btBorderStrong, width: CGFloat = 2) -> some View {
        padding(.leading, Space.md)
            .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: width) }
    }
}

/// A keyboard shortcut as plain text, the way macOS menus show it.
struct KeyHint: View {
    let keys: [String]

    init(_ keys: String...) { self.keys = keys }

    var body: some View {
        Text(keys.joined())
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Color.btTextTertiary)
            .monospacedDigit()
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    var message: String? = nil
    var action: (label: String, run: () -> Void)? = nil

    var body: some View {
        VStack(spacing: Space.md) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Color.btTextTertiary)
                .padding(.bottom, Space.xs)
            Text(title).font(.btHeadline).foregroundStyle(Color.btText)
            if let message {
                Text(message)
                    .font(.btBody)
                    .foregroundStyle(Color.btTextSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            if let action {
                Button(action.label, action: action.run).buttonStyle(.btPrimary).padding(.top, Space.xs)
            }
        }
        .padding(Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Section header used in sidebars and settings.
struct SectionLabel: View {
    let title: String
    var trailing: AnyView? = nil

    var body: some View {
        HStack {
            Text(title)
                .font(.btSectionLabel)
                .foregroundStyle(Color.btTextTertiary)
            Spacer()
            trailing
        }
    }
}

/// A 0.5pt hairline, the main structural device in place of boxes.
struct Hairline: View {
    var body: some View { Rectangle().fill(Color.btBorder).frame(height: 0.5) }
}
