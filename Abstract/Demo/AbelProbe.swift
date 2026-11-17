import AbstractCore
import Foundation

/// Demo mode's ABEL check (ABS-203). `ABSTRACT_DEMO_ABEL=<chat name prefix>`
/// opens that chat and turns Read Replies Aloud on for it, so `Abel
/// --simulate` (run with this demo's `ABSTRACT_DATA_DIR`) has a chat on
/// screen to dictate into and a reply to read. Every second it writes what
/// ABEL can change to `ABSTRACT_DEMO_ABEL_OUT` (JSON): the chat on screen,
/// its reply box, the last message you sent and the last reply.
enum AbelProbe {
    static func runIfRequested(_ model: AppModel) {
        guard let prefix = ProcessInfo.processInfo.environment["ABSTRACT_DEMO_ABEL"] else { return }
        let out = ProcessInfo.processInfo.environment["ABSTRACT_DEMO_ABEL_OUT"]
        Task { @MainActor in
            // After the demo's last chat starts, which takes the screen.
            for _ in 0..<30 where model.sessions.count < 4 { try? await Task.sleep(for: .seconds(1)) }
            try? await Task.sleep(for: .seconds(2))
            guard let chat = model.sessions.first(where: { $0.name.hasPrefix(prefix) }) ?? model.sessions.first else {
                log("abel probe: no chat")
                return
            }
            model.destination = .session(chat.id)
            model.setAbelSpeaks(chat.id, true)
            log("abel probe: showing “\(chat.name)”, read aloud on")
            while true {
                if let out { write(model, chat.id, to: out) }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    @MainActor
    private static func write(_ model: AppModel, _ chatId: String, to path: String) {
        let entries = model.feed(chatId).timeline.entries
        let sent = entries.compactMap { entry -> String? in
            if case let .text(.user, text, _, _) = entry.event { return text }
            return nil
        }
        let state: [String: Any] = [
            "shownChat": model.selectedSession?.name ?? "",
            "draft": model.composerDrafts.draft(chatId).text,
            "sentCount": sent.count,
            "lastSent": sent.last ?? "",
            "lastReply": model.feed(chatId).timeline.lastReply ?? "",
            "speaks": model.abelSpeaks(chatId),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
