import SwiftUI
import UniformTypeIdentifiers
import AbstractCore

/// An image file: fitted to the tab, or at its actual size (⌘0, ⌘1), or
/// pinched to any size between, over a checkerboard where it's transparent.
/// The footer says what it is and how large.
struct ImagePreviewView: View {
    let document: EditorDocument
    let preview: ImagePreview
    @State private var area: CGSize = .zero
    @State private var pinchStart: CGFloat?

    private static let padding = Space.xl

    var body: some View {
        let scale = document.imageScale ?? fitScale
        let shown = CGSize(width: preview.size.width * scale, height: preview.size.height * scale)
        VStack(spacing: 0) {
            ScrollView([.horizontal, .vertical]) {
                ZStack {
                    if preview.facts?.hasAlpha == true { Checkerboard() }
                    Image(nsImage: preview.image)
                        .resizable()
                        // Enlarged pixels stay crisp squares, as in Preview.
                        .interpolation(scale >= 2 ? .none : .high)
                }
                .frame(width: shown.width, height: shown.height)
                .padding(Self.padding)
                .frame(minWidth: area.width, minHeight: area.height)
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { area = $0 }
            .gesture(
                MagnifyGesture()
                    .onChanged { value in
                        let start = pinchStart ?? scale
                        pinchStart = start
                        document.imageScale = ImageZoom.clamp(start * value.magnification)
                    }
                    .onEnded { _ in pinchStart = nil }
            )
            ImageFooter(document: document, preview: preview, scale: scale)
        }
        .onChange(of: fitScale, initial: true) { document.fitScale = fitScale }
    }

    /// The whole image in the tab, never enlarged past its actual size.
    private var fitScale: CGFloat {
        let room = CGSize(width: area.width - Self.padding * 2, height: area.height - Self.padding * 2)
        guard room.width > 0, room.height > 0 else { return 1 }
        return min(1, room.width / preview.size.width, room.height / preview.size.height)
    }
}

/// Zoom steps shared by the pinch, the footer and the View menu.
enum ImageZoom {
    static func clamp(_ scale: CGFloat) -> CGFloat { min(max(scale, 0.05), 32) }

    /// ⌘= and ⌘-: the next step up or down from `scale`.
    static func step(_ scale: CGFloat, in: Bool) -> CGFloat {
        clamp(`in` ? scale * 1.25 : scale / 1.25)
    }
}

extension EditorDocument {
    func zoomToFit() { imageScale = nil }
    func zoomToActualSize() { imageScale = 1 }
    func zoom(in: Bool) { imageScale = ImageZoom.step(imageScale ?? fitScale, in: `in`) }
}

/// "PNG image · 1280 × 720 · 36.4 KB", and the zoom.
private struct ImageFooter: View {
    let document: EditorDocument
    let preview: ImagePreview
    let scale: CGFloat

    private enum Choice: Hashable { case fit, actual, other }

    var body: some View {
        HStack(spacing: Space.md) {
            Text(summary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: Space.sm)
            Text("\(Int((scale * 100).rounded()))%").monospacedDigit()
            Picker("Zoom", selection: Binding<Choice>(
                get: { document.imageScale == nil ? .fit : document.imageScale == 1 ? .actual : .other },
                set: { $0 == .fit ? document.zoomToFit() : document.zoomToActualSize() }
            )) {
                Text("Fit").tag(Choice.fit).help("Fit the image to the tab (⌘0)")
                Text("Actual Size").tag(Choice.actual).help("Show the image at its actual size (⌘1)")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .controlSize(.small)
        }
        .font(BTFont.ui(12))
        .foregroundStyle(Color.btTextTertiary)
        .padding(.horizontal, Space.md)
        .frame(height: 36)
        .overlay(alignment: .top) { Hairline() }
    }

    private var summary: String {
        let kind = preview.facts.flatMap { UTType($0.type)?.localizedDescription }
            ?? (document.path as NSString).pathExtension.uppercased()
        let pixels = preview.facts?.dimensions ?? "\(Int(preview.size.width)) × \(Int(preview.size.height)) pt"
        return [kind, pixels, EditorDocument.format(document.size)].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// Grey squares behind a transparent image, so what's see-through shows.
/// Tiled, so a large image zoomed in costs no more to draw.
private struct Checkerboard: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Image(nsImage: scheme == .dark ? Self.dark : Self.light).resizable(resizingMode: .tile)
    }

    private static let light = tile(NSColor(white: 0.98, alpha: 1), NSColor(white: 0.86, alpha: 1))
    private static let dark = tile(NSColor(white: 0.30, alpha: 1), NSColor(white: 0.22, alpha: 1))

    private static func tile(_ base: NSColor, _ square: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            base.setFill()
            rect.fill()
            square.setFill()
            NSRect(x: 0, y: 0, width: 8, height: 8).fill()
            NSRect(x: 8, y: 8, width: 8, height: 8).fill()
            return true
        }
    }
}
