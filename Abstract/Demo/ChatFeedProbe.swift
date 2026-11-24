import AppKit
import SwiftUI
import AbstractCore

/// Demo mode's chat feed check (ABS-217).
/// `ABSTRACT_DEMO_CHAT_FEED=<port>` adds made-up chats (one open with
/// planted secrets, a code block and sample patient data, one archived, one
/// deleted), turns the feed on at that port with health data hidden, and
/// writes a fresh token to `<demo root>/chat-feed-token` for `curl`. The
/// token stays in memory: a demo never touches the Keychain.
/// `ABSTRACT_DEMO_CHAT_FEED_SHOT=<png>` then opens Settings › Devices and
/// saves the window at a few scroll positions, the position in the name.
enum ChatFeedProbe {
    static func runIfRequested(_ model: AppModel, root: URL) {
        guard let spec = ProcessInfo.processInfo.environment["ABSTRACT_DEMO_CHAT_FEED"], let port = UInt16(spec) else { return }
        Task { await run(model, root: root, port: port) }
    }

    private static func run(_ model: AppModel, root: URL, port: UInt16) async {
        seed(model)
        model.chatFeed.update {
            $0.port = port
            $0.filter.redactsHealthData = true
            $0.enabled = true
        }
        let token = model.chatFeed.rotateToken()
        let url = root.appendingPathComponent("chat-feed-token")
        FileManager.default.createFile(atPath: url.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600])
        try? await Task.sleep(for: .seconds(1))
        log("chat feed: \(model.chatFeed.status) at \(model.chatFeed.endpointURL); token in \(url.path)")
        guard let shot = ProcessInfo.processInfo.environment["ABSTRACT_DEMO_CHAT_FEED_SHOT"] else { return }
        let tab = UserDefaults.standard.string(forKey: "settingsTab")
        defer {
            if let tab { UserDefaults.standard.set(tab, forKey: "settingsTab") } else { UserDefaults.standard.removeObject(forKey: "settingsTab") }
        }
        UserDefaults.standard.set(SettingsTab.devices.rawValue, forKey: "settingsTab")
        model.isSettingsOpen = true
        // A few calls, so "Last calls" has rows.
        try? await Task.sleep(for: .seconds(Double(ProcessInfo.processInfo.environment["ABSTRACT_DEMO_CHAT_FEED_WAIT"] ?? "") ?? 2))
        for fraction in [0.45, 0.6, 0.75, 1.0] {
            scroll(to: fraction)
            try? await Task.sleep(for: .seconds(1.2))
            guard let image = WindowCapture.image() ?? WindowCapture.image(method: .cacheDisplay) else {
                log("chat feed: no shot"); continue
            }
            let base = URL(fileURLWithPath: shot)
            let out = URL(fileURLWithPath: base.deletingPathExtension().path + "-\(Int(fraction * 100))." + base.pathExtension)
            try? image.write(to: out)
            log("chat feed: shot \(out.path)")
        }
        log("chat feed: done")
    }

    /// Made-up chats only: every secret and patient here is invented.
    private static func seed(_ model: AppModel) {
        let projectId = model.projects.first { $0.name == "payments-api" }?.id ?? model.projects.first?.id
        let now = Date()
        func chat(_ id: String, _ name: String, archived: Bool = false, _ messages: [(TextRole, String)]) {
            try? model.store.save(Session(id: id, projectId: projectId, name: name, providerId: "claude", status: .idle,
                                          createdAt: now.addingTimeInterval(-3_600), lastEventAt: now.addingTimeInterval(-60),
                                          archivedAt: archived ? now : nil))
            let lines = messages.enumerated().map { i, message in
                let at = now.addingTimeInterval(Double(i - messages.count) * 30)
                if message.0 == .user { return OutputLine(stream: .user, line: message.1, at: at) }
                let event = JSONValue.object([
                    "type": .string("assistant"),
                    "message": .object(["id": .string("demo-\(id)-\(i)"), "role": .string("assistant"),
                                        "content": .array([.object(["type": .string("text"), "text": .string(message.1)])])]),
                ])
                return OutputLine(stream: .stdout, line: event.compact(), at: at)
            }
            let text = lines.compactMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n") + "\n"
            try? text.write(to: model.engine.logsURL.appendingPathComponent("\(id).jsonl"), atomically: true, encoding: .utf8)
        }
        chat("feed-demo-open", "Move the clinic's database to the new host", [
            (.user, """
                Move the clinic app to the new database. The old one is postgres://clinic_admin:not-a-real-pass@db.example.test:5432/clinic \
                and .env has OPENAI_API_KEY=sk-proj-DEMOonlyNotAKey0123456789.
                """),
            (.assistant, """
                Done. I pointed DATABASE_URL at the new host and rotated the password: "password": "demo-only-123".

                ```sql
                ALTER ROLE clinic_admin PASSWORD 'demo';
                SELECT 1;
                ```

                One row still mentions Paciente Maria da Silva, CPF 123.456.789-09, DN: 03/04/1980, prontuário 778899. \
                I left it as it was.
                """),
        ])
        chat("feed-demo-archived", "Archived: old billing export", archived: true,
             [(.user, "Export billing for October."), (.assistant, "Exported.")])
        chat("feed-demo-deleted", "Deleted: scratch", [(.user, "Try something."), (.assistant, "Tried it.")])
        try? model.store.deleteSession("feed-demo-deleted")
        model.reload()
        log("chat feed: seeded made-up chats")
    }

    private static var mainWindow: NSWindow? { NSApp.windows.first { $0.canBecomeMain && $0.isVisible } }

    private static func scroll(to fraction: CGFloat) {
        guard let scroll = scrollViews(mainWindow?.contentView)
            .max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }),
              let document = scroll.documentView else { return }
        // The page starts under the title bar: its top is above the clip view's zero.
        let inset = scroll.contentView.contentInsets.top
        let target = max(0, document.frame.height - scroll.contentView.bounds.height + inset) * fraction - inset
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? target : document.frame.height - scroll.contentView.bounds.height - target))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private static func scrollViews(_ view: NSView?) -> [NSScrollView] {
        guard let view else { return [] }
        return ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
    }
}
