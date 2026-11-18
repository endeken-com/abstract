import AbstractCore
import Foundation
import Observation

/// How ABEL reaches Abstract: `AppLink` for real, a fake in tests.
public protocol AbstractConnection: Sendable {
    /// Abstract's answer; nil when it isn't open.
    func ask(_ request: AbelLink.Request) async -> AbelLink.Reply?
}

/// The Abstract that owns a data folder, over its `AppLink` socket.
public struct LinkedAbstract: AbstractConnection {
    public let storePath: String
    public init(storePath: String = Store.defaultPath()) { self.storePath = storePath }

    public func ask(_ request: AbelLink.Request) async -> AbelLink.Reply? {
        let storePath = storePath
        return await AbelLink.offThePool { AbelLink.ask(request, storePath: storePath) }
    }
}

/// What the floating panel shows.
public struct AbelDisplay: Sendable, Equatable {
    public enum Mode: String, Sendable, Equatable {
        case idle, listening, thinking, answering, paused
    }

    public var mode: Mode = .idle
    /// What ABEL heard, as it hears it.
    public var words = ""
    /// What ABEL answered or is saying.
    public var answer = ""
    /// Something to read in full before saying yes: an AppleScript (ABS-205).
    public var detail = ""

    public init(mode: Mode = .idle, words: String = "", answer: String = "", detail: String = "") {
        self.mode = mode; self.words = words; self.answer = answer; self.detail = detail
    }

    public var isExpanded: Bool { mode != .idle }
}

/// One thing ABEL heard, did or said, for its history and for
/// `Abel --simulate`'s report.
public struct AbelEvent: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable {
        case heard, did, said, refused
    }

    public var kind: Kind
    public var text: String
    public var at: Date

    public init(_ kind: Kind, _ text: String, at: Date = Date()) {
        self.kind = kind; self.text = text; self.at = at
    }
}

/// ABEL itself: hears through `ears`, speaks through `voice`, decides with
/// `AbelMachine`, and asks Abstract through `abstract`. Everything outside
/// it is a seam, so every rule here is tested with fakes.
@MainActor
@Observable
public final class AbelEngine {
    public internal(set) var display = AbelDisplay()
    public private(set) var settings: AbelSettings
    public private(set) var context: AbelLink.Context?
    /// Everything heard, done and said since launch, newest last.
    public private(set) var history: [AbelEvent] = []
    public private(set) var machine: AbelMachine

    @ObservationIgnored private let ears: any AbelEars
    @ObservationIgnored private let voice: any AbelVoice
    @ObservationIgnored let abstract: any AbstractConnection
    @ObservationIgnored var lastLanguage: String
    @ObservationIgnored private var collapseTask: Task<Void, Never>?
    /// Something ABEL read back and waits on "yes" for.
    @ObservationIgnored var pending: Pending?
    /// The reply being read, for "continue".
    @ObservationIgnored var reading: (text: SpeakableText, index: Int, chat: String)?
    /// The chats "what needs me" just read, in order: "approve" means the first.
    @ObservationIgnored var lastListed: [String] = []
    /// How long a read-back waits for "yes".
    @ObservationIgnored public var confirmationWindow: Duration = .seconds(10)

    struct Pending {
        var asked: Date
        var language: String
        /// Called once: true on a clear yes in time, false on anything else.
        var decide: @MainActor (Bool) async -> Void
    }
    /// How long the panel stays open after ABEL finishes speaking.
    @ObservationIgnored public var lingering: Duration = .seconds(4)
    /// ABEL's chimes; nil keeps it silent (tests).
    @ObservationIgnored public var sounds: (any AbelSounds)?
    /// How ABEL acts on other apps (ABS-205); nil leaves it unable to.
    @ObservationIgnored public var appControl: (any AppControlling)?
    /// Called when the settings Abstract handed over change, so they can be kept.
    @ObservationIgnored public var onSettings: ((AbelSettings) -> Void)?

    public init(ears: any AbelEars, voice: any AbelVoice, abstract: any AbstractConnection,
                settings: AbelSettings = AbelSettings()) {
        self.ears = ears
        self.voice = voice
        self.abstract = abstract
        self.settings = settings
        machine = AbelMachine(wakePhraseOn: settings.wakePhrase)
        lastLanguage = settings.languages.first ?? "en-US"
        ears.onWake = { [weak self] in self?.send(.wake(command: "")) }
        ears.onWords = { [weak self] words in self?.heardSoFar(words) }
        ears.onFinal = { [weak self] text, language in self?.heard(text, language: language) }
        ears.onSilence = { [weak self] in self?.send(.silence) }
        ears.onTalk = { [weak self] in self?.send(.talkedOver) }
        ears.onProblem = { [weak self] problem in self?.problem(problem) }
        voice.onFinished = { [weak self] in self?.spoke() }
    }

    /// Asks Abstract for its settings and starts the wake listener if it's on.
    public func start() async {
        await refreshContext()
        perform(machine.startEffects)
    }

    // MARK: Input

    /// The widget's Talk button: a tap starts listening, the next ends it.
    public func toggleListening() {
        if case .listening(.pushToTalk) = machine.phase { pushUp() } else { pushDown() }
    }

    /// Chats waiting on you, for the widget's badge.
    public var needsYouCount: Int { context?.chats.filter { $0.state == .needsYou }.count ?? 0 }

    /// The widget's bell: the first chat that needs you, in Abstract.
    /// False when Abstract isn't open, or nothing needs you.
    @discardableResult
    public func openWhatNeedsYou() async -> Bool {
        await refreshContext()
        guard let first = context?.chats.first(where: { $0.state == .needsYou }) else { return false }
        let reply = await abstract.ask(AbelLink.Request(kind: .open, chatId: first.id))
        if reply?.ok == true { record(.did, "Opened “\(first.title)”, asked by you") }
        return reply?.ok == true
    }

    /// The widget's pencil: Abstract's new chat screen. False when Abstract isn't open.
    @discardableResult
    public func openNewChat() async -> Bool {
        await abstract.ask(AbelLink.Request(kind: .newChat))?.ok == true
    }

    public func pushDown() { send(.pushDown) }
    public func pushUp() { send(.pushUp) }
    public func escape() { send(.escape) }

    public func screen(locked: Bool, shared: Bool) {
        send(.locked(locked))
        send(.screenShared(shared))
    }

    public func pause(_ on: Bool) { send(.pausedByYou(on)) }

    /// What you said, taken as if heard: `Abel --simulate` and tests.
    public func simulate(_ text: String, language: String? = nil, trigger: AbelMachine.Trigger = .pushToTalk) async {
        record(.heard, text)
        await handle(text, language: language ?? settings.languages.first ?? "en-US", trigger: trigger)
    }

    /// Whether ABEL is waiting for "yes" to something it read back.
    public var isWaitingForYes: Bool { pending != nil }

    // MARK: Abstract and `abstract` asking ABEL

    public func receive(_ request: AbelLink.HelperRequest) async -> AbelLink.HelperReply {
        switch request.kind {
        case .speak:
            guard let text = request.text else { return AbelLink.HelperReply(ok: false, message: "Nothing to say.") }
            guard !machine.isPaused else {
                return AbelLink.HelperReply(ok: false, message: machine.pauseReason?.sentence)
            }
            speakReply(text, chatTitle: request.chatTitle)
            return AbelLink.HelperReply(ok: true)
        case .status:
            return AbelLink.HelperReply(ok: true, state: stateSentence)
        case .reload:
            await refreshContext()
            return AbelLink.HelperReply(ok: true, state: stateSentence)
        case .history:
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let recent = Array(history.suffix(50))
            return AbelLink.HelperReply(ok: true, message: (try? encoder.encode(recent)).map { String(decoding: $0, as: UTF8.self) },
                                        state: stateSentence)
        case .tool:
            let outcome = await tool(request.name ?? "", arguments: request.text ?? "{}", from: request.chatId)
            return AbelLink.HelperReply(ok: !outcome.isError, message: outcome.text)
        case .hear:
            #if DEBUG
            guard let text = request.text else { return AbelLink.HelperReply(ok: false) }
            Task { await simulate(text, trigger: .wakePhrase) }
            return AbelLink.HelperReply(ok: true)
            #else
            return AbelLink.HelperReply(ok: false, message: "Only debug builds take a transcript.")
            #endif
        }
    }

    /// Whether ABEL may use the microphone; the real check by default.
    @ObservationIgnored public var microphoneAllowed: () -> Bool = { true }

    /// ABEL's state in a sentence, for Settings › ABEL and its menu.
    public var stateSentence: String {
        if let reason = machine.pauseReason { return reason.sentence }
        if !microphoneAllowed() { return "ABEL can't hear you yet: allow the microphone from ABEL's menu." }
        switch machine.phase {
        case .listening, .transcribing: return "Listening."
        case .speaking: return "Speaking."
        default:
            return settings.wakePhrase ? "Listening for “Hey Abel”, or hold ⌥Space." : "Hold ⌥Space to talk."
        }
    }

    // MARK: The machine

    func send(_ event: AbelMachine.Event) {
        let before = machine.isPaused
        perform(machine.send(event))
        if machine.isPaused != before {
            display = machine.isPaused ? AbelDisplay(mode: .paused, answer: machine.pauseReason?.sentence ?? "")
                : AbelDisplay()
        }
    }

    private func perform(_ effects: [AbelMachine.Effect]) {
        for effect in effects {
            switch effect {
            case let .startCapture(trigger):
                sounds?.play(.listen)
                collapseTask?.cancel()
                display = AbelDisplay(mode: .listening)
                ears.startCapture(trigger, languages: settings.languages, vocabulary: context?.vocabulary.contextualStrings ?? [])
            case .finishCapture:
                sounds?.play(.done)
                display.mode = .thinking
                ears.finishCapture()
            case .cancelCapture:
                ears.cancelCapture()
            case .stopSpeaking:
                voice.stop()
                ears.setBargeIn(false)
            case let .handle(text, trigger):
                record(.heard, text)
                display.words = text
                display.mode = .thinking
                Task { await handle(text, language: lastLanguage, trigger: trigger) }
            case .startWakeListener:
                ears.setWakeListening(true, languages: settings.languages, vocabulary: context?.vocabulary.contextualStrings ?? [])
            case .stopWakeListener:
                ears.setWakeListening(false, languages: settings.languages, vocabulary: [])
            case .expand:
                collapseTask?.cancel()
                if display.mode == .idle { display.mode = .listening }
            case .collapse:
                collapseSoon()
            case let .explain(reason):
                display = AbelDisplay(mode: .paused, answer: reason.sentence)
            }
        }
    }

    /// ABEL finished speaking: after a question, it listens for the answer.
    private func spoke() {
        send(.speechFinished)
        guard awaitingYes else { return }
        awaitingYes = false
        if settings.wakePhrase, !machine.isPaused { send(.wake(command: "")) }
    }

    private func heardSoFar(_ words: String) {
        guard display.mode == .listening else { return }
        display.words = words
    }

    private func heard(_ text: String, language: String) {
        lastLanguage = language
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            send(.heard(""))
            if !machine.isPaused { say(AbelPhrases(language: language).notHeard) }
            return
        }
        send(.heard(text))
    }

    private func collapseSoon(after delay: Duration? = nil) {
        collapseTask?.cancel()
        let wait = delay ?? lingering
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self, !self.machine.isPaused, self.machine.phase == .idle else { return }
            self.display = AbelDisplay()
        }
    }

    // MARK: Doing what was said

    func handle(_ text: String, language: String, trigger: AbelMachine.Trigger) async {
        lastLanguage = language
        if let waiting = pending {
            pending = nil
            let yes = AbelConfirmation.isYes(text)
                && Date().timeIntervalSince(waiting.asked) < Double(confirmationWindow.components.seconds)
            await waiting.decide(yes)
            return
        }
        await refreshContext()
        guard let context else { say(AbelPhrases(language: language).abstractClosed); return }
        // Holding the key over a chat in Abstract dictates into it; a
        // command then starts with "Abel", or is one needing no name.
        let dictating = trigger == .pushToTalk && context.isFrontmost && context.shownChatId != nil
        if dictating {
            let words = AbelText.words(text)
            if words.first == "abel" {
                await command(WakePhrase.strippingWake(text), language: language, trigger: trigger)
                return
            }
            if !AbelGrammar.isBareCommand(text) || AbelRouter.isSendIt(text) {
                await dictate(text, language: language, trigger: trigger)
                return
            }
        }
        await command(text, language: language, trigger: trigger)
    }

    /// Dictation and "send it", for the chat on screen (ABS-203).
    func dictate(_ text: String, language: String, trigger: AbelMachine.Trigger) async {
        switch AbelRouter.route(text, context: context, language: language) {
        case let .dictate(chatId, words):
            let reply = await abstract.ask(AbelLink.Request(kind: .dictate, chatId: chatId, text: words))
            finish(reply, done: { AbelPhrases(language: language).dictated($0) }, record: "Put “\(words)” in the reply box")
        case let .sendDraft(chatId):
            let send: @MainActor () async -> Void = { [weak self] in
                guard let self else { return }
                let reply = await self.abstract.ask(AbelLink.Request(kind: .sendDraft, chatId: chatId))
                self.finish(reply, done: { AbelPhrases(language: language).sent($0) }, record: "Sent the reply box")
            }
            // Holding the key is you; the wake phrase could be a TV. Sending
            // on the wake phrase is read back and needs "yes".
            if trigger == .wakePhrase {
                ask(AbelPhrases(language: language).confirmSend(context?.shownChatTitle ?? "the chat"), language: language) { yes in
                    if yes { await send() } else { self.cancelled(language) }
                }
            } else {
                await send()
            }
        case let .say(sentence):
            say(sentence)
        }
    }

    func finish(_ reply: AbelLink.Reply?, done: (String) -> String, record what: String) {
        guard let reply else { say(AbelPhrases(language: lastLanguage).abstractClosed); return }
        guard reply.ok else { say(reply.message ?? "That didn't work."); return }
        let chat = reply.chatTitle ?? "the chat"
        record(.did, "\(what) of “\(chat)”, asked by you")
        // Dictation shows, quietly: the words are already on screen.
        display = AbelDisplay(mode: .answering, words: display.words, answer: done(chat))
        collapseSoon()
    }

    /// Reads `question` back and waits for "yes": the next thing you say,
    /// with the key or, with the wake phrase on, without it.
    func ask(_ question: String, language: String, then decide: @escaping @MainActor (Bool) async -> Void) {
        pending = Pending(asked: Date(), language: language, decide: decide)
        say(question)
        awaitingYes = true
    }

    /// Nothing was done, and ABEL says so.
    func cancelled(_ language: String) {
        record(.refused, "Didn't hear yes, so nothing was done")
        say(AbelPhrases(language: language).cancelled)
    }

    @ObservationIgnored private var awaitingYes = false

    /// Says `sentence` and shows it.
    public func say(_ sentence: String) {
        record(.said, sentence)
        display.answer = sentence
        display.mode = .answering
        send(.speechStarted)
        ears.setBargeIn(true)
        voice.speak(sentence, language: lastLanguage)
    }

    /// A chat's reply read aloud: its first paragraph, Markdown read as words.
    func speakReply(_ markdown: String, chatTitle: String?) {
        let speakable = SpeakableText(markdown: markdown)
        guard let first = speakable.first else { return }
        let phrases = AbelPhrases(language: settings.languages.first ?? "en-US")
        lastLanguage = settings.languages.first ?? "en-US"
        say(chatTitle.map { "\(phrases.replied($0)) \(first)" } ?? first)
    }

    private func problem(_ message: String) {
        sounds?.play(.problem)
        record(.refused, message)
        send(.escape)
        say(message)
    }

    func record(_ kind: AbelEvent.Kind, _ text: String) {
        history.append(AbelEvent(kind, text))
        if history.count > 500 { history.removeFirst(history.count - 500) }
    }

    // MARK: Abstract

    public func refreshContext() async {
        let reply = await abstract.ask(AbelLink.Request(kind: .context))
        context = reply?.context
        guard let fresh = reply?.context?.settings, fresh != settings else { return }
        let wakeChanged = fresh.wakePhrase != settings.wakePhrase
        let languagesChanged = fresh.languages != settings.languages
        settings = fresh
        onSettings?(fresh)
        if wakeChanged {
            send(.wakePhraseSetting(fresh.wakePhrase))
        } else if languagesChanged, fresh.wakePhrase, !machine.isPaused {
            ears.setWakeListening(false, languages: fresh.languages, vocabulary: [])
            ears.setWakeListening(true, languages: fresh.languages, vocabulary: context?.vocabulary.contextualStrings ?? [])
        }
    }

    /// Settings kept from last time, used until Abstract answers.
    public func use(_ kept: AbelSettings) {
        settings = kept
        machine = AbelMachine(wakePhraseOn: kept.wakePhrase)
    }
}
