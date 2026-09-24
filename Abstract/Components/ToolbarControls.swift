import SwiftUI

/// A toolbar item drawn by Abstract alone: on macOS 26 the system would put
/// it in a shared glass capsule, which reads as a native segmented pill.
struct PlainToolbarItem<Content: View>: ToolbarContent {
    var placement: ToolbarItemPlacement = .automatic
    @ViewBuilder var content: () -> Content

    var body: some ToolbarContent {
        if #available(macOS 26, *) {
            ToolbarItem(placement: placement) { content() }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: placement) { content() }
        }
    }
}

/// Every icon in the window chrome: the same size, weight and hover wash,
/// so the sidebar and chat toolbars line up and read as one set.
struct ChromeIconStyle: ButtonStyle {
    var active = false
    var size: CGFloat = Chrome.button

    func makeBody(configuration: Configuration) -> some View {
        ChromeIcon(label: configuration.label, active: active, pressed: configuration.isPressed, size: size)
    }
}

private struct ChromeIcon<Label: View>: View {
    let label: Label
    let active: Bool
    let pressed: Bool
    let size: CGFloat
    @State private var hovering = false

    var body: some View {
        label
            .font(.system(size: size * 0.48, weight: .regular))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(active || hovering ? Color.btText : Color.btTextSecondary)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(active ? Color.btSelection : hovering || pressed ? Color.btHover : .clear)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.snappy(duration: 0.12), value: hovering)
    }
}

/// A menu that looks like a chrome icon rather than a native pull-down.
struct ChromeIconMenu<Content: View>: View {
    let symbol: String
    let help: String
    var size: CGFloat = Chrome.button
    @ViewBuilder var content: () -> Content

    var body: some View {
        Menu(content: content) {
            Image(systemName: symbol)
        }
        .menuStyle(.button)
        .buttonStyle(ChromeIconStyle(size: size))
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help)
    }
}

enum Chrome {
    static let button: CGFloat = 28
    static let gap: CGFloat = 2
    /// What the three chat buttons (and the toolbar's edge) take from the side
    /// panel's width, leaving the rest to its tabs: the buttons, their gaps,
    /// the toolbar's trailing inset and a hair of room past the divider.
    static let sideTabsReserve: CGFloat = 3 * button + 3 * gap + 14 + 1
    /// Height of the window's titlebar band (unified toolbar).
    static let titlebar: CGFloat = 52
    /// Where the first leading toolbar item starts, just past the traffic
    /// lights (measured once on macOS 26; the lights sit tighter before it).
    static var leadingItemOrigin: CGFloat {
        if #available(macOS 26, *) { 100 } else { 78 }
    }
}

extension View {
    /// Scrolls under the window title and fades out beneath it with
    /// macOS 26's progressive blur, instead of stopping at a hard line.
    @ViewBuilder
    func btUnderTitle() -> some View {
        if #available(macOS 26, *) {
            scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }
}
