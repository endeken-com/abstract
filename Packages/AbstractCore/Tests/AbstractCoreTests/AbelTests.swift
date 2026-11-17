import Darwin
import Foundation
import Testing
@testable import AbstractCore

/// ABEL's pure parts (ABS-203): what's read aloud, the wake phrase in text,
/// the state machine, dictation, settings, names, installing, and the link.
@Suite struct AbelSpeakableTextTests {
    @Test func readsTheFirstParagraphWithoutMarkdown() {
        let text = SpeakableText(markdown: "## Done\n\nI **added** a test for `SidebarChats` and [the docs](https://example.com/x).\n\nSecond paragraph.")
        #expect(text.first == "Done.")
        #expect(text.paragraphs[1] == "I added a test for SidebarChats and the docs.")
        #expect(text.paragraph(after: 1) == "Second paragraph.")
        #expect(text.paragraph(after: 2) == nil)
    }

    @Test func foldsCodeBlocksIntoTheParagraphBefore() {
        let reply = "I changed the grouping:\n\n```swift\nlet a = 1\nlet b = 2\nlet c = 3\n```\n\nTests pass."
        let text = SpeakableText(markdown: reply)
        #expect(text.first == "I changed the grouping, and 3 lines of code.")
        #expect(text.paragraphs.count == 2)
        #expect(!text.paragraphs.joined().contains("let a"))
    }

    @Test func callsADiffADiff() {
        let reply = "Here's the fix.\n\n```diff\n- old\n+ new\n+ newer\n```"
        #expect(SpeakableText(markdown: reply).first == "Here's the fix, and a 3-line diff.")
        let unlabelled = "Patch:\n\n```\n@@ -1 +1 @@\n-a\n+b\n```"
        #expect(SpeakableText(markdown: unlabelled).first == "Patch, and a 3-line diff.")
    }

    @Test func aReplyThatIsOnlyCodeStillSaysSomething() {
        #expect(SpeakableText(markdown: "```\nonly code\n```").first == "And a line of code.")
    }

    @Test func summarisesTables() {
        let reply = "Results:\n\n| Test | Result |\n|---|---|\n| a | pass |\n| b | fail |"
        #expect(SpeakableText(markdown: reply).first == "Results, and a table with 2 rows.")
    }

    @Test func shortensLongPathsAndLinks() {
        let text = SpeakableText(markdown: "I edited Packages/AbstractCore/Sources/AbstractCore/Abel/WakePhrase.swift, see https://github.com/endeken-com/abstract/pull/1")
        #expect(text.first == "I edited WakePhrase.swift, see a link to github.com.")
        // A short path stays as it is.
        #expect(SpeakableText(markdown: "Open docs/plugins.md").first == "Open docs/plugins.md.")
    }

    @Test func readsListsAsSentences() {
        let text = SpeakableText(markdown: "- first item\n- second item\n1. third")
        #expect(text.first == "first item. second item. third.")
    }

    @Test func emptyRepliesSayNothing() {
        #expect(SpeakableText(markdown: "   \n\n").first == nil)
    }
}

@Suite struct AbelWakePhraseTests {
    @Test(arguments: [
        ("Hey Abel, what needs me?", "en-US", "what needs me?"),
        ("Okay, Abel, what needs me?", "en-US", "what needs me?"),
        ("Kay Abel, read the last reply.", "en-US", "read the last reply."),
        (" Hey, Gable, what needs me?", "en-US", "what needs me?"),
        ("Hey, Abel, open the sidebar fixed chat.", "en-US", "open the sidebar fixed chat."),
        ("A able approve.", "en-US", "approve."),
        ("Okay, able.", "en-US", ""),
        ("Hey Abel", "en-US", ""),
        ("Abel, o que precisa de mim?", "pt-BR", "o que precisa de mim?"),
        ("Ei Abel, ler a última resposta", "pt-BR", "ler a última resposta"),
        ("Abel", "pt-BR", ""),
        ("Some noise. Hey Abel, stop.", "en-US", "stop."),
    ])
    func wakes(_ heard: String, _ locale: String, _ command: String) {
        #expect(WakePhrase.match(heard, locale: locale) == WakePhrase.Match(command: command))
    }

    @Test(arguments: [
        ("heard a bell ring in the hallway.", "en-US"),
        ("We should be able to ship it today.", "en-US"),
        ("Hey, a bell just rang.", "en-US"),
        ("Put a label on the table.", "en-US"),
        ("Hey Abby, are you coming?", "en-US"),
        ("Cain and Abel were brothers.", "en-US"),
        ("Okay, able, that's enough for today.", "en-US"),
        ("Abel Tasman sailed to New Zealand in 1642.", "en-US"),
        ("Hey, are you able to join the call at three?", "en-US"),
        ("Hey Mabel, can you pass me the salt?", "en-US"),
        ("Hey Abe, how was your weekend?", "en-US"),
        ("Okay, let's table that discussion.", "en-US"),
        ("A velha entrou na sala.", "pt-BR"),
        ("Ele é muito hábil com isso.", "pt-BR"),
        ("O Abel ligou ontem à noite.", "pt-BR"),
        ("Ei Fabinho tudo bem.", "pt-BR"),
    ])
    func ignoresNearMisses(_ heard: String, _ locale: String) {
        #expect(WakePhrase.match(heard, locale: locale) == nil)
    }

    @Test func stripsTheWakeOnceAwake() {
        #expect(WakePhrase.strippingWake("Hey, Gable, add a test for the sidebar grouping.") == "add a test for the sidebar grouping.")
        #expect(WakePhrase.strippingWake("Ei Abel, envia") == "envia")
        #expect(WakePhrase.strippingWake("add a test") == "add a test")
        #expect(WakePhrase.strippingWake("Hey, can you add a test") == "Hey, can you add a test")
    }

    @Test func foldsCaseAndAccents() {
        #expect(AbelText.normalized("Próximo, PR-43!") == "proximo pr 43")
        #expect(AbelText.words("What's next?") == ["whats", "next"])
    }
}

@Suite struct AbelMachineTests {
    @Test func pushToTalkListensThenHandlesWhatWasSaid() {
        var machine = AbelMachine()
        #expect(machine.send(.pushDown) == [.startCapture(.pushToTalk), .expand])
        #expect(machine.phase == .listening(.pushToTalk))
        #expect(machine.send(.pushUp) == [.finishCapture])
        #expect(machine.phase == .transcribing(.pushToTalk))
        #expect(machine.send(.heard("add a test")) == [.handle("add a test", .pushToTalk)])
        #expect(machine.phase == .idle)
    }

    @Test func nothingHeardJustCollapses() {
        var machine = AbelMachine()
        _ = machine.send(.pushDown)
        _ = machine.send(.pushUp)
        #expect(machine.send(.heard("  ")) == [.collapse])
    }

    @Test func escapeDropsWhatWasBeingHeard() {
        var machine = AbelMachine()
        _ = machine.send(.pushDown)
        #expect(machine.send(.escape) == [.cancelCapture, .collapse])
        #expect(machine.phase == .idle)
    }

    @Test func pressingTheKeyInterruptsSpeech() {
        var machine = AbelMachine()
        _ = machine.send(.speechStarted)
        #expect(machine.phase == .speaking)
        #expect(machine.send(.pushDown) == [.stopSpeaking, .startCapture(.pushToTalk), .expand])
    }

    @Test func talkingOverABELStopsIt() {
        var machine = AbelMachine()
        _ = machine.send(.speechStarted)
        #expect(machine.send(.talkedOver) == [.stopSpeaking, .collapse])
        #expect(machine.phase == .idle)
        _ = machine.send(.speechStarted)
        #expect(machine.send(.speechFinished) == [.collapse])
    }

    @Test func theWakePhraseListensForTheCommand() {
        var machine = AbelMachine(wakePhraseOn: true)
        #expect(machine.startEffects == [.startWakeListener])
        #expect(machine.send(.wake(command: "")) == [.startCapture(.wakePhrase), .expand])
        #expect(machine.send(.heard("what needs me")) == [.handle("what needs me", .wakePhrase)])
    }

    @Test func aWakeWithItsCommandActsAtOnce() {
        var machine = AbelMachine(wakePhraseOn: true)
        #expect(machine.send(.wake(command: "what needs me")) == [.expand, .handle("what needs me", .wakePhrase)])
        _ = machine.send(.speechStarted)
        #expect(machine.send(.wake(command: "")) == [.stopSpeaking, .startCapture(.wakePhrase), .expand])
    }

    @Test func silenceAfterTheWakePhraseGivesUp() {
        var machine = AbelMachine(wakePhraseOn: true)
        _ = machine.send(.wake(command: ""))
        #expect(machine.send(.silence) == [.cancelCapture, .collapse])
    }

    @Test func lockingStopsEverythingAndUnlockingResumesTheWakeListener() {
        var machine = AbelMachine(wakePhraseOn: true)
        _ = machine.send(.pushDown)
        #expect(machine.send(.locked(true)) == [.cancelCapture, .stopWakeListener, .collapse])
        #expect(machine.isPaused)
        // Nothing gets through while locked; push-to-talk says why.
        #expect(machine.send(.wake(command: "approve")) == [])
        #expect(machine.send(.heard("approve")) == [])
        #expect(machine.send(.pushDown) == [.explain(.locked)])
        #expect(machine.send(.locked(false)) == [.startWakeListener])
        #expect(machine.phase == .idle)
    }

    @Test func screenSharingAndYourPauseStack() {
        var machine = AbelMachine()
        _ = machine.send(.speechStarted)
        #expect(machine.send(.screenShared(true)) == [.stopSpeaking, .collapse])
        #expect(machine.send(.pausedByYou(true)) == [])
        #expect(machine.pauseReason == .screenShared)
        #expect(machine.send(.screenShared(false)) == [])
        #expect(machine.pauseReason == .byYou)
        #expect(machine.send(.pausedByYou(false)) == [])
        #expect(!machine.isPaused)
    }

    @Test func turningTheWakePhraseOnAndOff() {
        var machine = AbelMachine()
        #expect(machine.send(.wakePhraseSetting(true)) == [.startWakeListener])
        #expect(machine.send(.wakePhraseSetting(true)) == [])
        _ = machine.send(.locked(true))
        #expect(machine.send(.wakePhraseSetting(false)) == [])
        #expect(machine.send(.locked(false)) == [])
    }
}

@Suite struct AbelRouterTests {
    let context = AbelLink.Context(shownChatId: "chat-1", shownChatTitle: "Sidebar fix")

    @Test func dictatesIntoTheChatOnScreen() {
        #expect(AbelRouter.route("add a test for the sidebar grouping", context: context)
            == .dictate(chatId: "chat-1", text: "add a test for the sidebar grouping"))
    }

    @Test(arguments: ["Send it.", "send", "Envia", "pode enviar"])
    func sendItSends(_ said: String) {
        #expect(AbelRouter.route(said, context: context) == .sendDraft(chatId: "chat-1"))
    }

    @Test func saysWhyWhenThereIsNowhereToWrite() {
        #expect(AbelRouter.route("hello", context: nil) == .say(AbelPhrases(language: "en-US").abstractClosed))
        #expect(AbelRouter.route("hello", context: AbelLink.Context()) == .say(AbelPhrases(language: "en-US").openAChat))
        #expect(AbelRouter.route("olá", context: AbelLink.Context(), language: "pt-BR")
            == .say(AbelPhrases(language: "pt-BR").openAChat))
    }

    @Test func onlyAClearYesIsYes() {
        for yes in ["Yes.", "yeah", "Sim!", "pode sim", "go ahead"] { #expect(AbelConfirmation.isYes(yes)) }
        for no in ["no", "yes but not now", "send it", "", "não", "simulate"] { #expect(!AbelConfirmation.isYes(no)) }
    }

    @Test func dictationJoinsTakes() {
        #expect(AbelDictation.appending("add a test", to: "") == "add a test")
        #expect(AbelDictation.appending("for grouping", to: "add a test") == "add a test for grouping")
        #expect(AbelDictation.appending("more", to: "line\n") == "line\nmore")
        #expect(AbelDictation.appending("  ", to: "kept") == "kept")
    }
}

@Suite struct AbelSettingsTests {
    @Test func defaultsAreQuiet() {
        let settings = AbelSettings()
        #expect(!settings.wakePhrase)
        #expect(settings.languages == ["en-US"])
        #expect(settings.showOrb)
    }

    @Test func keepsOnlySupportedLanguagesInOrder() {
        #expect(AbelSettings(languages: ["pt-BR", "fr-FR", "en-US"]).languages == ["en-US", "pt-BR"])
        #expect(AbelSettings(languages: ["fr-FR"]).languages == ["en-US"])
    }

    @Test func readsOlderAndPartialJSON() throws {
        let settings = try JSONDecoder().decode(AbelSettings.self, from: Data(#"{"wakePhrase":true}"#.utf8))
        #expect(settings.wakePhrase)
        #expect(settings.languages == ["en-US"])
        #expect(settings.speakReplies.isEmpty)
    }

    @Test func roundTripsThroughTheStore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("abel-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try Store(path: dir.appendingPathComponent("abstract.sqlite").path)
        var settings = AbelSettings(wakePhrase: true, languages: ["en-US", "pt-BR"], voice: "voice-1")
        settings.setSpeaks("chat-1", true)
        try store.setSetting(AbelSettings.storeKey, settings)
        #expect(store.setting(AbelSettings.storeKey, as: AbelSettings.self) == settings)
    }

    @Test func readRepliesAloudPerChat() {
        var settings = AbelSettings()
        settings.setSpeaks("a", true)
        settings.setSpeaks("a", true)
        settings.setSpeaks("b", true)
        #expect(settings.speakReplies == ["a", "b"])
        settings.setSpeaks("a", false)
        #expect(!settings.speaks("a"))
        #expect(settings.speaks("b"))
    }
}

@Suite struct AbelVocabularyTests {
    @Test func buildsFromProjectsChatsAndAgents() {
        let now = Date()
        let vocabulary = AbelVocabulary.build(
            projects: [("Abstract", false), ("Old", true), (" Abstract ", false)],
            chats: [("Older chat", false, now.addingTimeInterval(-60)), ("Sidebar fix", false, now),
                    ("Archived", true, now), ("", false, now)],
            agents: ["Claude", "Codex", "OpenCode"])
        #expect(vocabulary.projects == ["Abstract"])
        #expect(vocabulary.chats == ["Sidebar fix", "Older chat"])
        #expect(vocabulary.agents == ["Claude", "Codex", "OpenCode"])
        #expect(vocabulary.contextualStrings.prefix(3) == ["Abel", "Hey Abel", "Ei Abel"])
    }

    @Test func keepsTheMostRecentChatsUnderTheLimit() {
        let now = Date()
        let chats = (0..<300).map { (title: "Chat \($0)", archived: false, activeAt: now.addingTimeInterval(Double($0))) }
        let vocabulary = AbelVocabulary.build(projects: [("P", false)], chats: chats, agents: ["Claude"])
        #expect(vocabulary.chats.count == AbelVocabulary.limit - 2)
        #expect(vocabulary.chats.first == "Chat 299")
    }
}

/// A login item that does what it's told, and remembers.
final class FakeLoginItem: LoginItemService, @unchecked Sendable {
    var status: LoginItemStatus
    var calls: [String] = []
    var failRegister = false

    init(_ status: LoginItemStatus = .notRegistered) { self.status = status }

    func register() throws {
        calls.append("register")
        if failRegister { throw AbstractError.message("Not allowed.") }
        status = .enabled
    }

    func unregister() throws {
        calls.append("unregister")
        status = .notRegistered
    }
}

final class Calls: @unchecked Sendable {
    var list: [String] = []
}

@Suite struct AbelInstallerTests {
    let app = URL(fileURLWithPath: "/Applications/Abstract.app/Contents/Library/LoginItems/Abel.app")
    let tahoe = OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0)

    func installer(_ service: FakeLoginItem, calls: Calls, app: URL? = nil,
                   version: OperatingSystemVersion? = nil) -> AbelInstaller {
        AbelInstaller(service: service, appURL: app ?? self.app, systemVersion: version ?? tahoe,
                      launch: { calls.list.append("launch \($0.lastPathComponent)") }, quit: { calls.list.append("quit") })
    }

    @Test func installTurnsTheLoginItemOnAndStartsIt() throws {
        let service = FakeLoginItem(), calls = Calls()
        let installer = installer(service, calls: calls)
        #expect(installer.state == .notInstalled)
        try installer.install()
        #expect(service.calls == ["register"])
        #expect(calls.list == ["launch Abel.app"])
        #expect(installer.state == .installed)
    }

    @Test func removeTurnsItOffAndQuitsIt() throws {
        let service = FakeLoginItem(.enabled), calls = Calls()
        let installer = installer(service, calls: calls)
        try installer.remove()
        #expect(service.calls == ["unregister"])
        #expect(calls.list == ["quit"])
        #expect(installer.state == .notInstalled)
    }

    @Test func installingTwiceDoesNotRegisterTwice() throws {
        let service = FakeLoginItem(.enabled), calls = Calls()
        try installer(service, calls: calls).install()
        #expect(service.calls.isEmpty)
        #expect(calls.list == ["launch Abel.app"])
    }

    @Test func needsMacOS26() {
        let service = FakeLoginItem(), calls = Calls()
        let old = installer(service, calls: calls, version: OperatingSystemVersion(majorVersion: 15, minorVersion: 6, patchVersion: 0))
        #expect(old.state == .unavailable("ABEL needs macOS 26 or later. This Mac has macOS 15."))
        #expect(throws: (any Error).self) { try old.install() }
        #expect(service.calls.isEmpty)
    }

    @Test func approvalAndFailuresAreReported() {
        let calls = Calls()
        #expect(installer(FakeLoginItem(.requiresApproval), calls: calls).state == .needsApproval)
        let failing = FakeLoginItem()
        failing.failRegister = true
        #expect(throws: (any Error).self) { try installer(failing, calls: calls).install() }
        #expect(calls.list.isEmpty)
    }

    @Test func findsAbelInsideAbstract() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("abel-install-\(UUID().uuidString)/Abstract.app")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        #expect(AbelInstaller.bundledApp(in: root) == nil)
        let contents = root.appendingPathComponent(AbelLink.bundledPath + "/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try Data().write(to: contents.appendingPathComponent("Info.plist"))
        #expect(AbelInstaller.bundledApp(in: root)?.lastPathComponent == "Abel.app")
        let missing = AbelInstaller(service: FakeLoginItem(), appURL: nil, systemVersion: tahoe, launch: { _ in }, quit: {})
        #expect(missing.state == .unavailable("This copy of Abstract was built without ABEL."))
    }
}

/// Both sockets, end to end on this Mac: ABEL asking Abstract over
/// `AppLink`, and Abstract asking ABEL over ABEL's own. Waits are long,
/// for a busy CI runner.
@Suite struct AbelLinkTests {
    let wait: Int32 = 20_000

    func storePath() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("abel-link-\(UUID().uuidString)/abstract.sqlite").path
    }

    @Test func abelAsksAbstractOverAppLink() async throws {
        let path = storePath()
        let made = AppLink.Server(storePath: path, handler: { _ in
            AppLink.StartReply(agent: nil, message: "start")
        }, abel: { request in
            switch request.kind {
            case .context: AbelLink.Reply(ok: true, context: AbelLink.Context(shownChatId: "chat-1", shownChatTitle: "Sidebar fix"))
            case .dictate: AbelLink.Reply(ok: true, chatTitle: request.text)
            case .sendDraft: .failed("Nothing to send.")
            }
        })
        let server = try #require(made)
        defer { server.stop() }
        let context = await AbelLink.offThePool { AbelLink.ask(AbelLink.Request(kind: .context), storePath: path, timeoutMs: wait) }
        #expect(context?.context?.shownChatTitle == "Sidebar fix")
        let dictated = await AbelLink.offThePool { AbelLink.ask(AbelLink.Request(kind: .dictate, text: "hi"), storePath: path, timeoutMs: wait) }
        #expect(dictated == AbelLink.Reply(ok: true, chatTitle: "hi"))
        let sent = await AbelLink.offThePool { AbelLink.ask(AbelLink.Request(kind: .sendDraft), storePath: path, timeoutMs: wait) }
        #expect(sent == .failed("Nothing to send."))
    }

    @Test func anAppWithoutABELSaysSo() async throws {
        let path = storePath()
        let made = AppLink.Server(storePath: path, handler: { _ in AppLink.StartReply(agent: nil, message: nil) })
        let server = try #require(made)
        defer { server.stop() }
        let reply = await AbelLink.offThePool { AbelLink.ask(AbelLink.Request(kind: .context), storePath: path, timeoutMs: wait) }
        #expect(reply?.ok == false)
    }

    @Test func noAbstractMeansNoReply() async {
        let path = storePath()
        #expect(await AbelLink.offThePool { AbelLink.ask(AbelLink.Request(kind: .context), storePath: path) } == nil)
        #expect(await AbelLink.offThePool { AbelLink.tell(AbelLink.HelperRequest(kind: .status), storePath: path) } == nil)
    }

    @Test func abstractAsksABEL() async throws {
        let path = storePath()
        let made = AbelLink.LineServer<AbelLink.HelperRequest, AbelLink.HelperReply>(
            path: AbelLink.helperSocketPath(storePath: path)) { request in
            AbelLink.HelperReply(ok: true, message: request.text, state: request.kind.rawValue)
        }
        let server = try #require(made)
        defer { server.stop() }
        let reply = await AbelLink.offThePool {
            AbelLink.tell(AbelLink.HelperRequest(kind: .speak, text: "Done.", chatTitle: "Sidebar fix"), storePath: path,
                          timeoutMs: wait)
        }
        #expect(reply == AbelLink.HelperReply(ok: true, message: "Done.", state: "speak"))
        // One ABEL per data folder.
        let second = AbelLink.LineServer<AbelLink.HelperRequest, AbelLink.HelperReply>(
            path: AbelLink.helperSocketPath(storePath: path)) { _ in AbelLink.HelperReply(ok: true) }
        #expect(second == nil)
    }

    @Test func eachDataFolderHasItsOwnSockets() {
        #expect(AbelLink.helperSocketPath(storePath: "/a/abstract.sqlite") != AbelLink.helperSocketPath(storePath: "/b/abstract.sqlite"))
        #expect(AbelLink.helperSocketPath(storePath: "/a/abstract.sqlite") != AppLink.socketPath(storePath: "/a/abstract.sqlite"))
    }
}
