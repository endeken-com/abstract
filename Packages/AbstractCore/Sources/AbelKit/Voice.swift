@preconcurrency import AVFoundation
import AbstractCore
import Foundation

/// How ABEL speaks. The engine only says what and stops; the real one is
/// the system synthesizer, tests use a fake.
@MainActor
public protocol AbelVoice: AnyObject {
    /// Called once the last thing said has finished (not when stopped).
    var onFinished: (() -> Void)? { get set }
    var isSpeaking: Bool { get }
    func speak(_ text: String, language: String)
    func stop()
}

/// `AVSpeechSynthesizer`, with the voice picked in Settings › ABEL or the
/// system's voice for the language. Started once at launch, since its
/// first sentence otherwise takes over a second (ABS-202 §3).
@MainActor
public final class SystemVoice: NSObject, AbelVoice, AVSpeechSynthesizerDelegate {
    public var onFinished: (() -> Void)?
    /// An `AVSpeechSynthesisVoice` identifier; nil picks by language.
    public var voiceIdentifier: String?
    private let synthesizer = AVSpeechSynthesizer()
    private var pending = 0

    public override init() {
        super.init()
        synthesizer.delegate = self
    }

    public var isSpeaking: Bool { synthesizer.isSpeaking }

    public func speak(_ text: String, language: String) {
        let utterance = Self.utterance(text, language: language, voice: voiceIdentifier)
        pending += 1
        synthesizer.speak(utterance)
    }

    public func stop() {
        pending = 0
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// Warms the synthesizer up without a sound.
    public func warmUp() {
        let utterance = AVSpeechUtterance(string: " ")
        utterance.volume = 0
        synthesizer.write(utterance) { _ in }
    }

    nonisolated static func utterance(_ text: String, language: String, voice: String?) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice.flatMap(AVSpeechSynthesisVoice.init(identifier:))
            .flatMap { $0.language.hasPrefix(String(language.prefix(2))) ? $0 : nil }
            ?? AVSpeechSynthesisVoice(language: language)
        utterance.prefersAssistiveTechnologySettings = false
        return utterance
    }

    /// The installed voices for ABEL's languages, best first, for Settings.
    public nonisolated static func voices(for languages: [String]) -> [(id: String, name: String, language: String)] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { voice in languages.contains { voice.language.hasPrefix(String($0.prefix(2))) } }
            .filter { !$0.voiceTraits.contains(.isNoveltyVoice) }
            .sorted { ($0.quality.rawValue, $1.name) > ($1.quality.rawValue, $0.name) }
            .map { ($0.identifier, $0.name, $0.language) }
    }

    /// Renders `text` into audio without playing it: how tests hear ABEL.
    public nonisolated static func render(_ text: String, language: String, voice: String? = nil) async -> AVAudioPCMBuffer? {
        let synthesizer = AVSpeechSynthesizer()
        let utterance = utterance(text, language: language, voice: voice)
        let collected = await withCheckedContinuation { (continuation: CheckedContinuation<[AVAudioPCMBuffer], Never>) in
            nonisolated(unsafe) var buffers: [AVAudioPCMBuffer] = []
            nonisolated(unsafe) var done = false
            synthesizer.write(utterance) { buffer in
                guard !done else { return }
                guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                    done = true
                    continuation.resume(returning: buffers)
                    return
                }
                buffers.append(pcm)
            }
        }
        _ = synthesizer
        guard let format = collected.first?.format else { return nil }
        let total = collected.reduce(0) { $0 + $1.frameLength }
        guard let joined = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total) else { return nil }
        for buffer in collected {
            let bytes = Int(buffer.frameLength) * Int(format.streamDescription.pointee.mBytesPerFrame)
            for channel in 0..<Int(format.channelCount) {
                if let from = buffer.floatChannelData?[channel], let to = joined.floatChannelData?[channel] {
                    memcpy(to + Int(joined.frameLength), from, bytes)
                } else if let from = buffer.int16ChannelData?[channel], let to = joined.int16ChannelData?[channel] {
                    memcpy(to + Int(joined.frameLength), from, bytes)
                }
            }
            joined.frameLength += buffer.frameLength
        }
        return joined
    }

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard self.pending > 0 else { return }
            self.pending -= 1
            if self.pending == 0 { self.onFinished?() }
        }
    }
}
