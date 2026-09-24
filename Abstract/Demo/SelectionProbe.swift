import AppKit

/// Demo mode's selection check. `ABSTRACT_DEMO_SELECT=<delay>` waits, then
/// drags from the first text on screen in the transcript to a text a few
/// rows below it, the way a mouse does, with events sent to the text itself
/// (nothing goes to the rest of the system), and logs what it selected.
/// `ABSTRACT_DEMO_SELECT_FROM=margin|gap` starts in empty space instead;
/// `ABSTRACT_DEMO_SELECT_HOLD=1` drags past the list's bottom and holds.
/// `ABSTRACT_DEMO_SELECT_SHOT=<png>` saves the window after.
enum SelectionProbe {
    static func runIfRequested() {
        guard let delay = ProcessInfo.processInfo.environment["ABSTRACT_DEMO_SELECT"].flatMap(Double.init) else { return }
        Task {
            try? await Task.sleep(for: .seconds(delay))
            await run()
        }
    }

    private static func run() async {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }), let content = window.contentView,
              let document = find(TranscriptDocumentView.self, in: content).first, let scroll = document.enclosingScrollView,
              let selection = document.controller?.selection else {
            log("selection probe: no transcript")
            return
        }
        // Up from the end, where more than one text is in view.
        // A wheel turn, so the chat stops following its end.
        for _ in 0..<6 {
            if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 150, wheel2: 0, wheel3: 0), let wheel = NSEvent(cgEvent: cg) {
                scroll.scrollWheel(with: wheel)
            }
            try? await Task.sleep(for: .milliseconds(30))
        }
        try? await Task.sleep(for: .seconds(1))
        let visible = scroll.convert(scroll.bounds, to: nil)
        let texts = texts(in: document).filter { visible.insetBy(dx: 0, dy: 30).intersects($0.convert($0.bounds, to: nil)) }
            .sorted { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }
        log("selection probe: \(texts.count) texts on screen")
        guard texts.count >= 2, let first = texts.first else {
            save()
            return
        }
        let last = texts[min(texts.count - 1, 4)]
        // Only the parts on screen: the first may run up under the top edge.
        let a = first.convert(first.bounds, to: nil).intersection(visible.insetBy(dx: 0, dy: 20)), b = last.convert(last.bounds, to: nil)
        // From just inside the first text's top left (or the margin beside
        // it, or the gap above it) to the middle of the last one.
        let env = ProcessInfo.processInfo.environment
        let from = switch env["ABSTRACT_DEMO_SELECT_FROM"] {
        case "margin": CGPoint(x: a.minX - 40, y: a.maxY - 6)
        case "gap": CGPoint(x: a.minX + 6, y: a.maxY + 4)
        default: CGPoint(x: a.minX + 6, y: a.maxY - 6)
        }
        let hold = env["ABSTRACT_DEMO_SELECT_HOLD"] != nil
        let to = hold ? CGPoint(x: b.midX, y: visible.minY - 30) : CGPoint(x: b.midX, y: b.midY)
        log("selection probe: from \(from) in \(a), to \(to)")
        let hit = window.contentView?.superview?.hitTest(from)
        log("selection probe: pressing on \(hit.map { String(describing: type(of: $0)) } ?? "nothing"), key \(window.isKeyWindow)")
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        // Through the window, so it finds the view under the pointer as a real press does.
        guard let down = event(.leftMouseDown, from) else { return }
        window.sendEvent(down)
        log("selection probe: first responder \(window.firstResponder.map { String(describing: type(of: $0)) } ?? "none")")
        for step in 1...12 {
            let t = CGFloat(step) / 12
            if let drag = event(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)) {
                window.sendEvent(drag)
            }
            try? await Task.sleep(for: .milliseconds(16))
        }
        let y0 = scroll.contentView.bounds.origin.y
        if hold {
            try? await Task.sleep(for: .milliseconds(1500))
            log(String(format: "selection probe: held past the edge, scrolled %.0fpt", scroll.contentView.bounds.origin.y - y0))
        }
        if let up = event(.leftMouseUp, to) { window.sendEvent(up) }
        try? await Task.sleep(for: .milliseconds(300))
        let text = selection.selectedText() ?? ""
        log("selection probe: spanning \(selection.hasSpanningSelection), \(text.count) characters, \(text.components(separatedBy: "\n\n").count) pieces")
        log("selection probe: text <<\(text.prefix(600))>>")
        save()
    }

    private static func save() {
        if let path = ProcessInfo.processInfo.environment["ABSTRACT_DEMO_SELECT_SHOT"], let image = WindowCapture.image() {
            try? image.write(to: URL(fileURLWithPath: path))
            log("selection probe: shot \(path)")
        }
    }

    private static func texts(in view: NSView) -> [NSView] {
        if String(describing: type(of: view)).contains("NSTextInteractionView") { return [view] }
        return view.subviews.flatMap(texts)
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        if let match = view as? T { return [match] }
        return view.subviews.flatMap { find(type, in: $0) }
    }
}
