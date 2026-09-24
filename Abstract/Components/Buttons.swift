import SwiftUI

/// Abstract's button styles. Each reacts to hover and press, and dims when
/// disabled, so every clickable thing feels the same.
struct BTButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost, danger }
    enum Size { case small, regular, large }

    var kind: Kind = .secondary
    var size: Size = .regular

    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, kind: kind, size: size)
    }

    private struct StyledButton: View {
        let configuration: ButtonStyleConfiguration
        let kind: Kind
        let size: Size
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(size == .small ? .btCallout.weight(.medium) : .btBodyMedium)
                .lineLimit(1)
                .padding(.horizontal, size == .small ? 9 : size == .large ? 16 : 12)
                .frame(height: size == .small ? 24 : size == .large ? 34 : 28)
                .foregroundStyle(foreground)
                // Fills only, never outlines: a stroke around every button is
                // exactly the boxed look Abstract avoids.
                .background(background, in: RoundedRectangle(cornerRadius: size == .small ? 6 : 8, style: .continuous))
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(.snappy(duration: 0.14), value: hovering)
                .animation(.snappy(duration: 0.1), value: configuration.isPressed)
        }

        private var foreground: Color {
            switch kind {
            case .primary: .btOnAccent
            case .secondary: .btText
            case .ghost: hovering ? .btText : .btTextSecondary
            case .danger: .btRemoved
            }
        }

        private var background: AnyShapeStyle {
            switch kind {
            case .primary:
                AnyShapeStyle(Color.btAccent.opacity(configuration.isPressed ? 0.85 : hovering ? 0.92 : 1))
            case .secondary:
                AnyShapeStyle(configuration.isPressed ? Color.btSelection : hovering ? Color.btSelection.opacity(0.8) : Color.btHover)
            case .ghost:
                AnyShapeStyle(hovering || configuration.isPressed ? Color.btHover : .clear)
            case .danger:
                AnyShapeStyle(hovering ? Color.btRemovedWash : .clear)
            }
        }
    }
}

extension ButtonStyle where Self == BTButtonStyle {
    static var btPrimary: BTButtonStyle { BTButtonStyle(kind: .primary) }
    static var btSecondary: BTButtonStyle { BTButtonStyle(kind: .secondary) }
    static var btGhost: BTButtonStyle { BTButtonStyle(kind: .ghost) }
    static var btDanger: BTButtonStyle { BTButtonStyle(kind: .danger) }
    static func bt(_ kind: BTButtonStyle.Kind, size: BTButtonStyle.Size = .regular) -> BTButtonStyle {
        BTButtonStyle(kind: kind, size: size)
    }
}

/// Square, icon-only button with a hover wash. Always pair with `.help(...)`.
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        IconBody(configuration: configuration, size: size, active: active)
    }

    private struct IconBody: View {
        let configuration: ButtonStyleConfiguration
        let size: CGFloat
        let active: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: size * 0.46, weight: .medium))
                .foregroundStyle(hovering || active ? Color.btText : Color.btTextSecondary)
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(active ? Color.btSelection : hovering || configuration.isPressed ? Color.btHover : .clear)
                )
                .scaleEffect(configuration.isPressed ? 0.92 : 1)
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(.snappy(duration: 0.12), value: hovering)
        }
    }
}

extension ButtonStyle where Self == IconButtonStyle {
    static var icon: IconButtonStyle { IconButtonStyle() }
    static func icon(size: CGFloat = 28, active: Bool = false) -> IconButtonStyle { IconButtonStyle(size: size, active: active) }
}

/// Row-sized hover wash for list-like buttons.
struct RowButtonStyle: ButtonStyle {
    var selected = false
    var cornerRadius: CGFloat = 7

    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration, selected: selected, cornerRadius: cornerRadius)
    }

    private struct RowBody: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        let cornerRadius: CGFloat
        @State private var hovering = false

        var body: some View {
            configuration.label
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(selected ? Color.btSelection : hovering ? Color.btHover : .clear)
                )
                .onHover { hovering = $0 }
                .animation(.snappy(duration: 0.12), value: hovering)
        }
    }
}
