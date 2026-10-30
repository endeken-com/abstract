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

/// The one working mark: three small solid hexagons, a fragment of
/// honeycomb, lit one after another round the cluster. No blur, no glow;
/// with Reduce Motion, or once the work is done, all three hold still.
/// Every mark on screen shares the same clock, so they step together.
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
    private static let period: CFTimeInterval = 1.2
    /// Left, upper right, lower right: the order they light in.
    private let cells = (0..<3).map { _ in CAShapeLayer() }
    var color: NSColor = .clear { didSet { applyColor() } }
    var animated = false { didSet { if animated != oldValue { updateAnimation() } } }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        cells.forEach { layer?.addSublayer($0) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (cell, rect) in zip(cells, Self.cells(in: bounds)) {
            cell.frame = bounds
            cell.path = RoundedHexagon().path(in: rect).cgPath
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

    /// Three flat-topped hexagons round a shared corner, a hairline apart,
    /// centred in `rect`. Each comes back as the square its hexagon fills.
    static func cells(in rect: CGRect) -> [CGRect] {
        // Radius r, gap g: the cluster is 3.5r + 0.87g wide and 3.46r + g tall.
        let gapRatio: CGFloat = 0.22
        let radius = min(rect.width / (3.5 + 0.866 * gapRatio), rect.height / (3.464 + gapRatio))
        let reach = radius * (1 + gapRatio / 3.squareRoot())
        let corner = CGPoint(x: rect.midX + reach / 4, y: rect.midY)
        return [CGPoint(x: -reach, y: 0),
                CGPoint(x: reach / 2, y: reach * 0.866),
                CGPoint(x: reach / 2, y: -reach * 0.866)].map {
            CGRect(x: corner.x + $0.x - radius, y: corner.y + $0.y - radius, width: radius * 2, height: radius * 2)
        }
    }

    private func applyColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            cells.forEach { $0.fillColor = color.cgColor }
            CATransaction.commit()
        }
    }

    private func updateAnimation() {
        guard animated, window != nil, bounds.width > 0 else {
            if !animated { cells.forEach { $0.removeAnimation(forKey: "step") } }
            return
        }
        // Phase from the media clock, so every mark lights the same cell at once.
        let now = CACurrentMediaTime().truncatingRemainder(dividingBy: Self.period)
        for (index, cell) in cells.enumerated() where cell.animation(forKey: "step") == nil {
            let step = CAKeyframeAnimation(keyPath: "opacity")
            step.values = [0.25, 1, 0.25, 0.25]
            step.keyTimes = [0, 0.2, 0.55, 1]
            step.timingFunctions = (0..<3).map { _ in CAMediaTimingFunction(name: .easeInEaseOut) }
            step.duration = Self.period
            step.repeatCount = .infinity
            step.timeOffset = now + Self.period * Double(3 - index) / 3
            cell.add(step, forKey: "step")
        }
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
