import AppKit
import CoreGraphics

/// ABEL's look: a small pixel-art robot with a visor face and Abstract's
/// chevron for a crest, drawn from code so every frame stays crisp. One
/// animation per state: idle bobs and blinks, listening pulses its ears,
/// thinking looks around under three dots, answering talks, paused dozes.
public enum AbelSprite {
    public static let width = 20, height = 20

    public enum Pose: String, CaseIterable, Sendable {
        case idle, listening, thinking, answering, paused
    }

    /// Frames per second the animations are drawn at.
    public static let fps = 8.0

    // Palette indices.
    static let clear: UInt8 = 0, outline: UInt8 = 1, body: UInt8 = 2, shine: UInt8 = 3, visor: UInt8 = 4
    static let eye: UInt8 = 5, dimEye: UInt8 = 6, crest: UInt8 = 7, zee: UInt8 = 8

    static let colors: [UInt8: UInt32] = [
        outline: 0x121216, body: 0x3B3D46, shine: 0x5D606D, visor: 0x09090C,
        eye: 0x7FF0FF, dimEye: 0x2E6F7B, crest: 0xF2F2F4, zee: 0xA4A4AD,
    ]

    struct Canvas {
        var pixels = [[UInt8]](repeating: [UInt8](repeating: 0, count: AbelSprite.width), count: AbelSprite.height)

        mutating func set(_ x: Int, _ y: Int, _ color: UInt8) {
            guard (0..<AbelSprite.width).contains(x), (0..<AbelSprite.height).contains(y) else { return }
            pixels[y][x] = color
        }

        mutating func fill(_ xs: ClosedRange<Int>, _ ys: ClosedRange<Int>, _ color: UInt8) {
            for y in ys { for x in xs { set(x, y, color) } }
        }
    }

    /// The pixels of one frame, by palette index.
    public static func pixels(_ pose: Pose, tick: Int) -> [[UInt8]] {
        var c = Canvas()
        // A one-pixel bob, slower while dozing; still while listening, so it reads as attention.
        let bob: Int = switch pose {
        case .idle: (tick / 6) % 2
        case .paused: (tick / 12) % 2
        case .answering: (tick / 4) % 2
        default: 0
        }
        let y0 = bob

        // Crest: Abstract's chevron, an A with its legs apart.
        c.fill(9...10, (0 + y0)...(0 + y0), crest)
        c.fill(8...11, (1 + y0)...(1 + y0), crest)
        c.fill(7...8, (2 + y0)...(2 + y0), crest)
        c.fill(11...12, (2 + y0)...(2 + y0), crest)

        // Body: a rounded block, outlined.
        c.fill(4...15, (3 + y0)...(3 + y0), outline)
        c.fill(4...15, (15 + y0)...(15 + y0), outline)
        c.fill(3...3, (4 + y0)...(14 + y0), outline)
        c.fill(16...16, (4 + y0)...(14 + y0), outline)
        c.fill(4...15, (4 + y0)...(14 + y0), body)
        c.fill(5...8, (4 + y0)...(4 + y0), shine)
        c.fill(4...4, (5 + y0)...(6 + y0), shine)

        // Visor.
        c.fill(5...14, (6 + y0)...(11 + y0), outline)
        c.fill(6...13, (7 + y0)...(10 + y0), visor)

        // Eyes.
        let blink = pose != .paused && tick % 32 < 2
        switch pose {
        case .paused:
            c.fill(7...8, (9 + y0)...(9 + y0), dimEye)
            c.fill(11...12, (9 + y0)...(9 + y0), dimEye)
        case _ where blink:
            c.fill(7...8, (9 + y0)...(9 + y0), eye)
            c.fill(11...12, (9 + y0)...(9 + y0), eye)
        case .listening:
            c.fill(7...8, (7 + y0)...(9 + y0), eye)
            c.fill(11...12, (7 + y0)...(9 + y0), eye)
        case .thinking:
            let look = [0, 1, 0, -1][(tick / 4) % 4]
            c.fill((7 + look)...(8 + look), (8 + y0)...(9 + y0), eye)
            c.fill((11 + look)...(12 + look), (8 + y0)...(9 + y0), eye)
        default:
            c.fill(7...8, (8 + y0)...(9 + y0), eye)
            c.fill(11...12, (8 + y0)...(9 + y0), eye)
        }

        // Mouth, while talking.
        if pose == .answering, (tick / 2) % 2 == 0 { c.fill(9...10, (10 + y0)...(10 + y0), eye) }

        // Belly mark: a tiny chevron, dim.
        c.set(9, 12 + y0, shine); c.set(10, 12 + y0, shine)
        c.set(8, 13 + y0, shine); c.set(11, 13 + y0, shine)

        // Feet stay on the ground.
        c.fill(5...7, 16...17, outline)
        c.fill(12...14, 16...17, outline)

        // Extras per state.
        switch pose {
        case .listening:
            // Sound coming in, from the outside toward the ears.
            let outer = (tick / 3) % 2 == 0
            let x = outer ? (0, 19) : (1, 18)
            c.fill(x.0...x.0, (7 + y0)...(10 + y0), eye)
            c.fill(x.1...x.1, (7 + y0)...(10 + y0), eye)
            if outer {
                c.set(1, 6 + y0, eye); c.set(1, 11 + y0, eye)
                c.set(18, 6 + y0, eye); c.set(18, 11 + y0, eye)
            }
        case .thinking:
            let dots = (tick / 3) % 4
            for i in 0..<dots { c.set(15 + i * 2, 1, crest) }
        case .paused:
            if (tick / 8) % 2 == 0 {
                c.fill(16...19, 0...0, zee); c.set(18, 1, zee); c.set(17, 2, zee); c.fill(16...19, 3...3, zee)
            }
        default:
            break
        }
        return c.pixels
    }

    /// One frame as an image, one pixel per sprite pixel; draw it scaled
    /// with no smoothing.
    public static func image(_ pose: Pose, tick: Int) -> CGImage? {
        let grid = pixels(pose, tick: tick)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                guard let rgb = colors[grid[y][x]] else { continue }
                let i = (y * width + x) * 4
                bytes[i] = UInt8((rgb >> 16) & 0xFF); bytes[i + 1] = UInt8((rgb >> 8) & 0xFF)
                bytes[i + 2] = UInt8(rgb & 0xFF); bytes[i + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// The tick for `date`, at `fps`.
    public static func tick(at date: Date) -> Int { Int(date.timeIntervalSinceReferenceDate * fps) }
}

/// Abstract's mark, drawn from its two shapes: the menu bar item's icon.
public enum AbelMark {
    /// A template image, so the menu bar tints it.
    public static func image(height: CGFloat = 16) -> NSImage {
        let size = NSSize(width: height * 39.862 / 44.737, height: height)
        let image = NSImage(size: size, flipped: true) { rect in
            let scale = rect.height / 44.737
            func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * scale, y: y * scale) }
            NSColor.black.setFill()
            let left = NSBezierPath()
            left.move(to: point(6.649, 44.737)); left.line(to: point(0, 33.562)); left.line(to: point(6.649, 22.368))
            left.line(to: point(19.933, 22.368)); left.line(to: point(13.289, 33.562)); left.line(to: point(19.933, 44.737))
            left.close(); left.fill()
            let right = NSBezierPath()
            right.move(to: point(26.577, 11.184)); right.line(to: point(19.933, 0)); right.line(to: point(13.289, 11.184))
            right.line(to: point(19.933, 22.368)); right.line(to: point(26.577, 33.562)); right.line(to: point(33.222, 44.737))
            right.line(to: point(39.862, 33.562)); right.line(to: point(33.222, 22.368)); right.close(); right.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "ABEL"
        return image
    }
}
