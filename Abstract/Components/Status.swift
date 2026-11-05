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
}

/// Status as a small solid hexagon; a working agent shows the working mark
/// instead. Always shown next to a word, never on its own.
struct StatusDot: View {
    let status: SessionStatus
    var size: CGFloat = 8

    var body: some View {
        Group {
            if status == .running {
                WorkingMark(color: status.tint)
            } else {
                RoundedHexagon().fill(status.tint)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The supplied Abstract symbol, traced as an outline while work is active.
/// Reduce Motion and inactive states show the complete, still outline.
struct WorkingMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var color: Color = .btAccent
    var active = true

    var body: some View {
        WorkingMarkLayers(color: color, animated: active && !reduceMotion)
            .accessibilityHidden(true)
    }
}

/// The loop runs in Core Animation. A SwiftUI `repeatForever` re-runs the
/// window's view graph every frame, for as long as an agent works, and that
/// starves scrolling and streaming; a layer animation costs the main thread nothing.
private struct WorkingMarkLayers: NSViewRepresentable {
    let color: Color
    let animated: Bool

    func makeNSView(context: Context) -> WorkingMarkView { WorkingMarkView() }

    func updateNSView(_ view: WorkingMarkView, context: Context) {
        view.color = NSColor(color)
        view.animated = animated
    }
}

final class WorkingMarkView: NSView {
    private static let period: CFTimeInterval = 1.7
    private let track = CAShapeLayer()
    private let trace = CAShapeLayer()
    var color: NSColor = .clear { didSet { applyColor() } }
    var animated = false { didSet { if animated != oldValue { updateAnimation() } } }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        for shape in [track, trace] {
            shape.fillColor = NSColor.clear.cgColor
            shape.lineCap = .round
            shape.lineJoin = .round
            layer?.addSublayer(shape)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let lineWidth = max(0.8, min(bounds.width, bounds.height) * 0.11)
        let drawingRect = bounds.insetBy(dx: lineWidth / 2 + 0.3, dy: lineWidth / 2 + 0.3)
        // SwiftUI's SVG path uses a downward Y axis; the AppKit layer uses upward Y.
        var flip = CGAffineTransform(translationX: 0, y: bounds.height).scaledBy(x: 1, y: -1)
        let path = AbstractMark().path(in: drawingRect).cgPath.copy(using: &flip)
        for shape in [track, trace] {
            shape.frame = bounds
            shape.path = path
            shape.lineWidth = lineWidth
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
        applyColor()
    }

    private func applyColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            track.strokeColor = color.withAlphaComponent(0.22).cgColor
            trace.strokeColor = color.cgColor
            CATransaction.commit()
        }
    }

    private func updateAnimation() {
        guard animated, window != nil, bounds.width > 0 else {
            trace.removeAnimation(forKey: "outline")
            trace.strokeEnd = 1
            return
        }
        guard trace.animation(forKey: "outline") == nil else { return }
        // Share the media clock so repeated marks trace in sync without SwiftUI redraws.
        let draw = CAKeyframeAnimation(keyPath: "strokeEnd")
        draw.values = [0, 1, 1, 0]
        draw.keyTimes = [0, 0.52, 0.64, 1]
        draw.timingFunctions = (0..<3).map { _ in CAMediaTimingFunction(name: .easeInEaseOut) }
        draw.duration = Self.period
        draw.repeatCount = .infinity
        draw.timeOffset = CACurrentMediaTime().truncatingRemainder(dividingBy: Self.period)
        trace.add(draw, forKey: "outline")
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
