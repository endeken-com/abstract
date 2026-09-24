import AppKit
import ObjectiveC

/// Every scroll bar in Abstract as a slim rounded thumb with no track, to
/// match the chat's hairline indicator. SwiftUI's scroll views, lists,
/// forms and text editors are all `NSScrollView`s underneath; each gets this
/// scroller the first time it lays out.
final class ThinScroller: NSScroller {
    static let width: CGFloat = 8
    private static let thumb: CGFloat = 4
    private static let wideThumb: CGFloat = 6

    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    private var tracking: NSTrackingArea?

    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat {
        width
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override func drawKnob() {
        let knob = rect(for: .knob)
        guard knob.width > 0, knob.height > 0 else { return }
        let vertical = bounds.height >= bounds.width
        let thickness = hovering || hitPart == .knob ? Self.wideThumb : Self.thumb
        let inset: CGFloat = 1.5
        let shape = vertical
            ? NSRect(x: bounds.maxX - thickness - inset, y: knob.minY + inset, width: thickness, height: knob.height - inset * 2)
            : NSRect(x: knob.minX + inset, y: bounds.maxY - thickness - inset, width: knob.width - inset * 2, height: thickness)
        NSColor.labelColor.withAlphaComponent(hovering ? 0.42 : 0.28).setFill()
        NSBezierPath(roundedRect: shape, xRadius: thickness / 2, yRadius: thickness / 2).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    /// Swaps every scroll view's scrollers for thin ones as it lays out. Call once, at launch.
    static func install() {
        guard let original = class_getInstanceMethod(NSScrollView.self, #selector(NSScrollView.tile)),
              let thin = class_getInstanceMethod(NSScrollView.self, #selector(NSScrollView.bt_thinTile)) else { return }
        method_exchangeImplementations(original, thin)
    }
}

extension NSScrollView {
    /// Runs as `tile`, once `ThinScroller.install()` has swapped them; the
    /// call inside is the original `tile`.
    @objc fileprivate func bt_thinTile() {
        if hasVerticalScroller, !(verticalScroller is ThinScroller) {
            let scroller = ThinScroller()
            scroller.scrollerStyle = scrollerStyle
            verticalScroller = scroller
        }
        if hasHorizontalScroller, !(horizontalScroller is ThinScroller) {
            let scroller = ThinScroller()
            scroller.scrollerStyle = scrollerStyle
            horizontalScroller = scroller
        }
        bt_thinTile()
    }
}
