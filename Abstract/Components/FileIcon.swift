import AppKit
import SwiftUI

/// Icons for files and folders by what they are: the Material Icon Theme
/// (https://github.com/material-extensions/vscode-material-icon-theme, MIT),
/// with its colours toned down as Paseo does. `material-icons.json` holds
/// the SVGs and the theme's lookups, generated from the theme's sources.
nonisolated enum FileIconTheme {
    private struct Manifest: Decodable {
        let icons: [String: String]
        let fileExtensions: [String: String]
        let fileNames: [String: String]
        let folderNames: [String: String]
        let light: [String]
    }

    private static let manifest: Manifest? = Bundle.main.url(forResource: "material-icons", withExtension: "json")
        .flatMap { try? Data(contentsOf: $0) }
        .flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) }
    private static let lightVariants = Set(manifest?.light ?? [])

    /// The theme's icon name for a file: its exact name first, then its
    /// longest extension ("test.tsx" before "tsx"), then the plain file.
    static func name(forFile path: String) -> String {
        guard let manifest else { return "file" }
        let name = (path as NSString).lastPathComponent.lowercased()
        if let icon = manifest.fileNames[name] { return icon }
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        for start in parts.indices.dropFirst() {
            let ext = parts[start...].joined(separator: ".")
            if let icon = manifest.fileExtensions[ext] { return icon }
        }
        return "file"
    }

    static func name(forFolder path: String, open: Bool) -> String {
        let name = (path as NSString).lastPathComponent.lowercased()
        let base = manifest?.folderNames[name] ?? "folder"
        if open, manifest?.icons[base + "-open"] != nil { return base + "-open" }
        return base
    }

    /// The SVG for an icon, in its light variant on light backgrounds when the theme has one.
    static func svg(_ name: String, light: Bool) -> String? {
        if light, lightVariants.contains(name.replacingOccurrences(of: "-open", with: "")),
           let variant = manifest?.icons[name + "_light"] {
            return variant
        }
        return manifest?.icons[name]
    }
}

/// Drawn icons, made once per name and appearance.
@MainActor
private enum FileIconCache {
    static var images: [String: NSImage] = [:]

    static func image(_ name: String, light: Bool) -> NSImage? {
        let key = name + (light ? "|light" : "")
        if let cached = images[key] { return cached }
        guard let svg = FileIconTheme.svg(name, light: light), let image = NSImage(data: Data(svg.utf8)) else { return nil }
        images[key] = image
        return image
    }
}

/// A file's or folder's icon from the theme, at a small fixed size.
struct FileIcon: View {
    let path: String
    var isDirectory = false
    var open = false
    var size: CGFloat = 14
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let name = isDirectory ? FileIconTheme.name(forFolder: path, open: open) : FileIconTheme.name(forFile: path)
        if let image = FileIconCache.image(name, light: colorScheme == .light) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Image(systemName: isDirectory ? "folder" : "doc")
                .font(.system(size: size * 0.8, weight: .regular))
                .foregroundStyle(Color.btTextTertiary)
                .frame(width: size, height: size)
        }
    }
}
