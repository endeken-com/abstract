import AppKit
import AbstractCore

/// Demo mode's Search in Files check. `ABSTRACT_DEMO_FILESEARCH=<delay>,<words>`
/// waits, then does what ⇧⌘F and typing the words do in the first chat, logs
/// what was found, then does what ⌘G does and logs what the editor selected.
/// `ABSTRACT_DEMO_FILESEARCH_SHOT=<png>` saves the window at each step
/// (`-results` and `-opened` before the extension).
enum FileSearchProbe {
    static func runIfRequested(_ model: AppModel) {
        guard let spec = ProcessInfo.processInfo.environment["ABSTRACT_DEMO_FILESEARCH"] else { return }
        let parts = spec.split(separator: ",", maxSplits: 1).map(String.init)
        guard parts.count == 2, let delay = Double(parts[0]) else { return }
        Task {
            try? await Task.sleep(for: .seconds(delay))
            await run(model, words: parts[1])
        }
    }

    private static func run(_ model: AppModel, words: String) async {
        for item in items(NSApp.mainMenu) where ["f", "g"].contains(item.keyEquivalent.lowercased()) {
            log("file search probe: menu “\(item.title)” \(item.keyEquivalentModifierMask.contains(.shift) ? "⇧" : "")⌘\(item.keyEquivalent)")
        }
        if model.selectedSessionId == nil, let first = model.sessions.first { model.open(first.id) }
        guard let id = model.selectedSessionId else { log("file search probe: no chat"); return }
        try? await Task.sleep(for: .seconds(1))
        // What ⇧⌘F does.
        model.searchInFiles(id)
        try? await Task.sleep(for: .milliseconds(600))
        let files = FilesPaneState.shared.session(id)
        log("file search probe: files showing \(model.layout(for: id).isShowing(.files)), mode \(files.mode), typing in \(responder())")
        files.contents.query = words
        for _ in 0..<40 where files.contents.searched != words || files.contents.phase == .searching {
            try? await Task.sleep(for: .milliseconds(250))
        }
        log("file search probe: “\(words)” \(files.contents.phase) — \(files.contents.summary)")
        for match in files.contents.results.matches.prefix(8) {
            log("file search probe:   \(match.path):\(match.line):\(match.column) “\(match.preview)” \(match.highlights)")
        }
        shot("-results")
        // What ⌘G does.
        log("file search probe: ⌘G steps the files search: \(model.fileSearchInFront == id)")
        model.stepFileSearch(1)
        try? await Task.sleep(for: .seconds(1.5))
        log("file search probe: tab \(String(describing: model.mainTabs.active?.kind)), editor selected “\(selection() ?? "nothing")”, keyboard in \(responder())")
        shot("-opened")
    }

    private static func shot(_ suffix: String) {
        guard let path = ProcessInfo.processInfo.environment["ABSTRACT_DEMO_FILESEARCH_SHOT"], let image = WindowCapture.image() else { return }
        let url = URL(fileURLWithPath: path)
        let out = url.deletingPathExtension().path + suffix + "." + url.pathExtension
        try? image.write(to: URL(fileURLWithPath: out))
        log("file search probe: shot \(out)")
    }

    private static func responder() -> String {
        NSApp.windows.first { $0.isVisible && $0.contentView != nil }?.firstResponder.map { String(describing: type(of: $0)) } ?? "nothing"
    }

    private static func selection() -> String? {
        guard let text = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })?.firstResponder as? NSTextView else { return nil }
        return (text.string as NSString).substring(with: text.selectedRange())
    }

    private static func items(_ menu: NSMenu?) -> [NSMenuItem] {
        (menu?.items ?? []).flatMap { [$0] + items($0.submenu) }
    }
}
