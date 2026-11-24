import SwiftUI

/// Abstract's button styles. Each reacts to hover and press, and dims when
/// disabled, so every clickable thing feels the same.
struct BTButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost, danger }
    enum Size { case small, regular, large }

    var kind: Kind = .secondary
    var size: Size = .regular
    var cornerRadius: CGFloat? = nil

    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, kind: kind, size: size, cornerRadius: cornerRadius)
    }

    private struct StyledButton: View {
        let configuration: ButtonStyleConfiguration
        let kind: Kind
        let size: Size
        let cornerRadius: CGFloat?
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: cornerRadius ?? Radius.control, style: .continuous)
            configuration.label
                .font(size == .small ? .btCallout.weight(.medium) : .btBodyMedium)
                .lineLimit(1)
                .padding(.horizontal, size == .small ? 9 : size == .large ? 16 : 12)
                .frame(height: size == .small ? 24 : size == .large ? 34 : 28)
                .foregroundStyle(foreground)
                .background {
                    shape.fill(fill)
                        .overlay(shape.fill(interactionWash))
                        .overlay(shape.strokeBorder(border, lineWidth: Stroke.emphasis))
                }
                .scaleEffect(reduceMotion ? 1 : configuration.isPressed ? 0.975 : 1)
                .opacity(isEnabled ? 1 : 0.5)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: hovering)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
        }

        private var foreground: Color {
            switch kind {
            case .primary: .btOnAccent
            case .secondary: .btText
            case .ghost: hovering ? .btText : .btTextSecondary
            case .danger: .btRemoved
            }
        }

        private var fill: Color {
            switch kind {
            case .primary: .btAccent
            case .secondary: .btSurfaceRaised
            case .ghost, .danger: .clear
            }
        }

        private var interactionWash: Color {
            if configuration.isPressed {
                switch kind {
                case .primary: return Color.btOnAccent.opacity(0.16)
                case .secondary, .ghost: return .btSelection
                case .danger: return .btRemovedWash
                }
            }
            guard hovering else { return .clear }
            switch kind {
            case .primary: return Color.btOnAccent.opacity(0.08)
            case .secondary, .ghost: return .btHover
            case .danger: return .btRemovedWash
            }
        }

        private var border: Color {
            switch kind {
            case .secondary: hovering ? .btBorderStrong : .btBorder
            case .primary, .ghost, .danger: .clear
            }
        }
    }
}

extension ButtonStyle where Self == BTButtonStyle {
    static var btPrimary: BTButtonStyle { BTButtonStyle(kind: .primary) }
    static var btSecondary: BTButtonStyle { BTButtonStyle(kind: .secondary) }
    static var btGhost: BTButtonStyle { BTButtonStyle(kind: .ghost) }
    static var btDanger: BTButtonStyle { BTButtonStyle(kind: .danger) }
    static func bt(_ kind: BTButtonStyle.Kind, size: BTButtonStyle.Size = .regular,
                   cornerRadius: CGFloat? = nil) -> BTButtonStyle {
        BTButtonStyle(kind: kind, size: size, cornerRadius: cornerRadius)
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
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            configuration.label
                .font(.system(size: size * 0.46, weight: .medium))
                .foregroundStyle(hovering || active ? Color.btText : Color.btTextSecondary)
                .frame(width: size, height: size)
                .background(active ? Color.btSelection : configuration.isPressed ? Color.btSelection : hovering ? Color.btHover : .clear,
                            in: shape)
                .scaleEffect(reduceMotion ? 1 : configuration.isPressed ? 0.94 : 1)
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovering)
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
    var cornerRadius: CGFloat = Radius.control

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
