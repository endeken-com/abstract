import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What an image file holds, read from its bytes rather than its name: any
/// format macOS decodes counts, with or without an extension.
public struct ImageFacts: Sendable, Hashable {
    /// The format's identifier, e.g. "public.png" or "public.avif".
    public var type: String
    /// Pixels, as the image is meant to be seen (after its orientation).
    public var width: Int
    public var height: Int
    public var hasAlpha: Bool

    public init(type: String, width: Int, height: Int, hasAlpha: Bool) {
        self.type = type; self.width = width; self.height = height; self.hasAlpha = hasAlpha
    }

    /// The image in `data`, or nil when ImageIO can't decode it as one.
    public init?(_ data: Data) {
        guard !data.isEmpty, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { return nil }
        // EXIF orientations 5 to 8 turn the picture a quarter.
        let turned = ((properties[kCGImagePropertyOrientation] as? Int) ?? 1) >= 5
        self.type = type as String
        self.width = turned ? height : width
        self.height = turned ? width : height
        self.hasAlpha = properties[kCGImagePropertyHasAlpha] as? Bool ?? false
    }

    /// Whether a file named like `path` is an image by its extension alone,
    /// including the vector formats (PDF, SVG) ImageIO doesn't read.
    public static func isImageName(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .pdf)
    }

    /// "1280 × 720".
    public var dimensions: String { "\(width) × \(height)" }
}
