import Foundation

/// ABEL's states and what moves it between them: idle, listening (to
/// push-to-talk or after the wake phrase), transcribing, speaking, and
/// paused (screen locked, screen shared, or by you). It decides; the
/// engine carries out the effects it returns. Pure, so every rule here
/// is tested without a microphone.
public struct AbelMachine: Sendable, Equatable {
    public enum Trigger: String, Sendable, Equatable {
        case pushToTalk, wakePhrase
    }

    public enum PauseReason: String, Sendable, Hashable, CaseIterable, Comparable {
        case locked, screenShared, byYou

        /// What ABEL says or shows while paused.
        public var sentence: String {
            switch self {
            case .locked: "ABEL is off while the screen is locked."
            case .screenShared: "ABEL is paused while your screen is shared."
            case .byYou: "ABEL is paused. Turn it back on from its menu."
            }
        }

        public static func < (a: Self, b: Self) -> Bool {
            allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
        }
    }

    public enum Phase: Sendable, Equatable {
        case idle
        case listening(Trigger)
        /// Push-to-talk let go: the last words are being finished.
        case transcribing(Trigger)
        case speaking
        case paused
    }

    public enum Event: Sendable, Equatable {
        case pushDown, pushUp, escape
        /// The wake listener heard "Hey Abel"; `command` is what followed it
        /// in the same breath, maybe nothing.
        case wake(command: String)
        /// The final words of what you said while ABEL listened.
        case heard(String)
        /// Nothing more was said after the wake phrase.
        case silence
        case speechStarted, speechFinished
        /// You talked over ABEL while it spoke.
        case talkedOver
        case locked(Bool)
        case screenShared(Bool)
        case pausedByYou(Bool)
        case wakePhraseSetting(Bool)
    }

    public enum Effect: Sendable, Equatable {
        /// Start taking the microphone's words as a request.
        case startCapture(Trigger)
        /// Finish the words heard so far; `heard` follows.
        case finishCapture
        /// Drop what was being heard.
        case cancelCapture
        case stopSpeaking
        /// Act on what you said.
        case handle(String, Trigger)
        case startWakeListener, stopWakeListener
        case expand, collapse
        /// Say (or show) why ABEL isn't listening.
        case explain(PauseReason)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var pauses: Set<PauseReason> = []
    public private(set) var wakePhraseOn: Bool

    public init(wakePhraseOn: Bool = false) {
        self.wakePhraseOn = wakePhraseOn
    }

    /// The effects to start with: the wake listener, when it's on.
    public var startEffects: [Effect] { wakePhraseOn && pauses.isEmpty ? [.startWakeListener] : [] }

    public var isPaused: Bool { !pauses.isEmpty }
    /// The reason shown first while paused.
    public var pauseReason: PauseReason? { pauses.min() }

    public mutating func send(_ event: Event) -> [Effect] {
        switch event {
        case let .locked(on): return setPause(.locked, on)
        case let .screenShared(on): return setPause(.screenShared, on)
        case let .pausedByYou(on): return setPause(.byYou, on)
        case let .wakePhraseSetting(on):
            guard on != wakePhraseOn else { return [] }
            wakePhraseOn = on
            guard !isPaused else { return [] }
            return [on ? .startWakeListener : .stopWakeListener]
        default:
            break
        }
        if isPaused {
            // Push-to-talk says why nothing happens; everything else is ignored.
            if event == .pushDown, let reason = pauseReason { return [.explain(reason)] }
            return []
        }
        switch (phase, event) {
        case (.idle, .pushDown):
            phase = .listening(.pushToTalk)
            return [.startCapture(.pushToTalk), .expand]
        case (.speaking, .pushDown):
            phase = .listening(.pushToTalk)
            return [.stopSpeaking, .startCapture(.pushToTalk), .expand]
        case (.listening(.wakePhrase), .pushDown):
            // Holding the key after the wake phrase: the key now decides when it ends.
            phase = .listening(.pushToTalk)
            return []
        case (.listening(.pushToTalk), .pushUp):
            phase = .transcribing(.pushToTalk)
            return [.finishCapture]
        case (.listening, .escape), (.transcribing, .escape):
            phase = .idle
            return [.cancelCapture, .collapse]
        case (.speaking, .escape):
            phase = .idle
            return [.stopSpeaking, .collapse]
        case (.idle, .wake(let command)), (.speaking, .wake(let command)):
            let stop: [Effect] = phase == .speaking ? [.stopSpeaking] : []
            let words = command.trimmingCharacters(in: .whitespacesAndNewlines)
            if words.isEmpty {
                phase = .listening(.wakePhrase)
                return stop + [.startCapture(.wakePhrase), .expand]
            }
            phase = .idle
            return stop + [.expand, .handle(words, .wakePhrase)]
        case (.listening(let trigger), .heard(let text)), (.transcribing(let trigger), .heard(let text)):
            phase = .idle
            let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return words.isEmpty ? [.collapse] : [.handle(words, trigger)]
        case (.listening(.wakePhrase), .silence):
            phase = .idle
            return [.cancelCapture, .collapse]
        case (.idle, .speechStarted), (.transcribing, .speechStarted):
            phase = .speaking
            return [.expand]
        case (.speaking, .speechFinished):
            phase = .idle
            return [.collapse]
        case (.speaking, .talkedOver):
            phase = .idle
            return [.stopSpeaking, .collapse]
        default:
            return []
        }
    }

    private mutating func setPause(_ reason: PauseReason, _ on: Bool) -> [Effect] {
        let wasPaused = isPaused
        if on { pauses.insert(reason) } else { pauses.remove(reason) }
        if on, !wasPaused {
            var effects: [Effect] = []
            switch phase {
            case .listening, .transcribing: effects.append(.cancelCapture)
            case .speaking: effects.append(.stopSpeaking)
            case .idle, .paused: break
            }
            phase = .paused
            if wakePhraseOn { effects.append(.stopWakeListener) }
            return effects + [.collapse]
        }
        if !on, wasPaused, !isPaused {
            phase = .idle
            return wakePhraseOn ? [.startWakeListener] : []
        }
        return []
    }
}
