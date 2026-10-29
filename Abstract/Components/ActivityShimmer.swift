import SwiftUI
import AbstractCore

extension SessionStatus {
    /// Whether its label is working status text, which shimmers.
    var isWorking: Bool { self == .running || self == .provisioning }
}

/// Working status text: a soft highlight sweeps across it while the work
/// runs, after Paseo's running-tool shimmer (Apache-2.0, Copyright (c)
/// 2025-present Mohamed Boudra). Reduce Motion keeps it still; Increased
/// Contrast keeps it solid.
struct ActivityStatusText: View {
    @Environment(\.colorSchemeContrast) private var contrast
    let text: String
    let font: Font
    var active = true
    var fallback: Color = .btTextSecondary

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(contrast == .increased ? Color.btText : fallback)
            .modifier(Shimmer(active: active))
    }
}

/// Sweeps a highlight across any label while `active`. The text stays in
/// SwiftUI for layout and accessibility; the sweep is a Core Animation loop,
/// so a working chat doesn't rebuild its row on every frame.
struct Shimmer: ViewModifier {
    let active: Bool
    var highlight: Color = .btText
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        // One branch for both states, so the label keeps its identity when work stops.
        let sweeping = active && !reduceMotion && contrast != .increased
        content
            .opacity(sweeping ? 0.72 : 1)
            .overlay {
                if sweeping {
                    ShimmerBand(color: highlight)
                        .mask { content }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }
}

private struct ShimmerBand: NSViewRepresentable {
    let color: Color

    func makeNSView(context: Context) -> ShimmerBandView { ShimmerBandView() }

    func updateNSView(_ view: ShimmerBandView, context: Context) {
        view.color = NSColor(color)
    }
}

private final class ShimmerBandView: NSView {
    private let band = CAGradientLayer()
    private var laidOutSize: CGSize = .zero
    var color: NSColor = .clear { didSet { applyColor() } }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        band.locations = [0, 0.5, 1]
        layer?.addSublayer(band)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        guard bounds.size != laidOutSize else { return }
        laidOutSize = bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        band.frame = CGRect(x: 0, y: 0, width: bandWidth, height: bounds.height)
        band.position = CGPoint(x: -bandWidth / 2, y: bounds.midY)
        CATransaction.commit()
        band.removeAnimation(forKey: "sweep")
        startSweep()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        startSweep()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColor()
    }

    private var bandWidth: CGFloat { min(max(42, bounds.width * 0.22), 120) }

    private func applyColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            band.colors = [color.withAlphaComponent(0).cgColor, color.cgColor, color.withAlphaComponent(0).cgColor]
            CATransaction.commit()
        }
    }

    /// Longer labels sweep slower, but never sluggishly.
    private func startSweep() {
        guard window != nil else {
            band.removeAnimation(forKey: "sweep")
            return
        }
        guard bounds.width > 0, band.animation(forKey: "sweep") == nil else { return }
        let travel = bounds.width + bandWidth
        let sweep = CABasicAnimation(keyPath: "position.x")
        sweep.fromValue = -bandWidth / 2
        sweep.toValue = bounds.width + bandWidth / 2
        sweep.duration = min(max(travel / 150, 1.1), 2.3)
        sweep.repeatCount = .infinity
        band.add(sweep, forKey: "sweep")
    }
}
