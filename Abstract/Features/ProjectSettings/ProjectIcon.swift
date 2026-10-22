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

/// Every icon editor offers the same symbols, including existing profile and workflow choices.
enum ProjectIconSymbols {
    static let all = [
        "folder", "shippingbox", "cube", "square.stack.3d.up", "hammer",
        "wrench.and.screwdriver", "terminal", "chevron.left.forwardslash.chevron.right", "curlybraces", "server.rack",
        "cloud", "globe", "iphone", "macwindow", "gamecontroller",
        "paintbrush.pointed", "book.closed", "chart.bar", "leaf", "bolt",
        "person.crop.circle", "magnifyingglass", "list.bullet.clipboard", "ladybug",
        "doc.text.magnifyingglass", "lightbulb", "paintpalette", "checkmark.seal",
        "testtube.2", "text.book.closed", "shield.lefthalf.filled", "sparkles",
        Workflow.defaultSymbol,
    ]
}

enum IconContext {
    case project(owner: String?)
    case profile
    case workflow
    case plugin

    var defaultSymbol: String? {
        switch self {
        case .profile: "person.crop.circle"
        case .workflow: Workflow.defaultSymbol
        case .project, .plugin: nil
        }
    }
}

/// One tile for the same saved value wherever its owner appears.
struct IconTile: View {
    let value: IconValue
    let name: String
    let context: IconContext
    var size: CGFloat = 30
    var imageData: Data? = nil

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: (size * 0.26).rounded(), style: .continuous)
        Group {
            if let imageData, let image = NSImage(data: imageData) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
            } else if let path = value.imagePath, let image = ProjectIconStore.image(path) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
            } else if !value.isDefault {
                tile
            } else if case .project(let owner) = context,
                      let owner, let url = GitRemote.githubAvatarURL(owner: owner, size: 96) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().interpolation(.high).scaledToFill() } else { tile }
                }
            } else {
                tile
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .accessibilityLabel("\(name) icon")
    }

    private var tint: ProjectIconColor? { value.color.flatMap(ProjectIconColor.init(rawValue:)) }

    private var tile: some View {
        ZStack {
            Rectangle().fill(tint?.color ?? Color.btInset)
            Group {
                if let symbol = value.symbol ?? context.defaultSymbol {
                    Image(systemName: symbol).font(.system(size: size * 0.44, weight: .medium))
                } else {
                    Text(String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
                        .font(BTFont.ui(size * 0.46, .semibold))
                }
            }
            .foregroundStyle(tint == nil ? Color.btTextSecondary : Color.white.opacity(0.92))
        }
    }
}

struct ProjectIconView: View {
    let project: Project
    var owner: String?
    var size: CGFloat = 30

    var body: some View {
        IconTile(value: IconValue(symbol: project.iconSymbol, color: project.iconColor, imagePath: project.iconImagePath),
                 name: project.name, context: .project(owner: owner), size: size)
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
            IconPicker(value: IconValue(symbol: project.iconSymbol, color: project.iconColor, imagePath: project.iconImagePath),
                       name: project.name, onChange: { value in
                           model.setProjectIcon(project.id, symbol: value.symbol, color: value.color)
                       }, onUpload: { model.importProjectIcon(project.id, from: $0) },
                       dismiss: { open = false })
        }
    }
}

struct SharedIconButton: View {
    let value: IconValue
    let name: String
    let context: IconContext
    let onChange: (IconValue) -> Void
    let onUpload: (URL) -> Void
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            IconTile(value: value, name: name, context: context, size: 30)
        }
        .buttonStyle(.plain)
        .help("Change the icon")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            IconPicker(value: value, name: name, onChange: onChange,
                       onUpload: onUpload, dismiss: { open = false })
        }
    }
}

/// Symbols, colours, an image of your own, or the default.
struct IconPicker: View {
    let value: IconValue
    let name: String
    let onChange: (IconValue) -> Void
    let onUpload: (URL) -> Void
    let dismiss: () -> Void
    var dismissBeforeUpload = true
    var onUploadStart: () -> Void = {}
    var onUploadCancel: () -> Void = {}

    private static let cell: CGFloat = 32
    private static let columns = Array(repeating: GridItem(.fixed(cell), spacing: 4), count: 5)

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 4) {
                ForEach(symbols, id: \.self) { symbol in
                    Button { onChange(IconValue(symbol: symbol, color: value.color)) } label: {
                        Image(systemName: symbol)
                    }
                    .buttonStyle(.icon(size: Self.cell, active: value.imagePath == nil && value.symbol == symbol))
                    .help(symbol)
                    .accessibilityLabel(symbol)
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
                if !value.isDefault {
                    action("Use Default") {
                        onChange(IconValue())
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

    private var symbols: [String] {
        guard let selected = value.symbol, !ProjectIconSymbols.all.contains(selected) else { return ProjectIconSymbols.all }
        return [selected] + ProjectIconSymbols.all
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
        let selected = value.imagePath == nil && value.color == tint?.rawValue
        return Button { onChange(IconValue(symbol: value.symbol, color: tint?.rawValue)) } label: {
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
        panel.message = "Choose an image for \(name)"
        panel.prompt = "Use Image"
        onUploadStart()
        if dismissBeforeUpload { dismiss() }
        guard panel.runModal() == .OK, let url = panel.url else { onUploadCancel(); return }
        onUpload(url)
    }
}
