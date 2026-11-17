@preconcurrency import AVFoundation
import AbstractCore
import Foundation

/// Ears that hear nothing by themselves: what's said comes from
/// `AbelEngine.simulate`. For `Abel --simulate` and tests.
@MainActor
public final class QuietEars: AbelEars {
    public var onWake: (() -> Void)?
    public var onWords: ((String) -> Void)?
    public var onFinal: ((String, String) -> Void)?
    public var onSilence: (() -> Void)?
    public var onTalk: (() -> Void)?
    public var onProblem: ((String) -> Void)?

    /// What the engine asked of the ears, in order, for tests.
    public private(set) var calls: [String] = []
    public private(set) var wakeListening = false
    public private(set) var capturing = false
    public private(set) var bargeIn = false
    /// What `finishCapture` hands back as heard.
    public var nextFinal: (text: String, language: String)?

    public init() {}

    public func setWakeListening(_ on: Bool, languages: [String], vocabulary: [String]) {
        wakeListening = on
        calls.append(on ? "wake on \(languages.joined(separator: ","))" : "wake off")
    }

    public func startCapture(_ trigger: AbelMachine.Trigger, languages: [String], vocabulary: [String]) {
        capturing = true
        calls.append("capture \(trigger.rawValue)")
    }

    public func finishCapture() {
        capturing = false
        calls.append("finish")
        let final = nextFinal ?? ("", "en-US")
        nextFinal = nil
        onFinal?(final.text, final.language)
    }

    public func cancelCapture() {
        capturing = false
        calls.append("cancel")
    }

    public func setBargeIn(_ on: Bool) {
        bargeIn = on
    }
}

/// A voice that writes down what it would say, and finishes at once (or
/// when told to). With `renderTo`, each sentence is also synthesized
/// into a sound file there, proving the real synthesizer speaks it.
@MainActor
public final class RecordingVoice: AbelVoice {
    public var onFinished: (() -> Void)?
    public private(set) var spoken: [(text: String, language: String)] = []
    public private(set) var isSpeaking = false
    public private(set) var stops = 0
    /// Finish each sentence by itself; off leaves it speaking until `finish()`.
    public var finishesAtOnce: Bool
    public var renderTo: URL?

    public init(finishesAtOnce: Bool = true, renderTo: URL? = nil) {
        self.finishesAtOnce = finishesAtOnce
        self.renderTo = renderTo
    }

    public func speak(_ text: String, language: String) {
        spoken.append((text, language))
        isSpeaking = true
        if let renderTo {
            let index = spoken.count
            Task {
                guard let buffer = await SystemVoice.render(text, language: language) else { return }
                let url = renderTo.appendingPathComponent(String(format: "said-%02d.caf", index))
                if let file = try? AVAudioFile(forWriting: url, settings: buffer.format.settings) { try? file.write(from: buffer) }
            }
        }
        if finishesAtOnce { Task { @MainActor in self.finish() } }
    }

    public func finish() {
        guard isSpeaking else { return }
        isSpeaking = false
        onFinished?()
    }

    public func stop() {
        stops += 1
        isSpeaking = false
    }
}

/// `Abel --simulate`: says each transcript to ABEL in turn, against a
/// running Abstract, and reports what ABEL heard, did and said.
@MainActor
public enum AbelSimulation {
    public struct Report: Codable, Sendable {
        public var events: [AbelEvent]
        public var spoken: [String]
        /// The panel's mode after each step.
        public var panel: [String]
    }

    public static func run(_ transcripts: [String], language: String, abstract: any AbstractConnection,
                           renderTo: URL? = nil) async -> Report {
        let voice = RecordingVoice(renderTo: renderTo)
        let engine = AbelEngine(ears: QuietEars(), voice: voice, abstract: abstract)
        engine.lingering = .milliseconds(10)
        await engine.start()
        var panel: [String] = []
        for transcript in transcripts {
            await engine.simulate(transcript, language: language)
            panel.append(engine.display.mode.rawValue)
            // Let a reply that's being spoken settle.
            try? await Task.sleep(for: .milliseconds(50))
        }
        return Report(events: engine.history, spoken: voice.spoken.map(\.text), panel: panel)
    }
}
