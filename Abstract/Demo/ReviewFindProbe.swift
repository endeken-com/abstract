import AppKit
import SwiftUI
import SwiftTerm
import AbstractCore

/// Demo mode's ⌘F check for the Review tab, the file editor and the
/// terminal. `ABSTRACT_DEMO_REVIEWFIND=<delay>,<word>` waits, writes a long
/// file into the first chat's worktree with the word only on one late line
/// (so the review starts it collapsed), then does what ⌘F, typing the word,
/// Return, the line filter and Escape do in the Review tab; then ⌘F, ⌘G and
/// ⌥⌘F with that file open and the keyboard elsewhere; then ⌘F with the
/// keyboard in a terminal. `ABSTRACT_DEMO_REVIEWFIND_SHOT=<png>` saves the
/// window at each step (`-unified`, `-split`, `-editor` before the extension).
enum ReviewFindProbe {
    static func runIfRequested(_ model: AppModel) {
        guard let spec = ProcessInfo.processInfo.environment["ABSTRACT_DEMO_REVIEWFIND"] else { return }
        let parts = spec.split(separator: ",", maxSplits: 1).map(String.init)
        guard parts.count == 2, let delay = Double(parts[0]) else { return }
        Task {
            try? await Task.sleep(for: .seconds(delay))
            await run(model, word: parts[1])
        }
    }

    private static let file = "notes/probe-long.txt"

    private static func run(_ model: AppModel, word: String) async {
        for item in items(NSApp.mainMenu) where ["f", "g", "e"].contains(item.keyEquivalent.lowercased())
            && item.keyEquivalentModifierMask.contains(.command) {
            log("review find probe: menu “\(item.title)” \(keys(item)) in \(item.menu?.title ?? "?")")
        }
        guard let session = model.sessions.first(where: { $0.worktreePath != nil }), let root = session.worktreePath else {
            log("review find probe: no chat with a worktree"); return
        }
        let id = session.id
        model.open(id)
        let lines = (1...900).map { $0 == 850 ? "line \($0) mentions \(word) once" : "line \($0)" }
        try? FileManager.default.createDirectory(atPath: root + "/notes", withIntermediateDirectories: true)
        try? (lines.joined(separator: "\n") + "\n").write(toFile: root + "/" + file, atomically: true, encoding: .utf8)
        _ = try? await LocalExecutor.shared.run("git", ["add", "-N", file], cwd: root)

        // The Review tab, with the long file read.
        model.openDiffTab(in: id)
        let review = ReviewStore.shared.review(id)
        for _ in 0..<40 where !review.files.contains(where: { $0.path == file }) {
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard let long = review.files.first(where: { $0.path == file }) else { log("review find probe: the long file never showed"); return }
        log("review find probe: \(review.files.count) files; \(file) open \(review.isExpanded(long))")

        // ⌘F, then typing.
        model.performFind(.find)
        try? await Task.sleep(for: .milliseconds(500))
        log("review find probe: ⌘F → \(String(describing: model.findFront.target(for: .find))), bar open \(review.find.isOpen), typing in \(responder())")
        review.find.query = word
        log("review find probe: “\(word)” \(review.find.state.label)")
        // Return.
        review.find.next()
        try? await Task.sleep(for: .seconds(1.2))
        let match = review.find.state.currentMatch
        log("review find probe: after Return \(review.find.state.label), at \(match?.path ?? "-"):\(match?.newLine ?? 0), file open \(review.isExpanded(long))")
        log("review find probe: marked “\(marked(review, long))”")
        shot("-unified")
        // Side by side needs the room the side panel takes.
        model.togglePanel(.side, in: id)
        UserDefaults.standard.set("split", forKey: "diff.layout")
        try? await Task.sleep(for: .milliseconds(500))
        model.performFind(.next)
        try? await Task.sleep(for: .seconds(1.2))
        shot("-split")
        UserDefaults.standard.set("unified", forKey: "diff.layout")
        model.togglePanel(.side, in: id)
        // Only removed lines: the word is on an added one.
        review.find.options.lines = .removed
        log("review find probe: removed lines only \(review.find.state.label)")
        review.find.options.lines = .all
        review.find.options.caseSensitive = true
        review.find.query = word.uppercased()
        log("review find probe: matching case “\(word.uppercased())” \(review.find.state.label)")
        review.find.options.caseSensitive = false
        // Escape.
        review.find.close()
        try? await Task.sleep(for: .milliseconds(300))
        log("review find probe: after Escape open \(review.find.isOpen), keyboard in \(responder())")

        // The file, with the keyboard elsewhere.
        model.openFileTab(file, in: id)
        try? await Task.sleep(for: .seconds(1.5))
        let window = NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
        window?.makeFirstResponder(nil)
        model.performFind(.find)
        try? await Task.sleep(for: .milliseconds(500))
        let text = model.activeFileDocument?.textView
        log("review find probe: file ⌘F → \(String(describing: model.findFront.target(for: .find))), find bar \(text?.enclosingScrollView?.isFindBarVisible == true), typing in \(responder())")
        // Typing in the find bar, then ⌘G.
        if let field = window?.firstResponder as? NSTextView, field !== text {
            field.selectAll(nil)
            field.insertText(word, replacementRange: field.selectedRange())
        }
        try? await Task.sleep(for: .milliseconds(300))
        model.performFind(.next)
        try? await Task.sleep(for: .milliseconds(500))
        if let text { log("review find probe: file ⌘G selected “\((text.string as NSString).substring(with: text.selectedRange()))”") }
        model.performFind(.replace)
        try? await Task.sleep(for: .milliseconds(500))
        log("review find probe: file ⌥⌘F find bar \(text?.enclosingScrollView?.isFindBarVisible == true), editable \(text?.isEditable == true)")
        shot("-editor")

        // The terminal with the keyboard.
        model.newTerminal(in: id)
        try? await Task.sleep(for: .seconds(2))
        guard let terminal = window?.contentView.flatMap(find(TerminalView.self)) else { log("review find probe: no terminal"); return }
        window?.makeFirstResponder(terminal)
        log("review find probe: terminal ⌘F → \(String(describing: model.findFront.target(for: .find)))")
        model.performFind(.find)
        try? await Task.sleep(for: .milliseconds(500))
        let bar = terminal.subviews.first { String(describing: type(of: $0)).contains("FindBar") }
        log("review find probe: terminal find bar \(bar.map { !$0.isHidden } ?? false), typing in \(responder())")
        try? FileManager.default.removeItem(atPath: root + "/notes")
    }

    /// The text marked as the current match on the match's row.
    private static func marked(_ review: DiffReview, _ file: ReviewFile) -> String {
        guard let find = review.find.rowFind, let match = find.current, let row = file.row(of: match, split: false),
              let item = file.unified.first(where: { $0.id == row }), case .line(let line) = item.content else { return "nothing" }
        let text = find.mark(AttributedString(line.text), line: line, in: file)
        return text.runs.compactMap { $0.backgroundColor == .btFindCurrent ? String(text[$0.range].characters) : nil }.joined()
    }

    private static func find<T: NSView>(_ type: T.Type) -> (NSView) -> T? {
        { view in
            if let match = view as? T { return match }
            return view.subviews.lazy.compactMap(find(type)).first
        }
    }

    private static func keys(_ item: NSMenuItem) -> String {
        let m = item.keyEquivalentModifierMask
        return (m.contains(.option) ? "⌥" : "") + (m.contains(.shift) ? "⇧" : "") + "⌘" + item.keyEquivalent
    }

    private static func shot(_ suffix: String) {
        guard let path = ProcessInfo.processInfo.environment["ABSTRACT_DEMO_REVIEWFIND_SHOT"], let image = WindowCapture.image() else { return }
        let url = URL(fileURLWithPath: path)
        let out = url.deletingPathExtension().path + suffix + "." + url.pathExtension
        try? image.write(to: URL(fileURLWithPath: out))
        log("review find probe: shot \(out)")
    }

    private static func responder() -> String {
        NSApp.windows.first { $0.isVisible && $0.contentView != nil }?.firstResponder.map { String(describing: type(of: $0)) } ?? "nothing"
    }

    private static func items(_ menu: NSMenu?) -> [NSMenuItem] {
        (menu?.items ?? []).flatMap { [$0] + items($0.submenu) }
    }
}
