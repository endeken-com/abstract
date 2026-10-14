// Makes every app icon from the two Horizonte sources in Abstract/Resources/Brand.
// Run it through scripts/make-icons.sh; Abstract/Resources/ICONS.md says which file is which.
import AppKit
import CoreImage

let brand = "Abstract/Resources/Brand"
let masters = "Abstract/Resources/AppIcon.icon/Assets"
let phone = "mobile/assets"
let phoneIcons = "mobile/ios/Abstract/Images.xcassets/AppIcon.appiconset"

/// Every file this script writes, and its size in pixels.
let outputs: [(path: String, size: Int)] = [
    ("\(masters)/horizonte-dark.png", 1024),
    ("\(masters)/horizonte-light.png", 1024),
    ("\(phone)/icon-dark.png", 1024),
    ("\(phone)/icon-light.png", 1024),
    ("\(phone)/icon-arc.png", 1024),
    ("\(phone)/icon-clear.png", 1024),
    ("\(phoneIcons)/App-Icon-1024x1024@1x.png", 1024),
    ("\(phoneIcons)/App-Icon-dark-1024x1024@1x.png", 1024),
]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-icons: \(message)\n".utf8))
    exit(1)
}

func load(_ path: String) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("can't read \(path)") }
    return image
}

func save(_ image: CGImage, _ path: String) {
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { fail("can't write \(path)") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fail("can't write \(path)") }
}

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

/// The source scaled to a square, with no alpha channel: the stores refuse icons with one.
func opaque(_ image: CGImage, _ size: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    return ctx.makeImage()!
}

/// The bright arc alone, white on transparent: Android's themed icon. Blurring first
/// drops the grain, and widens the line a little so it still reads at launcher sizes.
func arc(_ image: CGImage) -> CGImage {
    let size = image.width
    let blurred = CIImage(cgImage: image)
        .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        .clampedToExtent()
        .applyingGaussianBlur(sigma: Double(size) / 512)
        .cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
    var luma = [UInt8](repeating: 0, count: size * size * 4)
    CIContext(options: [.workingColorSpace: sRGB]).render(blurred, toBitmap: &luma, rowBytes: size * 4,
                                                          bounds: blurred.extent, format: .RGBA8, colorSpace: sRGB)
    let (low, high) = (0.5, 0.8)
    var pixels = [UInt8](repeating: 0, count: size * size * 4)
    for i in 0..<(size * size) {
        let t = min(max((Double(luma[i * 4]) / 255 - low) / (high - low), 0), 1)
        let alpha = UInt8((t * t * (3 - 2 * t) * 255).rounded())
        // Premultiplied white.
        pixels[i * 4] = alpha; pixels[i * 4 + 1] = alpha; pixels[i * 4 + 2] = alpha; pixels[i * 4 + 3] = alpha
    }
    let ctx = CGContext(data: &pixels, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return ctx.makeImage()!
}

func make() {
    let dark = opaque(load("\(brand)/horizonte-dark.png"), 1024)
    let light = opaque(load("\(brand)/horizonte-light.png"), 1024)
    save(dark, "\(masters)/horizonte-dark.png")
    save(light, "\(masters)/horizonte-light.png")
    save(dark, "\(phone)/icon-dark.png")
    save(light, "\(phone)/icon-light.png")
    save(arc(dark), "\(phone)/icon-arc.png")
    // Android's adaptive icon draws the artwork as its background layer, under nothing.
    save(CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!, "\(phone)/icon-clear.png")
    // What `expo prebuild` writes from app.config.js, kept in step for the checked-in iOS project.
    save(light, "\(phoneIcons)/App-Icon-1024x1024@1x.png")
    save(dark, "\(phoneIcons)/App-Icon-dark-1024x1024@1x.png")
}

/// Fails when an icon is missing or the wrong size, or the Icon Composer document
/// names an image that isn't there.
func check() {
    var problems: [String] = []
    for (path, size) in outputs {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            problems.append("\(path) is missing"); continue
        }
        let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0, height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        if width != size || height != size { problems.append("\(path) is \(width)×\(height), not \(size)×\(size)") }
    }
    let doc = "Abstract/Resources/AppIcon.icon/icon.json"
    if let data = FileManager.default.contents(atPath: doc), let json = try? JSONSerialization.jsonObject(with: data) {
        func images(_ value: Any) -> [String] {
            switch value {
            case let s as String: s.hasSuffix(".png") ? [s] : []
            case let a as [Any]: a.flatMap(images)
            case let d as [String: Any]: d.values.flatMap(images)
            default: []
            }
        }
        let names = images(json)
        if names.isEmpty { problems.append("\(doc) names no image") }
        for name in Set(names) where !FileManager.default.fileExists(atPath: "\(masters)/\(name)") {
            problems.append("\(doc) names \(name), which isn't in \(masters)")
        }
    } else {
        problems.append("\(doc) is missing")
    }
    guard problems.isEmpty else { fail(problems.joined(separator: "\n")) }
    print("make-icons: \(outputs.count) icons, all present and the right size")
}

switch CommandLine.arguments.dropFirst().first {
case nil: make(); check()
case "--check": check()
default: fail("usage: scripts/make-icons.sh [--check]")
}
