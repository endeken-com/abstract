import SwiftUI
import AbstractCore

extension SessionStatus {
    var label: String {
        switch self {
        case .created: "Ready"
        case .provisioning: "Setting up"
        case .running: "Working"
        case .waitingInput: "Needs you"
        case .idle: "Your turn"
        case .finished: "Done"
        case .errored: "Error"
        }
    }

    var tint: Color {
        switch self {
        case .running, .provisioning: .btAccent
        case .waitingInput: .btAttention
        case .idle: .btTextSecondary
        case .finished: .btTextTertiary
        case .errored: .btRemoved
        case .created: .btTextTertiary
        }
    }
}

enum ActivityInk {
    static func colors(for colorScheme: ColorScheme) -> [Color] {
        colorScheme == .dark
            ? [Color(red: 0.86, green: 0.85, blue: 0.87),
               Color(red: 0.94, green: 0.84, blue: 0.80),
               Color(red: 0.91, green: 0.78, blue: 0.83),
               Color(red: 0.82, green: 0.79, blue: 0.91)]
            : [Color(red: 0.19, green: 0.18, blue: 0.20),
               Color(red: 0.36, green: 0.27, blue: 0.25),
               Color(red: 0.35, green: 0.24, blue: 0.30),
               Color(red: 0.27, green: 0.25, blue: 0.37)]
    }
}

/// The text stays in SwiftUI for layout and accessibility; Core Animation
/// moves overlapping pastel color fields without rebuilding a chat row on every frame.
struct ActivityStatusText: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let text: String
    let font: Font
    var active = true
    var fallback: Color = .btTextSecondary

    var body: some View {
        if active, contrast != .increased {
            Text(text)
                .font(font)
                .foregroundStyle(.clear)
                .overlay {
                    ActivityMesh(colors: ActivityInk.colors(for: colorScheme), animated: !reduceMotion)
                        .mask { Text(text).font(font) }
                        .accessibilityHidden(true)
                }
        } else {
            Text(text).font(font).foregroundStyle(contrast == .increased ? Color.btText : fallback)
        }
    }
}

private struct ActivityMesh: NSViewRepresentable {
    let colors: [Color]
    let animated: Bool

    func makeNSView(context: Context) -> ActivityMeshView { ActivityMeshView() }

    func updateNSView(_ view: ActivityMeshView, context: Context) {
        view.colors = colors.map(NSColor.init)
        view.animated = animated
    }
}

private final class ActivityMeshView: NSView {
    private let base = CALayer()
    private let fields = (0..<3).map { _ in CAGradientLayer() }
    private var laidOutSize: CGSize = .zero
    var colors: [NSColor] = [] { didSet { applyColors() } }
    var animated = false { didSet { updateAnimation() } }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(base)
        for field in fields {
            field.type = .radial
            field.startPoint = CGPoint(x: 0.5, y: 0.5)
            field.endPoint = CGPoint(x: 1, y: 0.5)
            field.locations = [0, 1]
            layer?.addSublayer(field)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        guard bounds.size != laidOutSize else { return }
        laidOutSize = bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        base.frame = bounds
        let fieldSize = CGSize(width: max(bounds.width * 0.86, 48),
                               height: max(bounds.height * 3.4, 48))
        for (index, field) in fields.enumerated() {
            field.bounds = CGRect(origin: .zero, size: fieldSize)
            field.position = position(for: index, step: 0)
            field.removeAnimation(forKey: "drift")
        }
        CATransaction.commit()
        updateAnimation()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAnimation()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        guard colors.count == 4 else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            base.backgroundColor = colors[0].cgColor
            for (index, field) in fields.enumerated() {
                field.colors = [colors[index + 1].withAlphaComponent(0.88).cgColor,
                                colors[index + 1].withAlphaComponent(0).cgColor]
            }
            CATransaction.commit()
        }
    }

    private func updateAnimation() {
        guard animated, window != nil else {
            fields.forEach { $0.removeAnimation(forKey: "drift") }
            return
        }
        guard bounds.width > 0, bounds.height > 0 else { return }
        for (index, field) in fields.enumerated() where field.animation(forKey: "drift") == nil {
            let drift = CAKeyframeAnimation(keyPath: "position")
            drift.values = (0...4).map { NSValue(point: position(for: index, step: $0)) }
            drift.keyTimes = [0, 0.25, 0.5, 0.75, 1]
            drift.timingFunctions = (0..<4).map { _ in CAMediaTimingFunction(name: .easeInEaseOut) }
            drift.duration = [6.4, 7.7, 8.9][index]
            drift.repeatCount = .infinity
            field.add(drift, forKey: "drift")
        }
    }

    private func position(for index: Int, step: Int) -> CGPoint {
        let paths: [[CGPoint]] = [
            [CGPoint(x: 0.13, y: 0.42), CGPoint(x: 0.33, y: 0.65),
             CGPoint(x: 0.48, y: 0.36), CGPoint(x: 0.24, y: 0.25), CGPoint(x: 0.13, y: 0.42)],
            [CGPoint(x: 0.51, y: 0.62), CGPoint(x: 0.70, y: 0.32),
             CGPoint(x: 0.40, y: 0.52), CGPoint(x: 0.58, y: 0.77), CGPoint(x: 0.51, y: 0.62)],
            [CGPoint(x: 0.86, y: 0.43), CGPoint(x: 0.65, y: 0.73),
             CGPoint(x: 0.79, y: 0.30), CGPoint(x: 0.96, y: 0.60), CGPoint(x: 0.86, y: 0.43)],
        ]
        let point = paths[index][step]
        return CGPoint(x: bounds.width * point.x, y: bounds.height * point.y)
    }
}

/// A softly rounded hexagon, echoing the six-sided Abstract mark.
struct RoundedHexagon: Shape {
    func path(in rect: CGRect) -> Path {
        let vertices: [CGPoint] = [
            CGPoint(x: rect.maxX, y: rect.midY),
            CGPoint(x: rect.minX + rect.width * 0.75, y: rect.minY + rect.height * 0.067),
            CGPoint(x: rect.minX + rect.width * 0.25, y: rect.minY + rect.height * 0.067),
            CGPoint(x: rect.minX, y: rect.midY),
            CGPoint(x: rect.minX + rect.width * 0.25, y: rect.minY + rect.height * 0.933),
            CGPoint(x: rect.minX + rect.width * 0.75, y: rect.minY + rect.height * 0.933),
        ]
        func toward(_ from: CGPoint, _ to: CGPoint) -> CGPoint {
            CGPoint(x: from.x + (to.x - from.x) * 0.14,
                    y: from.y + (to.y - from.y) * 0.14)
        }
        var path = Path()
        for index in vertices.indices {
            let corner = vertices[index]
            let entry = toward(corner, vertices[(index + 5) % 6])
            let exit = toward(corner, vertices[(index + 1) % 6])
            if index == 0 { path.move(to: entry) } else { path.addLine(to: entry) }
            path.addQuadCurve(to: exit, control: corner)
        }
        path.closeSubpath()
        return path
    }

    /// Outline length for a frame of `size`, for dashes that travel around it.
    static func perimeter(_ size: CGFloat) -> CGFloat { 3 * size * 0.94 }
}

/// Status as a small solid hexagon. A working agent's mark breathes gently;
/// nothing glows or radiates. Always shown next to a word, never on its own.
struct StatusDot: View {
    let status: SessionStatus
    var size: CGFloat = 8

    var body: some View {
        Group {
            if status == .running {
                AnimatedHexagon(motion: .breathe, color: status.tint)
            } else {
                RoundedHexagon().fill(status.tint)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A rounded hexagon whose loop runs in Core Animation. A SwiftUI
/// `repeatForever` re-runs the window's view graph every frame, for as long
/// as an agent works, and that starves scrolling and streaming; a layer
/// animation costs the main thread nothing.
struct AnimatedHexagon: NSViewRepresentable {
    enum Motion { case breathe, travel }
    let motion: Motion
    let color: Color
    /// The outline under a travelling stroke.
    var track: Color = .clear
    var lineWidth: CGFloat = 1.4

    func makeNSView(context: Context) -> HexagonLayerView { HexagonLayerView(motion: motion) }

    func updateNSView(_ view: HexagonLayerView, context: Context) {
        view.colors = (NSColor(color), NSColor(track))
        view.lineWidth = lineWidth
    }
}

final class HexagonLayerView: NSView {
    private let motion: AnimatedHexagon.Motion
    private let trackLayer = CAShapeLayer()
    private let markLayer = CAShapeLayer()
    var colors: (mark: NSColor, track: NSColor) = (.clear, .clear) { didSet { applyColors() } }
    var lineWidth: CGFloat = 1.4 { didSet { needsLayout = true } }

    init(motion: AnimatedHexagon.Motion) {
        self.motion = motion
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(trackLayer)
        layer?.addSublayer(markLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let path = RoundedHexagon().path(in: bounds).cgPath
        for shape in [trackLayer, markLayer] {
            shape.frame = bounds
            shape.path = path
        }
        switch motion {
        case .breathe:
            trackLayer.isHidden = true
            markLayer.strokeColor = nil
        case .travel:
            let perimeter = RoundedHexagon.perimeter(min(bounds.width, bounds.height))
            for shape in [trackLayer, markLayer] {
                shape.fillColor = nil
                shape.lineWidth = lineWidth
            }
            markLayer.lineCap = .round
            markLayer.lineDashPattern = [perimeter * 0.3, perimeter * 0.7].map { NSNumber(value: Double($0)) }
        }
        applyColors()
        CATransaction.commit()
        animate()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { animate() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            switch motion {
            case .breathe:
                markLayer.fillColor = colors.mark.cgColor
            case .travel:
                trackLayer.strokeColor = colors.track.cgColor
                markLayer.strokeColor = colors.mark.cgColor
            }
        }
    }

    private func animate() {
        guard bounds.width > 0, markLayer.animation(forKey: "loop") == nil else { return }
        let loop: CABasicAnimation
        switch motion {
        case .breathe:
            loop = CABasicAnimation(keyPath: "opacity")
            loop.fromValue = 1
            loop.toValue = 0.35
            loop.autoreverses = true
            loop.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        case .travel:
            loop = CABasicAnimation(keyPath: "lineDashPhase")
            loop.fromValue = 0
            loop.toValue = -RoundedHexagon.perimeter(min(bounds.width, bounds.height))
        }
        loop.duration = 1.1
        loop.repeatCount = .infinity
        markLayer.add(loop, forKey: "loop")
    }
}

/// Dot plus word, as plain text. No capsule, so it sits cleanly anywhere,
/// including next to native controls.
struct StatusBadge: View {
    let status: SessionStatus

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(status: status, size: 6)
            Text(status.label)
        }
        .font(.btCaptionMedium)
        .foregroundStyle(status == .waitingInput || status == .errored ? status.tint : Color.btTextSecondary)
    }
}
