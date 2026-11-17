@preconcurrency import AVFoundation
import AbstractCore
import Foundation
@preconcurrency import Speech

/// Words the recognizer heard, in one of ABEL's languages.
public struct Heard: Sendable, Equatable {
    public var text: String
    public var isFinal: Bool
    public var locale: String
    /// The recognizer's mean confidence, 0 to 1; nil when it gave none.
    public var confidence: Double?

    public init(text: String, isFinal: Bool, locale: String, confidence: Double? = nil) {
        self.text = text; self.isFinal = isFinal; self.locale = locale; self.confidence = confidence
    }
}

/// What came of one stretch of speech, in the language that fit it best.
public struct Transcript: Sendable, Equatable {
    public var text: String
    public var locale: String
    public var confidence: Double?
    /// Every language's version, for the record and for tests.
    public var all: [String: String]

    public init(text: String, locale: String, confidence: Double?, all: [String: String]) {
        self.text = text; self.locale = locale; self.confidence = confidence; self.all = all
    }

    /// The language whose words the recognizer was surest of. One that
    /// heard nothing never wins over one that heard something.
    public static func best(of finals: [(locale: String, text: String, confidence: Double?)], order: [String]) -> Transcript {
        let all = Dictionary(finals.map { ($0.locale, $0.text) }, uniquingKeysWith: { $1 })
        let spoken = finals.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let pick = spoken.max { a, b in
            let ca = a.confidence ?? 0, cb = b.confidence ?? 0
            if ca != cb { return ca < cb }
            // Ties go to the earlier language in the settings.
            return (order.firstIndex(of: a.locale) ?? .max) > (order.firstIndex(of: b.locale) ?? .max)
        }
        guard let pick else { return Transcript(text: "", locale: order.first ?? "en-US", confidence: nil, all: all) }
        return Transcript(text: pick.text.trimmingCharacters(in: .whitespacesAndNewlines), locale: pick.locale,
                          confidence: pick.confidence, all: all)
    }
}

/// Apple's on-device recognizer (`SpeechAnalyzer`, macOS 26), one per
/// language, all fed the same audio. Nothing it hears leaves the Mac, and
/// it needs no Speech Recognition permission (ABS-202 §1).
@available(macOS 26, *)
public actor TranscriptionSession {
    public let locales: [String]
    private var lanes: [Lane] = []
    private var finals: [String: [(text: String, confidence: Double?)]] = [:]
    private var readers: [Task<Void, Never>] = []
    private let updates: AsyncStream<Heard>.Continuation
    /// Every result as it comes, volatile and final, from every language.
    public nonisolated let heard: AsyncStream<Heard>

    private struct Lane {
        var locale: String
        var analyzer: SpeechAnalyzer
        var transcriber: SpeechTranscriber
        var input: AsyncStream<AnalyzerInput>.Continuation
        var format: AVAudioFormat
        var converter: AVAudioConverter?
        var converterFrom: AVAudioFormat?
    }

    /// Sets up a recognizer for each of `locales`. `live` asks for the
    /// words as they come (for the panel and the wake phrase), not only
    /// the final ones. Throws when a language's model can't be had.
    public init(locales: [String], contextualStrings: [String] = [], live: Bool = true) async throws {
        self.locales = locales
        (heard, updates) = AsyncStream<Heard>.makeStream()
        for locale in locales {
            let transcriber = SpeechTranscriber(locale: Locale(identifier: locale), transcriptionOptions: [],
                                                reportingOptions: live ? [.volatileResults, .fastResults] : [],
                                                attributeOptions: [.transcriptionConfidence])
            try await Self.ensureModel(for: transcriber)
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            if !contextualStrings.isEmpty {
                let context = AnalysisContext()
                context.contextualStrings[.general] = contextualStrings
                try? await analyzer.setContext(context)
            }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                throw AbelError("The recognizer has no audio format for \(locale).")
            }
            let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
            try await analyzer.start(inputSequence: stream)
            lanes.append(Lane(locale: locale, analyzer: analyzer, transcriber: transcriber, input: input, format: format))
        }
        for lane in lanes { startReading(lane) }
    }

    /// Downloads the language's on-device model once if it's missing:
    /// Apple's model comes down, no audio goes up.
    static func ensureModel(for transcriber: SpeechTranscriber) async throws {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }

    /// Whether `locale`'s model is already on this Mac.
    public static func isInstalled(_ locale: String) async -> Bool {
        await SpeechTranscriber.installedLocales.contains { $0.identifier(.bcp47) == locale }
    }

    private func startReading(_ lane: Lane) {
        let transcriber = lane.transcriber
        let locale = lane.locale
        readers.append(Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    let confidence = Self.confidence(of: result.text)
                    await self?.received(Heard(text: text, isFinal: result.isFinal, locale: locale, confidence: confidence))
                }
            } catch {
                // A cancelled or failed lane just stops adding words.
            }
        })
    }

    private func received(_ heard: Heard) {
        if heard.isFinal { finals[heard.locale, default: []].append((heard.text, heard.confidence)) }
        updates.yield(heard)
    }

    nonisolated static func confidence(of text: AttributedString) -> Double? {
        var total = 0.0, weight = 0.0
        for run in text.runs {
            guard let value = run.transcriptionConfidence else { continue }
            let length = Double(text[run.range].characters.count)
            total += value * length
            weight += length
        }
        return weight > 0 ? total / weight : nil
    }

    /// Feeds one buffer of audio, in any format, to every language.
    public func append(_ buffer: AVAudioPCMBuffer) {
        for index in lanes.indices {
            let converted = convert(buffer, lane: index)
            guard let converted else { continue }
            lanes[index].input.yield(AnalyzerInput(buffer: converted))
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer, lane index: Int) -> AVAudioPCMBuffer? {
        let target = lanes[index].format
        if buffer.format == target { return buffer }
        if lanes[index].converter == nil || lanes[index].converterFrom != buffer.format {
            lanes[index].converter = AVAudioConverter(from: buffer.format, to: target)
            lanes[index].converterFrom = buffer.format
        }
        guard let converter = lanes[index].converter else { return nil }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        nonisolated(unsafe) var given = false
        nonisolated(unsafe) let source = buffer
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if given { outStatus.pointee = .noDataNow; return nil }
            given = true
            outStatus.pointee = .haveData
            return source
        }
        return status == .error || output.frameLength == 0 ? nil : output
    }

    /// Ends the audio, waits for every language's last words, and returns
    /// the language that fit best.
    public func finish() async -> Transcript {
        for lane in lanes {
            lane.input.finish()
            try? await lane.analyzer.finalizeAndFinishThroughEndOfInput()
        }
        for reader in readers { await reader.value }
        updates.finish()
        return Transcript.best(of: locales.map { locale in
            let parts = finals[locale] ?? []
            let text = parts.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            let scored = parts.compactMap(\.confidence)
            return (locale, text, scored.isEmpty ? nil : scored.reduce(0, +) / Double(scored.count))
        }, order: locales)
    }

    /// The final words so far, per language, and forgets them: the wake
    /// listener takes each sentence once.
    public func takeFinals() -> [String: String] {
        let taken = finals.mapValues { $0.map(\.text).joined() }
        finals = [:]
        return taken
    }

    /// Stops listening without waiting for words.
    public func cancel() async {
        for lane in lanes {
            lane.input.finish()
            await lane.analyzer.cancelAndFinishNow()
        }
        for reader in readers { reader.cancel() }
        updates.finish()
    }

    /// Transcribes a whole audio file: tests and `Abel --simulate-audio`.
    public static func transcribe(file url: URL, locales: [String], contextualStrings: [String] = []) async throws -> Transcript {
        let session = try await TranscriptionSession(locales: locales, contextualStrings: contextualStrings, live: false)
        let file = try AVAudioFile(forReading: url)
        let frames: AVAudioFrameCount = 4_096
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { break }
            try file.read(into: buffer, frameCount: frames)
            if buffer.frameLength == 0 { break }
            await session.append(buffer)
        }
        return await session.finish()
    }
}

/// A failure ABEL can say in a sentence.
public struct AbelError: Error, LocalizedError, Sendable, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
