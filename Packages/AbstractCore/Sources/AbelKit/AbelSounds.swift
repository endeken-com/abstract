@preconcurrency import AVFoundation
import Foundation

/// ABEL's sound: short 8-bit chimes, in step with its pixel look, so you
/// know it heard you without looking. Synthesized on the Mac; nothing is
/// played from a file.
@MainActor
public protocol AbelSounds: AnyObject {
    func play(_ cue: AbelCue)
}

public enum AbelCue: String, Sendable, CaseIterable {
    /// Started listening: two notes rising.
    case listen
    /// Stopped listening: two notes falling.
    case done
    /// Something went wrong: a low double blip.
    case problem
}

@MainActor
public final class ChipChimes: AbelSounds {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    public var volume: Float = 0.22

    public init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    public func play(_ cue: AbelCue) {
        guard let buffer = Self.render(cue, format: format, volume: volume) else { return }
        if !engine.isRunning { try? engine.start() }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        if !player.isPlaying { player.play() }
    }

    /// The notes of each cue, as (frequency, seconds).
    public static func notes(_ cue: AbelCue) -> [(Double, Double)] {
        switch cue {
        case .listen: [(659.25, 0.07), (987.77, 0.11)]
        case .done: [(987.77, 0.07), (659.25, 0.11)]
        case .problem: [(196.0, 0.08), (0, 0.04), (196.0, 0.1)]
        }
    }

    /// A soft square-ish wave (a sine with a little of its third harmonic),
    /// each note with a quick attack and a short fade so nothing clicks.
    public static func render(_ cue: AbelCue, format: AVAudioFormat, volume: Float) -> AVAudioPCMBuffer? {
        let rate = format.sampleRate
        let notes = notes(cue)
        let total = AVAudioFrameCount(notes.reduce(0) { $0 + $1.1 } * rate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total), let out = buffer.floatChannelData?[0]
        else { return nil }
        var frame = 0
        for (frequency, seconds) in notes {
            let count = Int(seconds * rate)
            for i in 0..<count {
                let t = Double(i) / rate
                let envelope = min(1, t / 0.006) * min(1, (seconds - t) / 0.03)
                let wave = frequency == 0 ? 0 : sin(2 * .pi * frequency * t) + 0.3 * sin(6 * .pi * frequency * t)
                out[frame + i] = Float(wave * envelope) * volume
            }
            frame += count
        }
        buffer.frameLength = AVAudioFrameCount(frame)
        return buffer
    }
}
