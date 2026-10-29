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
            let shape = RoundedRectangle(cornerRadius: cornerRadius ?? (size == .small ? 7 : 9), style: .continuous)
            configuration.label
                .font(size == .small ? .btCallout.weight(.medium) : .btBodyMedium)
                .lineLimit(1)
                .padding(.horizontal, size == .small ? 9 : size == .large ? 16 : 12)
                .frame(height: size == .small ? 24 : size == .large ? 34 : 28)
                .foregroundStyle(foreground)
                .background(background, in: shape)
                .shadow(color: kind == .primary && isEnabled ? Color.btAccent.opacity(hovering ? 0.18 : 0.1) : .clear,
                        radius: hovering ? 12 : 7, y: 2)
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

        private var background: AnyShapeStyle {
            switch kind {
            case .primary:
                AnyShapeStyle(LinearGradient(
                    colors: [Color.btAccent.opacity(configuration.isPressed ? 0.9 : 1),
                             Color.btAccent.opacity(configuration.isPressed ? 0.78 : hovering ? 0.88 : 0.84)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
            case .secondary:
                AnyShapeStyle(LinearGradient(
                    colors: [hovering || configuration.isPressed ? Color.btSelection : Color.btSurfaceRaised,
                             configuration.isPressed ? Color.btSelection : Color.btHover],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
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
            configuration.label
                .font(.system(size: size * 0.46, weight: .medium))
                .foregroundStyle(hovering || active ? Color.btText : Color.btTextSecondary)
                .frame(width: size, height: size)
                .background(LinearGradient(
                    colors: active ? [Color.btSelection, Color.btHover] : hovering || configuration.isPressed
                        ? [Color.btHover, Color.btSurfaceRaised] : [.clear, .clear],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
