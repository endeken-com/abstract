import AppKit
import CoreGraphics

/// ABEL, drawn: a small graphite robot in Abstract's colours, with a visor
/// face, glowing eyes, little arms, and Abstract's mark on its chest and on
/// the tip of its antenna. Every frame is rasterised from shapes at 48×48
/// pixels and shaded (outline, rim light, rim shadow), so it stays crisp
/// pixel art at any whole scale. Each state has its own animation, at 12
/// frames a second.
public enum AbelSprite {
    public static let width = 48, height = 48

    public enum Pose: String, CaseIterable, Sendable {
        /// Breathes, blinks, glances around.
        case idle
        /// Hovered: waves, happy eyes.
        case greeting
        /// Wide eyes, antenna lit, sound rings coming in.
        case listening
        /// Looks up and around under three dots; antenna blinking.
        case thinking
        /// Talks: the mouth moves and the emblem glows.
        case answering
        /// Dozes: eyes shut, z's floating up.
        case paused
    }

    public static let fps = 12.0

    // MARK: Palette

    enum Ink: UInt8 {
        case clear = 0, outline, body, bodyLight, bodyDark, visor, visorLight, eye, eyeDim, mark, markGlow, foot, effect,
             effectDim
    }

    static let rgb: [Ink: UInt32] = [
        .outline: 0x0C0C0F, .body: 0x3A3C45, .bodyLight: 0x5E616E, .bodyDark: 0x25262C, .visor: 0x07070A,
        .visorLight: 0x1D1E24, .eye: 0xE8FBFF, .eyeDim: 0x5F7C83, .mark: 0xF2F2F4, .markGlow: 0xFFFFFF,
        .foot: 0x18191D, .effect: 0xE8FBFF, .effectDim: 0xA4A4AD,
    ]

    // MARK: Shapes

    struct Canvas {
        var px = [Ink](repeating: .clear, count: AbelSprite.width * AbelSprite.height)
        /// Which pixels belong to the solid figure, for the silhouette outline.
        var solid = [Bool](repeating: false, count: AbelSprite.width * AbelSprite.height)

        subscript(x x: Int, y y: Int) -> Ink {
            get { inside(x, y) ? px[y * AbelSprite.width + x] : .clear }
            set { if inside(x, y) { px[y * AbelSprite.width + x] = newValue } }
        }

        func inside(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < AbelSprite.width && y < AbelSprite.height }

        /// Fills where `contains` holds, shaded: light on the top-left rim,
        /// dark on the bottom-right rim.
        mutating func shape(_ contains: (Double, Double) -> Bool, fill: Ink, light: Ink? = nil, dark: Ink? = nil,
                            figure: Bool = true) {
            var mask = [Bool](repeating: false, count: AbelSprite.width * AbelSprite.height)
            for y in 0..<AbelSprite.height {
                for x in 0..<AbelSprite.width where contains(Double(x) + 0.5, Double(y) + 0.5) {
                    mask[y * AbelSprite.width + x] = true
                }
            }
            func m(_ x: Int, _ y: Int) -> Bool { inside(x, y) && mask[y * AbelSprite.width + x] }
            for y in 0..<AbelSprite.height {
                for x in 0..<AbelSprite.width where mask[y * AbelSprite.width + x] {
                    var ink = fill
                    if let light, !m(x, y - 1) || !m(x - 1, y) { ink = light }
                    if let dark, !m(x, y + 1) || !m(x + 1, y) { ink = dark }
                    self[x: x, y: y] = ink
                    if figure { solid[y * AbelSprite.width + x] = true }
                }
            }
        }

        /// A dark line around the whole figure.
        mutating func outlineFigure() {
            var edge: [(Int, Int)] = []
            for y in 0..<AbelSprite.height {
                for x in 0..<AbelSprite.width where !solid[y * AbelSprite.width + x] {
                    let near = [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)].contains { inside($0.0, $0.1) && solid[$0.1 * AbelSprite.width + $0.0] }
                    if near { edge.append((x, y)) }
                }
            }
            for (x, y) in edge where self[x: x, y: y] == .clear { self[x: x, y: y] = .outline }
        }

        mutating func dot(_ x: Int, _ y: Int, _ ink: Ink) { self[x: x, y: y] = ink }
    }

    static func roundedRect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, r: Double) -> (Double, Double) -> Bool {
        { px, py in
            let cx = min(max(px, x + r), x + w - r), cy = min(max(py, y + r), y + h - r)
            return (px - cx) * (px - cx) + (py - cy) * (py - cy) <= r * r && px >= x && px <= x + w && py >= y && py <= y + h
        }
    }

    static func capsule(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double, r: Double) -> (Double, Double) -> Bool {
        { px, py in
            let dx = bx - ax, dy = by - ay
            let t = max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / max(dx * dx + dy * dy, 0.0001)))
            let qx = ax + t * dx - px, qy = ay + t * dy - py
            return qx * qx + qy * qy <= r * r
        }
    }

    /// Abstract's mark (its two shapes), scaled to `height` pixels with its
    /// top-left at (x, y).
    static func mark(_ x: Double, _ y: Double, height: Double) -> (Double, Double) -> Bool {
        let s = height / 44.737
        let left: [(Double, Double)] = [(6.649, 44.737), (0, 33.562), (6.649, 22.368), (19.933, 22.368), (13.289, 33.562), (19.933, 44.737)]
        let right: [(Double, Double)] = [(26.577, 11.184), (19.933, 0), (13.289, 11.184), (19.933, 22.368), (26.577, 33.562),
                                         (33.222, 44.737), (39.862, 33.562), (33.222, 22.368)]
        func inPolygon(_ poly: [(Double, Double)], _ px: Double, _ py: Double) -> Bool {
            var inside = false
            var j = poly.count - 1
            for i in 0..<poly.count {
                let (xi, yi) = (x + poly[i].0 * s, y + poly[i].1 * s), (xj, yj) = (x + poly[j].0 * s, y + poly[j].1 * s)
                if (yi > py) != (yj > py), px < (xj - xi) * (py - yi) / (yj - yi) + xi { inside.toggle() }
                j = i
            }
            return inside
        }
        return { px, py in inPolygon(left, px, py) || inPolygon(right, px, py) }
    }

    // MARK: Frames

    /// One frame, by palette index, as rows.
    public static func pixels(_ pose: Pose, tick: Int) -> [[UInt8]] {
        let c = canvas(pose, tick: tick)
        return (0..<height).map { y in (0..<width).map { x in c[x: x, y: y].rawValue } }
    }

    static func canvas(_ pose: Pose, tick: Int) -> Canvas {
        var c = Canvas()
        // Breathing: a slow sine, to whole pixels; quicker while talking, slower asleep.
        let period: Double = switch pose {
        case .answering: 8
        case .paused: 36
        case .greeting: 10
        default: 22
        }
        let phase = sin(Double(tick) / period * 2 * .pi)
        let bob = phase > 0.3 ? 1 : 0
        // Squash on the way down, stretch on the way up.
        let squash = bob == 1 ? 1.0 : 0.0
        let top = 8.0 + Double(bob)
        let bodyTop = top + 19 + squash

        // Feet, fixed on the ground.
        c.shape(roundedRect(14, 42, 8, 4, r: 1.5), fill: .foot, light: .bodyDark)
        c.shape(roundedRect(26, 42, 8, 4, r: 1.5), fill: .foot, light: .bodyDark)

        // Arms, posed by where the hands are.
        let shoulderY = bodyTop + 3
        let wave = sin(Double(tick) / 2.2)
        let (leftHand, rightHand): ((Double, Double), (Double, Double)) = switch pose {
        case .greeting: ((8, shoulderY + 8), (43 + wave * 2, shoulderY - 11 + abs(wave)))
        case .listening: ((4, shoulderY - 2), (44, shoulderY - 2))
        case .thinking: ((8, shoulderY + 8), (30, shoulderY + 2))
        case .answering: ((7, shoulderY + 6 - Double(bob)), (41, shoulderY + 6 - Double(1 - bob)))
        default: ((8, shoulderY + 8), (40, shoulderY + 8))
        }
        c.shape(capsule(12.5, shoulderY, leftHand.0, leftHand.1, r: 2), fill: .body, light: .bodyLight, dark: .bodyDark)
        c.shape(capsule(35.5, shoulderY, rightHand.0, rightHand.1, r: 2), fill: .body, light: .bodyLight, dark: .bodyDark)

        // Body, with Abstract's mark on the chest.
        c.shape(roundedRect(12 - squash, bodyTop, 24 + 2 * squash, 42 - bodyTop + 0.5, r: 6), fill: .body,
                light: .bodyLight, dark: .bodyDark)
        let markGlow = pose == .answering && (tick / 3) % 2 == 0
        let markHeight = 11.0
        c.shape(mark(24 - markHeight * 0.891 / 2, bodyTop + 2.5, height: markHeight), fill: markGlow ? .markGlow : .mark,
                figure: false)

        // Neck.
        c.shape(roundedRect(21, top + 16, 6, 4, r: 1), fill: .bodyDark)

        // Antenna, its tip lit while ABEL listens, thinks or talks.
        c.shape(capsule(24, top + 1, 24, top - 4, r: 0.8), fill: .bodyDark)
        let tipLit: Bool = switch pose {
        case .listening: (tick / 3) % 2 == 0
        case .thinking: (tick / 2) % 3 != 0
        case .answering, .greeting: true
        default: false
        }
        c.shape({ x, y in (x - 24) * (x - 24) + (y - (top - 6)) * (y - (top - 6)) <= 5.3 },
                fill: tipLit ? .markGlow : .bodyLight, light: tipLit ? .markGlow : .mark, dark: tipLit ? .eye : .bodyDark)
        if tipLit {
            for (dx, dy) in [(-4, -7), (4, -7), (0, -11)] { c.dot(24 + dx, Int(top) + dy, .effectDim) }
        }

        // Head and visor, with a glint across the glass.
        c.shape(roundedRect(8, top, 32, 18, r: 7), fill: .body, light: .bodyLight, dark: .bodyDark)
        c.shape(roundedRect(11, top + 3, 26, 12, r: 5), fill: .visor, light: .visorLight, figure: false)
        c.dot(13, Int(top) + 5, .visorLight); c.dot(14, Int(top) + 4, .visorLight); c.dot(15, Int(top) + 4, .visorLight)

        // Eyes.
        let eyeY = Int(top) + 5
        drawEyes(&c, pose, tick: tick, y: eyeY)

        // Mouth, while talking.
        if pose == .answering {
            let open = [0, 1, 2, 1, 2, 3, 1, 0][tick % 8]
            if open > 0 {
                let w = 2 + open, x0 = 24 - w / 2
                for dy in 0..<min(open, 2) { for dx in 0..<w { c.dot(x0 + dx, eyeY + 7 + dy, .eye) } }
            }
        }

        c.outlineFigure()
        effects(&c, pose, tick: tick, top: Int(top))
        return c
    }

    static func drawEyes(_ c: inout Canvas, _ pose: Pose, tick: Int, y: Int) {
        let leftX = 16, rightX = 28
        /// A rounded eye: corners cut once it's big enough.
        func eye(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ ink: Ink = .eye, glint: Bool = false) {
            for dy in 0..<h {
                for dx in 0..<w {
                    let corner = w >= 4 && h >= 5 && (dx == 0 || dx == w - 1) && (dy == 0 || dy == h - 1)
                    if !corner { c.dot(x + dx, y + dy, ink) }
                }
            }
            if glint, w >= 4, h >= 5 { c.dot(x + w - 2, y + 1, .markGlow); c.dot(x + 1, y + h - 2, .visorLight) }
        }
        func pair(_ dx: Int = 0, _ dy: Int = 0, w: Int = 4, h: Int = 6, ink: Ink = .eye, glint: Bool = true) {
            let y0 = y + (6 - h) / 2 + dy
            eye(leftX + dx, y0, w, h, ink, glint: glint)
            eye(rightX + dx, y0, w, h, ink, glint: glint)
        }
        switch pose {
        case .paused:
            pair(0, 1, w: 5, h: 1, ink: .eyeDim, glint: false)
        case .greeting:
            // Happy: upturned arcs.
            for x0 in [leftX - 1, rightX - 1] {
                for (dx, dy) in [(0, 4), (0, 3), (1, 2), (2, 1), (3, 1), (4, 2), (5, 3), (5, 4), (1, 3), (4, 3)] {
                    c.dot(x0 + dx, y + dy, .eye)
                }
            }
        case .listening:
            pair(0, -1, w: 5, h: 7)
        case .thinking:
            let look = [(1, -1), (1, -1), (-1, -1), (-1, -1), (0, -1)][(tick / 6) % 5]
            pair(look.0, look.1, h: 5)
        case .idle, .answering:
            // A five-step blink every few seconds; now and then a glance.
            let blink = [6, 3, 1, 3, 6]
            let cycle = tick % 54
            let h = cycle < 5 ? blink[cycle] : 6
            let glanceCycle = tick % 120
            let glance = pose == .idle && glanceCycle > 70 && glanceCycle < 95 ? (glanceCycle < 82 ? -1 : 1) : 0
            pair(glance, 0, h: h, glint: h == 6)
        }
    }

    static func effects(_ c: inout Canvas, _ pose: Pose, tick: Int, top: Int) {
        switch pose {
        case .listening:
            // Rings coming in from the sides, toward the head.
            let stage = (tick / 3) % 3
            let mid = top + 10
            for ring in 0..<3 where ring >= stage {
                let off = 2 + (2 - ring) * 2
                for dy in -2...2 {
                    let bend = abs(dy) == 2 ? 1 : 0
                    c.dot(8 - off + bend, mid + dy, ring == stage ? .effect : .effectDim)
                    c.dot(39 + off - bend, mid + dy, ring == stage ? .effect : .effectDim)
                }
            }
        case .thinking:
            let shown = (tick / 4) % 4
            for i in 0..<shown { c.shape(roundedRect(Double(32 + i * 4), Double(top - 8 - i), 2.4, 2.4, r: 1.2), fill: .effect, figure: false) }
        case .paused:
            // Three z's drifting up and fading.
            for i in 0..<2 {
                let t = (tick / 2 + i * 9) % 18
                let x = 36 + t / 4, y = top - 2 - t
                guard y > 0 else { continue }
                let ink: Ink = t > 11 ? .effectDim : .effect
                let size = t > 8 ? 3 : 4
                for dx in 0..<size { c.dot(x + dx, y, ink); c.dot(x + dx, y + size - 1, ink) }
                for k in 1..<(size - 1) { c.dot(x + size - 1 - k, y + k, ink) }
            }
        default:
            break
        }
    }

    /// One frame as an image, one pixel per sprite pixel; draw it scaled by
    /// a whole number, without smoothing.
    public static func image(_ pose: Pose, tick: Int) -> CGImage? {
        let c = canvas(pose, tick: tick)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                guard let value = rgb[c[x: x, y: y]] else { continue }
                let i = (y * width + x) * 4
                bytes[i] = UInt8((value >> 16) & 0xFF); bytes[i + 1] = UInt8((value >> 8) & 0xFF)
                bytes[i + 2] = UInt8(value & 0xFF); bytes[i + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

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
