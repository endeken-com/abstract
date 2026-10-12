import AppKit

/// Demo mode's find check. `ABSTRACT_DEMO_FIND=<delay>,<words>` waits, then
/// does what ⌘F, typing the words and Return do, and logs the count, where
/// the transcript went and what it marked; then Escape, and where the
/// keyboard went. Use it with `ABSTRACT_DEMO_HISTORY`.
/// `ABSTRACT_DEMO_FIND_SHOT=<png>` saves the window with the match showing.
enum FindProbe {
    static func runIfRequested(_ model: AppModel) {
        guard let spec = ProcessInfo.processInfo.environment["ABSTRACT_DEMO_FIND"] else { return }
        let parts = spec.split(separator: ",", maxSplits: 1).map(String.init)
        guard parts.count == 2, let delay = Double(parts[0]) else { return }
        Task {
            try? await Task.sleep(for: .seconds(delay))
            await run(model, words: parts[1])
        }
    }

    private static func run(_ model: AppModel, words: String) async {
        // Nothing else may take ⌘F or ⌘G.
        for item in items(NSApp.mainMenu) where ["f", "g"].contains(item.keyEquivalent.lowercased()) {
            log("find probe: menu “\(item.title)” \(item.keyEquivalentModifierMask.contains(.shift) ? "⇧" : "")⌘\(item.keyEquivalent) in \(item.menu?.title ?? "?")")
        }
        guard let id = model.chatInFront else { log("find probe: no chat in front"); return }
        let find = model.feed(id).find
        // What ⌘F does.
        find.open()
        try? await Task.sleep(for: .milliseconds(500))
        log("find probe: open \(find.isOpen), typing in \(responder())")
        find.query = words
        try? await Task.sleep(for: .milliseconds(300))
        log("find probe: “\(words)” \(find.state.label)")
        // Return.
        find.next()
        try? await Task.sleep(for: .seconds(1))
        log("find probe: after Return \(find.state.label), " + (document()?.controller?.describeFind() ?? "no transcript"))
        if let path = ProcessInfo.processInfo.environment["ABSTRACT_DEMO_FIND_SHOT"], let image = WindowCapture.image() {
            try? image.write(to: URL(fileURLWithPath: path))
            log("find probe: shot \(path)")
        }
        // Escape.
        find.close()
        try? await Task.sleep(for: .milliseconds(500))
        log("find probe: after Escape open \(find.isOpen), keyboard in \(responder())")
    }

    private static func responder() -> String {
        NSApp.windows.first { $0.isVisible && $0.contentView != nil }?.firstResponder.map { String(describing: type(of: $0)) } ?? "nothing"
    }

    private static func document() -> TranscriptDocumentView? {
        func find(_ view: NSView) -> TranscriptDocumentView? {
            if let match = view as? TranscriptDocumentView { return match }
            return view.subviews.lazy.compactMap(find).first
        }
        return NSApp.windows.first { $0.isVisible && $0.contentView != nil }?.contentView.flatMap(find)
    }

    private static func items(_ menu: NSMenu?) -> [NSMenuItem] {
        (menu?.items ?? []).flatMap { [$0] + items($0.submenu) }
    }
}
