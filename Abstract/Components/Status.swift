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

/// A square turned 45° with softened corners: the shape of every status
/// mark, echoing Abstract's own mark.
struct RoundedDiamond: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height) / 2.squareRoot()
        let square = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        let turn = CGAffineTransform(translationX: rect.midX, y: rect.midY)
            .rotated(by: .pi / 4)
            .translatedBy(x: -rect.midX, y: -rect.midY)
        return Path(roundedRect: square, cornerRadius: side * 0.26, style: .continuous).applying(turn)
    }

    /// Outline length for a frame of `size`, for dashes that travel around it.
    static func perimeter(_ size: CGFloat) -> CGFloat { 4 * size / 2.squareRoot() * 0.94 }
}

/// Status as a small solid diamond. A working agent's breathes gently;
/// nothing glows or radiates. Always shown next to a word, never on its own.
struct StatusDot: View {
    let status: SessionStatus
    var size: CGFloat = 8

    var body: some View {
        Group {
            if status == .running {
                AnimatedDiamond(motion: .breathe, color: status.tint)
            } else {
                RoundedDiamond().fill(status.tint)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A rounded diamond whose loop runs in Core Animation. A SwiftUI
/// `repeatForever` re-runs the window's view graph every frame, for as long
/// as an agent works, and that starves scrolling and streaming; a layer
/// animation costs the main thread nothing.
struct AnimatedDiamond: NSViewRepresentable {
    enum Motion { case breathe, travel }
    let motion: Motion
    let color: Color
    /// The outline under a travelling stroke.
    var track: Color = .clear
    var lineWidth: CGFloat = 1.4

    func makeNSView(context: Context) -> DiamondLayerView { DiamondLayerView(motion: motion) }

    func updateNSView(_ view: DiamondLayerView, context: Context) {
        view.colors = (NSColor(color), NSColor(track))
        view.lineWidth = lineWidth
    }
}

final class DiamondLayerView: NSView {
    private let motion: AnimatedDiamond.Motion
    private let trackLayer = CAShapeLayer()
    private let markLayer = CAShapeLayer()
    var colors: (mark: NSColor, track: NSColor) = (.clear, .clear) { didSet { applyColors() } }
    var lineWidth: CGFloat = 1.4 { didSet { needsLayout = true } }

    init(motion: AnimatedDiamond.Motion) {
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
        let path = RoundedDiamond().path(in: bounds).cgPath
        for shape in [trackLayer, markLayer] {
            shape.frame = bounds
            shape.path = path
        }
        switch motion {
        case .breathe:
            trackLayer.isHidden = true
            markLayer.strokeColor = nil
        case .travel:
            let perimeter = RoundedDiamond.perimeter(min(bounds.width, bounds.height))
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
            loop.toValue = -RoundedDiamond.perimeter(min(bounds.width, bounds.height))
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
