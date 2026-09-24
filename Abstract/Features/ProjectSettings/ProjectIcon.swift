import AppKit
import SwiftUI
import UniformTypeIdentifiers
import AbstractCore

/// The tile colours a project icon can take: neutral greys and a few
/// desaturated tones. Stored by name; nil is the neutral default.
enum ProjectIconColor: String, CaseIterable, Identifiable {
    case graphite, slate, stone, sage, rose, plum, sand

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .graphite: Color(nsColor: NSColor(hex: 0x4A4A51))
        case .slate: Color(nsColor: NSColor(hex: 0x7A7A83))
        case .stone: Color(nsColor: NSColor(hex: 0x8E877C))
        case .sage: Color(nsColor: NSColor(hex: 0x7C8B74))
        case .rose: Color(nsColor: NSColor(hex: 0x9E7F7F))
        case .plum: Color(nsColor: NSColor(hex: 0x86778A))
        case .sand: Color(nsColor: NSColor(hex: 0xA09780))
        }
    }

    var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

/// Symbols that suit a project.
enum ProjectIconSymbols {
    static let all = [
        "folder", "shippingbox", "cube", "square.stack.3d.up", "hammer",
        "wrench.and.screwdriver", "terminal", "chevron.left.forwardslash.chevron.right", "curlybraces", "server.rack",
        "cloud", "globe", "iphone", "macwindow", "gamecontroller",
        "paintbrush.pointed", "book.closed", "chart.bar", "leaf", "bolt",
    ]
}

/// A project's icon: its uploaded image, else its symbol or initial on its
/// colour, else (with nothing chosen) the GitHub owner's avatar.
struct ProjectIconView: View {
    let project: Project
    /// The GitHub owner of the project's origin, for the default.
    var owner: String?
    var size: CGFloat = 30

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: (size * 0.26).rounded(), style: .continuous)
        Group {
            if let path = project.iconImagePath, let image = ProjectIconStore.image(path) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
            } else if project.iconSymbol != nil || project.iconColor != nil {
                tile
            } else if let owner, let url = GitRemote.githubAvatarURL(owner: owner, size: 96) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().interpolation(.high).scaledToFill() } else { tile }
                }
            } else {
                tile
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .accessibilityHidden(true)
    }

    private var tint: ProjectIconColor? { project.iconColor.flatMap(ProjectIconColor.init(rawValue:)) }

    private var tile: some View {
        ZStack {
            Rectangle().fill(tint?.color ?? Color.btInset)
            Group {
                if let symbol = project.iconSymbol {
                    Image(systemName: symbol).font(.system(size: size * 0.44, weight: .medium))
                } else {
                    Text(String(project.name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
                        .font(BTFont.ui(size * 0.46, .semibold))
                }
            }
            .foregroundStyle(tint == nil ? Color.btTextSecondary : Color.white.opacity(0.92))
        }
    }
}

/// The Icon row's tile: opens the picker.
struct ProjectIconButton: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let owner: String?
    @State private var open = false
    @State private var hovering = false

    var body: some View {
        Button { open.toggle() } label: {
            ProjectIconView(project: project, owner: owner, size: 30)
                .opacity(hovering ? 0.85 : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Change the icon")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            ProjectIconPicker(project: project, dismiss: { open = false })
        }
    }
}

/// Symbols, colours, an image of your own, or the default.
struct ProjectIconPicker: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let dismiss: () -> Void

    private static let cell: CGFloat = 32
    private static let columns = Array(repeating: GridItem(.fixed(cell), spacing: 4), count: 5)

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 4) {
                ForEach(ProjectIconSymbols.all, id: \.self) { symbol in
                    Button { model.setProjectIcon(project.id, symbol: symbol, color: project.iconColor) } label: {
                        Image(systemName: symbol)
                    }
                    .buttonStyle(.icon(size: Self.cell, active: project.iconImagePath == nil && project.iconSymbol == symbol))
                    .help(symbol)
                }
            }

            // Spread across the grid's width, the ends under its first and last glyphs.
            HStack(spacing: 0) {
                swatch(nil)
                ForEach(ProjectIconColor.allCases) { tint in
                    Spacer(minLength: 2)
                    swatch(tint)
                }
            }
            .padding(.horizontal, 8)

            Hairline()

            VStack(spacing: 1) {
                action("Upload Image…", action: upload)
                if project.iconSymbol != nil || project.iconColor != nil || project.iconImagePath != nil {
                    action("Use Default") {
                        model.resetProjectIcon(project.id)
                        dismiss()
                    }
                }
            }
            .padding(.horizontal, -Space.xs)
            .padding(.top, -Space.xs)
        }
        .padding(Space.md)
        .frame(width: 5 * Self.cell + 4 * 4 + 2 * Space.md)
        .background(Color.btSurfaceRaised)
    }

    /// A menu-like row: text on a wash when hovered.
    private func action(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.btBody)
                .foregroundStyle(Color.btText)
                .padding(.horizontal, Space.sm)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        }
        .buttonStyle(RowButtonStyle(cornerRadius: Radius.sm))
    }

    private func swatch(_ tint: ProjectIconColor?) -> some View {
        let selected = project.iconImagePath == nil && project.iconColor == tint?.rawValue
        return Button { model.setProjectIcon(project.id, symbol: project.iconSymbol, color: tint?.rawValue) } label: {
            Circle()
                .fill(tint?.color ?? Color.btInset)
                .frame(width: 16, height: 16)
                // The neutral tile is close to the popover's own fill; a hairline shows its edge.
                .overlay { if tint == nil { Circle().strokeBorder(Color.btBorderStrong, lineWidth: 1) } }
                .overlay {
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(tint == nil ? Color.btText : Color.white)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(tint?.title ?? "Neutral")
        .accessibilityLabel(tint?.title ?? "Neutral")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func upload() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an image for \(project.name)"
        panel.prompt = "Use Image"
        dismiss()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.importProjectIcon(project.id, from: url)
    }
}
