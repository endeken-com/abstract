import AppKit

/// Demo mode's scroll benchmark. `ABSTRACT_DEMO_SCROLL=<delay>,<seconds>`
/// waits, then scrolls the window's tallest scroll view toward the top and
/// back at 120 Hz, the way a trackpad does, and logs how often the main
/// thread missed a frame.
enum ScrollProbe {
    static func runIfRequested() {
        guard let spec = ProcessInfo.processInfo.environment["ABSTRACT_DEMO_SCROLL"] else { return }
        let parts = spec.split(separator: ",").compactMap { Double($0) }
        Task { await run(after: parts.first ?? 5, for: parts.count > 1 ? parts[1] : 6) }
    }

    private static func run(after delay: Double, for seconds: Double) async {
        // Where the chat sits while the agent streams: it should follow the end.
        for _ in 0..<Int(delay / 2) {
            try? await Task.sleep(for: .seconds(2))
            if let content = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })?.contentView,
               let scroll = scrollViews(in: content).max(by: { height($0) < height($1) }), let document = scroll.documentView {
                let clip = scroll.contentView.bounds
                log(String(format: "scroll probe: y %.0f, %.0f from the end of %.0f", clip.origin.y, document.frame.height - clip.maxY, document.frame.height))
            }
        }
        guard let content = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })?.contentView,
              let scroll = scrollViews(in: content).max(by: { height($0) < height($1) }), let document = scroll.documentView else {
            log("scroll probe: no scroll view")
            return
        }
        let clip = scroll.contentView
        log(String(format: "scroll probe: %@ in %@, y %.0f of %.0f, flipped %d", String(describing: type(of: scroll)),
                   String(describing: type(of: document)), clip.bounds.origin.y, document.frame.height, document.isFlipped ? 1 : 0))
        if ProcessInfo.processInfo.environment["ABSTRACT_DEMO_SCROLL_WHEEL"] != nil {
            await wheel(scroll, for: seconds)
            return
        }
        var turned = false
        // Points per step: 40 is a steady trackpad; a fling is hundreds.
        let speed = CGFloat(Double(ProcessInfo.processInfo.environment["ABSTRACT_DEMO_SCROLL_SPEED"] ?? "") ?? 40)
        let flinging = speed > 40
        var towardTop: CGFloat = document.isFlipped ? -speed : speed
        let start = CACurrentMediaTime()
        var last = start
        var gaps: [Double] = []
        var travelled: CGFloat = 0
        while CACurrentMediaTime() - start < seconds {
            let now = CACurrentMediaTime()
            gaps.append(now - last)
            last = now
            var dy = now - start < seconds / 2 ? towardTop : -towardTop
            if flinging {
                // Back and forth, end to end, as fast as it goes.
                let top = clip.bounds.origin.y <= 1, bottom = clip.bounds.maxY >= document.frame.height - 1
                if (top && towardTop < 0) || (bottom && towardTop > 0) { towardTop = -towardTop }
                dy = towardTop
            } else if !turned, dy != towardTop {
                turned = true
                log(String(format: "scroll probe: turning at y %.0f of %.0f", clip.bounds.origin.y, document.frame.height))
            }
            var origin = clip.bounds.origin
            let before = origin.y
            origin.y = min(max(0, origin.y + dy), max(0, document.frame.height - clip.bounds.height))
            clip.scroll(to: origin)
            scroll.reflectScrolledClipView(clip)
            travelled += abs(origin.y - before)
            try? await Task.sleep(for: .milliseconds(8))
        }
        let sorted = gaps.sorted()
        let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
        log(String(format: "scroll probe: %d frames, %d over 25ms, p95 %.1fms, max %.1fms, travelled %.0fpt of %.0fpt",
                   gaps.count, gaps.filter { $0 > 0.025 }.count, p95 * 1000, (sorted.last ?? 0) * 1000, travelled, document.frame.height))
    }

    /// Trackpad flings, as the scroll view gets them: a swipe (phase began,
    /// changed, ended) then momentum decaying, up and down, over and over,
    /// sent to the scroll view itself (nothing goes to the rest of the system).
    private static func wheel(_ scroll: NSScrollView, for seconds: Double) async {
        let start = CACurrentMediaTime()
        var last = start
        var gaps: [Double] = []
        var up = true
        var flings = 0
        func send(_ dy: Double, phase: Int64, momentum: Int64) {
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(dy), wheel2: 0, wheel3: 0) else { return }
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
            cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: dy)
            cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: dy)
            if let window = scroll.window {
                let center = scroll.convert(NSPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil)
                cg.location = CGPoint(x: window.frame.minX + center.x, y: (NSScreen.screens.first?.frame.height ?? 0) - (window.frame.minY + center.y))
            }
            if let event = NSEvent(cgEvent: cg) { scroll.scrollWheel(with: event) }
        }
        func frame() async {
            try? await Task.sleep(for: .milliseconds(8))
            let now = CACurrentMediaTime()
            gaps.append(now - last)
            if now - last > 0.2, let document = scroll.documentView as? TranscriptDocumentView {
                let y = scroll.contentView.bounds.midY
                log(String(format: "scroll probe: %.0fms at y %.0f: ", (now - last) * 1000, y) + (document.controller?.describe(around: y) ?? ""))
            }
            last = now
        }
        while CACurrentMediaTime() - start < seconds {
            let sign: Double = up ? 1 : -1
            // The swipe: a few big deltas.
            send(0, phase: 1, momentum: 0); await frame()
            for _ in 0..<6 { send(sign * 180, phase: 2, momentum: 0); await frame() }
            send(0, phase: 4, momentum: 0); await frame()
            // The momentum: decaying, as a hard fling does.
            var v = 260.0
            send(sign * v, phase: 0, momentum: 1); await frame()
            while v > 4 { v *= 0.95; send(sign * v, phase: 0, momentum: 2); await frame() }
            send(0, phase: 0, momentum: 3); await frame()
            flings += 1
            let clip = scroll.contentView.bounds
            let height = scroll.documentView?.frame.height ?? 0
            if up, clip.minY <= 1 { up = false } else if !up, clip.maxY >= height - 1 { up = true }
        }
        let sorted = gaps.sorted()
        let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
        log(String(format: "scroll probe (wheel): %d frames, %d flings, %d over 25ms, %d over 100ms, p95 %.1fms, max %.1fms, doc %.0fpt",
                   gaps.count, flings, gaps.filter { $0 > 0.025 }.count, gaps.filter { $0 > 0.1 }.count, p95 * 1000, (sorted.last ?? 0) * 1000,
                   scroll.documentView?.frame.height ?? 0))
    }

    private static func height(_ scroll: NSScrollView) -> CGFloat { scroll.documentView?.frame.height ?? 0 }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        // Not inside one: those are code blocks scrolling sideways.
        if let scroll = view as? NSScrollView { return [scroll] }
        return view.subviews.flatMap(scrollViews)
    }
}
