@testable import AbelKit
import AbstractCore
import AppKit
import Foundation
import Testing

/// Abstract as ABEL sees it, played by the test: answers from a script,
/// and remembers every request.
final class FakeAbstract: AbstractConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [AbelLink.Request] = []
    var context: AbelLink.Context?
    var replies: [AbelLink.Request.Kind: AbelLink.Reply] = [:]

    init(context: AbelLink.Context? = AbelLink.Context(shownChatId: "chat-1", shownChatTitle: "Sidebar fix")) {
        self.context = context
    }

    var requests: [AbelLink.Request] { lock.withLock { _requests } }
    var acting: [AbelLink.Request] { requests.filter { $0.kind != .context } }

    func ask(_ request: AbelLink.Request) async -> AbelLink.Reply? {
        lock.withLock { _requests.append(request) }
        guard let context else { return nil }
        if request.kind == .context { return AbelLink.Reply(ok: true, context: context) }
        return replies[request.kind] ?? AbelLink.Reply(ok: true, chatTitle: context.shownChatTitle)
    }
}

/// Waits a little for something the engine does in a task of its own.
@MainActor
func eventually(_ condition: () -> Bool) async {
    for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
}

@MainActor
@Suite struct AbelEngineTests {
    let ears = QuietEars()
    let voice = RecordingVoice(finishesAtOnce: false)

    func engine(_ abstract: FakeAbstract = FakeAbstract()) async -> AbelEngine {
        let engine = AbelEngine(ears: ears, voice: voice, abstract: abstract)
        engine.lingering = .milliseconds(20)
        await engine.start()
        return engine
    }

    @Test func holdingTheKeyDictatesIntoTheOpenChat() async {
        let abstract = FakeAbstract()
        let engine = await engine(abstract)
        engine.pushDown()
        #expect(ears.calls == ["capture pushToTalk"])
        #expect(engine.display.mode == .listening)
        ears.nextFinal = ("add a test for the sidebar grouping", "en-US")
        engine.pushUp()
        await eventually { !abstract.acting.isEmpty }
        #expect(abstract.acting == [AbelLink.Request(kind: .dictate, chatId: "chat-1", text: "add a test for the sidebar grouping")])
        await eventually { engine.display.mode == .answering }
        #expect(engine.display.answer == "Added to Sidebar fix.")
        // Dictation is quiet: the words are already on screen.
        #expect(voice.spoken.isEmpty)
        #expect(engine.history.contains { $0.kind == .did && $0.text.contains("asked by you") })
    }

    @Test func sendItSendsTheReplyBox() async {
        let abstract = FakeAbstract()
        let engine = await engine(abstract)
        engine.pushDown()
        ears.nextFinal = ("Send it.", "en-US")
        engine.pushUp()
        await eventually { !abstract.acting.isEmpty }
        #expect(abstract.acting == [AbelLink.Request(kind: .sendDraft, chatId: "chat-1")])
    }

    @Test func sendingOnTheWakePhraseIsReadBackAndNeedsYes() async {
        var context = AbelLink.Context(shownChatId: "chat-1", shownChatTitle: "Sidebar fix")
        context.settings.wakePhrase = true
        let abstract = FakeAbstract(context: context)
        let engine = await engine(abstract)
        await engine.simulate("send it", trigger: .wakePhrase)
        #expect(abstract.acting.isEmpty)
        #expect(voice.spoken.last?.text == "Send the reply box of Sidebar fix? Say yes to send.")
        #expect(engine.isWaitingForYes)
        // Once the question is said, ABEL listens for the answer without the wake phrase.
        voice.finish()
        #expect(ears.calls.last == "capture wakePhrase")
        await engine.simulate("yes", trigger: .wakePhrase)
        #expect(abstract.acting == [AbelLink.Request(kind: .sendDraft, chatId: "chat-1")])
        #expect(!engine.isWaitingForYes)
    }

    @Test func anythingButYesCancels() async {
        let abstract = FakeAbstract()
        let engine = await engine(abstract)
        await engine.simulate("send it", trigger: .wakePhrase)
        await engine.simulate("send it now", trigger: .wakePhrase)
        #expect(abstract.acting.isEmpty)
        #expect(voice.spoken.last?.text == "Cancelled.")
        #expect(engine.history.contains { $0.kind == .refused })
    }

    @Test func aLateYesDoesNothing() async {
        let abstract = FakeAbstract()
        let engine = await engine(abstract)
        engine.confirmationWindow = .zero
        await engine.simulate("envia", language: "pt-BR", trigger: .wakePhrase)
        #expect(voice.spoken.last?.text == "Enviar a caixa de resposta de Sidebar fix? Diga sim para enviar.")
        await engine.simulate("sim", language: "pt-BR", trigger: .wakePhrase)
        #expect(abstract.acting.isEmpty)
        #expect(voice.spoken.last?.text == "Cancelado.")
    }

    @Test func saysWhyWhenAbstractRefuses() async {
        let abstract = FakeAbstract()
        abstract.replies[.sendDraft] = .failed("The reply box of “Sidebar fix” is empty.")
        let engine = await engine(abstract)
        await engine.simulate("send it")
        #expect(voice.spoken.map(\.text) == ["The reply box of “Sidebar fix” is empty."])
    }

    @Test func saysSoWhenAbstractIsClosed() async {
        let engine = await engine(FakeAbstract(context: nil))
        await engine.simulate("add a test")
        #expect(voice.spoken.map(\.text) == [AbelPhrases(language: "en-US").abstractClosed])
        #expect(engine.display.mode == .answering)
    }

    @Test func answersInTheLanguageYouSpoke() async {
        let engine = await engine(FakeAbstract(context: AbelLink.Context()))
        await engine.simulate("escreva isso", language: "pt-BR")
        #expect(voice.spoken.first?.language == "pt-BR")
        #expect(voice.spoken.first?.text == AbelPhrases(language: "pt-BR").openAChat)
    }

    @Test func readsAFinishedReplyWithoutItsCode() async {
        let engine = await engine()
        let reply = await engine.receive(AbelLink.HelperRequest(
            kind: .speak, text: "I added the test.\n\n```swift\nlet a = 1\n```\n\nAll green.", chatTitle: "Sidebar fix"))
        #expect(reply.ok)
        #expect(voice.spoken.map(\.text) == ["Sidebar fix says: I added the test, and a line of code."])
        #expect(engine.machine.phase == .speaking)
        voice.finish()
        #expect(engine.machine.phase == .idle)
    }

    @Test func pressingTheKeyStopsSpeech() async {
        let engine = await engine()
        _ = await engine.receive(AbelLink.HelperRequest(kind: .speak, text: "A long reply.", chatTitle: "Chat"))
        #expect(voice.isSpeaking)
        engine.pushDown()
        #expect(!voice.isSpeaking)
        #expect(voice.stops == 1)
        #expect(engine.display.mode == .listening)
    }

    @Test func talkingOverABELStopsIt() async {
        let engine = await engine()
        _ = await engine.receive(AbelLink.HelperRequest(kind: .speak, text: "A long reply.", chatTitle: "Chat"))
        #expect(ears.bargeIn)
        ears.onTalk?()
        #expect(!voice.isSpeaking)
        #expect(!ears.bargeIn)
        #expect(engine.machine.phase == .idle)
    }

    @Test func lockedOrSharedScreensStopListeningAndSpeaking() async {
        let engine = await engine()
        _ = await engine.receive(AbelLink.HelperRequest(kind: .speak, text: "Reply.", chatTitle: "Chat"))
        engine.screen(locked: true, shared: false)
        #expect(!voice.isSpeaking)
        #expect(engine.display.mode == .paused)
        let refused = await engine.receive(AbelLink.HelperRequest(kind: .speak, text: "Another.", chatTitle: "Chat"))
        #expect(!refused.ok)
        engine.pushDown()
        #expect(!ears.capturing)
        #expect(engine.display.answer == AbelMachine.PauseReason.locked.sentence)
        engine.screen(locked: false, shared: true)
        #expect(engine.stateSentence == AbelMachine.PauseReason.screenShared.sentence)
        engine.screen(locked: false, shared: false)
        #expect(engine.display.mode == .idle)
        engine.pushDown()
        #expect(ears.capturing)
    }

    @Test func followsTheWakePhraseSettingFromAbstract() async {
        var context = AbelLink.Context(shownChatId: "chat-1", shownChatTitle: "Sidebar fix")
        context.settings = AbelSettings(wakePhrase: true, languages: ["en-US", "pt-BR"])
        let abstract = FakeAbstract(context: context)
        let engine = await engine(abstract)
        #expect(ears.wakeListening)
        #expect(ears.calls.contains("wake on en-US,pt-BR"))
        abstract.context?.settings.wakePhrase = false
        _ = await engine.receive(AbelLink.HelperRequest(kind: .reload))
        #expect(!ears.wakeListening)
        #expect(engine.stateSentence == "Hold ⌥Space to talk.")
    }

    @Test func aWakeThenACommandDictates() async {
        var context = AbelLink.Context(shownChatId: "chat-1", shownChatTitle: "Sidebar fix")
        context.settings.wakePhrase = true
        let abstract = FakeAbstract(context: context)
        let engine = await engine(abstract)
        ears.onWake?()
        #expect(engine.display.isExpanded)
        #expect(ears.calls.last == "capture wakePhrase")
        ears.onFinal?("add a test", "en-US")
        await eventually { !abstract.acting.isEmpty }
        #expect(abstract.acting.first?.kind == .dictate)
    }

    @Test func nothingHeardSaysSo() async {
        let engine = await engine()
        engine.pushDown()
        engine.pushUp()
        #expect(voice.spoken.map(\.text) == ["I didn't catch that."])
    }

    @Test func escapeCancelsListening() async {
        let engine = await engine()
        engine.pushDown()
        engine.escape()
        #expect(ears.calls.last == "cancel")
        await eventually { engine.display.mode == .idle }
        #expect(engine.display.mode == .idle)
    }

    @Test func aProblemIsSaid() async {
        let engine = await engine()
        engine.pushDown()
        ears.onProblem?("ABEL can't hear you: allow the microphone for Abel in System Settings › Privacy & Security.")
        #expect(voice.spoken.first?.text.contains("allow the microphone") == true)
        #expect(engine.history.contains { $0.kind == .refused })
    }

    @Test func simulationReportsWhatHappened() async {
        let report = await AbelSimulation.run(["add a test for the sidebar grouping", "send it"], language: "en-US",
                                              abstract: FakeAbstract())
        #expect(report.events.map(\.kind) == [.heard, .did, .heard, .did])
        #expect(report.panel == ["answering", "answering"])
    }
}

@Suite struct TranscriptChoiceTests {
    @Test func picksTheSurestLanguage() {
        let best = Transcript.best(of: [("en-US", "a cue pressing the mean", 0.31), ("pt-BR", "o que precisa de mim", 0.92)],
                                   order: ["en-US", "pt-BR"])
        #expect(best.text == "o que precisa de mim")
        #expect(best.locale == "pt-BR")
        #expect(best.all.count == 2)
    }

    @Test func silenceNeverWinsAndTiesGoToTheFirstLanguage() {
        #expect(Transcript.best(of: [("en-US", "", 0.99), ("pt-BR", "sim", 0.2)], order: ["en-US", "pt-BR"]).locale == "pt-BR")
        #expect(Transcript.best(of: [("en-US", "yes", nil), ("pt-BR", "sim", nil)], order: ["en-US", "pt-BR"]).locale == "en-US")
        #expect(Transcript.best(of: [], order: ["pt-BR"]).text.isEmpty)
    }
}

@MainActor
@Suite struct ScreenWatchTests {
    @Test func reportsEachChangeOnce() {
        var reading = ScreenWatch.Reading(locked: false, shared: false)
        let watch = ScreenWatch(read: { reading })
        var seen: [ScreenWatch.Reading] = []
        watch.onChange = { seen.append($0) }
        watch.check()
        #expect(seen.isEmpty)
        reading.locked = true
        watch.check()
        watch.check()
        reading.shared = true
        watch.check()
        #expect(seen == [.init(locked: true, shared: false), .init(locked: true, shared: true)])
    }

    @Test func theRealChecksRunHere() {
        // This Mac is unlocked while tests run, and isn't sharing its screen.
        #expect(ScreenWatch.isLocked() == false)
        #expect(ScreenWatch.isRunning("launchd"))
        #expect(!ScreenWatch.isRunning("no-such-process-abel"))
    }
}

@MainActor
@Suite struct AbelPanelTests {
    static let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Abstract/Resources")

    @Test func neverTakesFocusAndFloatsEverywhere() {
        _ = NSApplication.shared
        let defaults = UserDefaults(suiteName: "abel-panel-\(UUID().uuidString)")!
        let panel = AbelPanel(defaults: defaults)
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.level == .floating)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(!panel.hidesOnDeactivate)
        #expect(panel.isMovableByWindowBackground)
    }

    @Test func remembersWhereYouDraggedIt() {
        _ = NSApplication.shared
        let defaults = UserDefaults(suiteName: "abel-panel-\(UUID().uuidString)")!
        let panel = AbelPanel(defaults: defaults)
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let spot = NSPoint(x: visible.minX + 100, y: visible.minY + 100)
        panel.setFrameOrigin(spot)
        #expect(defaults.string(forKey: AbelPanel.originKey) == NSStringFromPoint(spot))
        let again = AbelPanel(defaults: defaults)
        again.restoreOrigin()
        #expect(again.frame.origin == spot)
    }

    @Test func growsDownFromItsTopEdge() {
        _ = NSApplication.shared
        let panel = AbelPanel(defaults: UserDefaults(suiteName: "abel-panel-\(UUID().uuidString)")!)
        panel.setFrame(NSRect(x: 100, y: 500, width: 44, height: 44), display: false)
        panel.resize(to: NSSize(width: 340, height: 120))
        #expect(panel.frame.maxY == 544)
        #expect(panel.frame.minX == 100)
    }

    @Test func drawsInGraphitePaperAndInk() throws {
        let catalog = AbelPalette.themes(in: Self.resources)
        let ids = [ThemeCatalog.graphiteId, ThemeCatalog.paperId, ThemeCatalog.inkId]
        let palettes = ids.map { AbelPalette(theme: catalog.theme($0)) }
        #expect(Set(palettes.map(\.surface)).count == 3)
        #expect(palettes.map(\.isDark) == [true, false, true])
        for palette in palettes {
            for display in [AbelDisplay(), AbelDisplay(mode: .listening, words: "add a test"),
                            AbelDisplay(mode: .answering, answer: "Sidebar fix says: done.")] {
                let png = try #require(AbelSnapshot.png(display: display, palette: palette))
                let image = try #require(NSImage(data: png))
                #expect(image.size.width > (display.isExpanded ? 200 : 30))
            }
        }
    }
}
