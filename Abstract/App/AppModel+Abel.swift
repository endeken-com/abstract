import AbstractCore
import AppKit
import Foundation

/// ABEL, the voice assistant (ABS-203): installing and removing it, what it
/// asks Abstract over `AppLink`, and the replies it reads aloud. ABEL is
/// its own app, `Abel.app`, inside this one; it holds the microphone, and
/// Abstract never asks for it.
extension AppModel {
    static let abelSendDraft = Notification.Name("AbelSendDraft")

    var abelInstaller: AbelInstaller {
        AbelInstaller(appURL: AbelInstaller.bundledApp(in: Bundle.main.bundleURL), launch: { url in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.addsToRecentItems = false
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }, quit: {
            Task { @MainActor in
                NSRunningApplication.runningApplications(withBundleIdentifier: AbelLink.bundleIdentifier)
                    .forEach { $0.terminate() }
            }
        })
    }

    /// Reads ABEL's settings and whether it's installed.
    func loadAbel() {
        abelSettings = store.setting(AbelSettings.storeKey, as: AbelSettings.self) ?? AbelSettings()
        refreshAbelState()
    }

    func refreshAbelState() {
        // A demo's ABEL is the real one's: never install or remove it from there.
        abelState = isDemo ? .unavailable("ABEL can't be installed from a demo.") : abelInstaller.state
    }

    var abelInstalled: Bool { abelState == .installed }

    func installAbel() {
        do {
            try abelInstaller.install()
        } catch {
            flash(error.localizedDescription, isError: true)
        }
        refreshAbelState()
    }

    func removeAbel() {
        do {
            try abelInstaller.remove()
        } catch {
            flash(error.localizedDescription, isError: true)
        }
        refreshAbelState()
    }

    /// Saves ABEL's settings and tells ABEL to pick them up.
    func updateAbelSettings(_ change: (inout AbelSettings) -> Void) {
        var settings = abelSettings
        change(&settings)
        guard settings != abelSettings else { return }
        abelSettings = settings
        try? store.setSetting(AbelSettings.storeKey, settings)
        let storePath = storePath
        Task.detached { _ = AbelLink.tell(AbelLink.HelperRequest(kind: .reload), storePath: storePath) }
    }

    /// What ABEL says it's doing, for Settings › ABEL; nil when it isn't running.
    func abelStatus() async -> String? {
        let storePath = storePath
        return await Task.detached { AbelLink.tell(AbelLink.HelperRequest(kind: .status), storePath: storePath)?.state }.value
    }

    // MARK: ABEL asking

    func answerAbel(_ request: AbelLink.Request) async -> AbelLink.Reply {
        switch request.kind {
        case .context:
            return AbelLink.Reply(ok: true, context: abelContext())
        case .dictate:
            guard let chatId = request.chatId ?? selectedSessionId, let session = session(chatId) else {
                return .failed("Open a chat in Abstract first.")
            }
            guard let words = request.text?.trimmingCharacters(in: .whitespacesAndNewlines), !words.isEmpty else {
                return .failed("There was nothing to write.")
            }
            let draft = composerDrafts.draft(chatId)
            draft.text = AbelDictation.appending(words, to: draft.text)
            return AbelLink.Reply(ok: true, chatTitle: session.name)
        case .sendDraft:
            guard let chatId = request.chatId ?? selectedSessionId, let session = session(chatId) else {
                return .failed("Open a chat in Abstract first.")
            }
            guard !composerDrafts.draft(chatId).text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failed("The reply box of “\(session.name)” is empty.")
            }
            guard selectedSessionId == chatId else {
                return .failed("Open “\(session.name)” to send what's in its reply box.")
            }
            // The chat's own Send does it, review comments and all.
            NotificationCenter.default.post(name: Self.abelSendDraft, object: chatId)
            return AbelLink.Reply(ok: true, chatTitle: session.name)
        }
    }

    func abelContext() -> AbelLink.Context {
        let vocabulary = AbelVocabulary.build(
            projects: projects.map { ($0.name, $0.archivedAt != nil) },
            chats: sessions.map { ($0.name, $0.archivedAt != nil, $0.lastEventAt ?? $0.createdAt) },
            agents: ProviderRegistry.all.map { ProviderRegistry.name($0.id) })
        let shown = selectedSessionId.flatMap { session($0) }
        return AbelLink.Context(shownChatId: shown?.id, shownChatTitle: shown?.name, isFrontmost: NSApp.isActive,
                                vocabulary: vocabulary, settings: abelSettings,
                                themeId: ThemeState.shared.theme(for: NSApp.effectiveAppearance).id)
    }

    // MARK: Reading replies aloud

    /// A turn ended: ABEL reads the reply if the chat has Read Replies Aloud on.
    func abelTurnEnded(_ sessionId: String) {
        guard abelSettings.speaks(sessionId), let session = session(sessionId),
              let reply = feed(sessionId).timeline.lastReply else { return }
        let storePath = storePath, title = session.name
        Task.detached {
            _ = AbelLink.tell(AbelLink.HelperRequest(kind: .speak, text: reply, chatId: sessionId, chatTitle: title),
                              storePath: storePath)
        }
    }

    func abelSpeaks(_ sessionId: String) -> Bool { abelSettings.speaks(sessionId) }

    func setAbelSpeaks(_ sessionId: String, _ on: Bool) {
        updateAbelSettings { $0.setSpeaks(sessionId, on) }
    }
}
