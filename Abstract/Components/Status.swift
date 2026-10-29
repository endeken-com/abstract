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
