@preconcurrency import AVFoundation
import AbstractCore
import Foundation

/// How ABEL hears. The engine starts and stops listening; the real ears
/// are the microphone and the on-device recognizer, tests use a fake.
@MainActor
public protocol AbelEars: AnyObject {
    /// "Hey Abel" was heard. The command follows as `onFinal`.
    var onWake: (() -> Void)? { get set }
    /// The words so far while capturing, for the panel.
    var onWords: ((String) -> Void)? { get set }
    /// The finished request and the language it was in.
    var onFinal: ((String, String) -> Void)? { get set }
    /// Nothing was said after the wake phrase.
    var onSilence: (() -> Void)? { get set }
    /// You spoke over ABEL while it talked.
    var onTalk: (() -> Void)? { get set }
    /// Something went wrong that ABEL should say.
    var onProblem: ((String) -> Void)? { get set }

    func setWakeListening(_ on: Bool, languages: [String], vocabulary: [String])
    func startCapture(_ trigger: AbelMachine.Trigger, languages: [String], vocabulary: [String])
    func finishCapture()
    func cancelCapture()
    /// Listen for you talking over ABEL while it speaks.
    func setBargeIn(_ on: Bool)
}

/// Where audio comes from: the microphone, or a file in tests and simulations.
@MainActor
public protocol AudioSource: AnyObject {
    var isRunning: Bool { get }
    func start(_ handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws
    func stop()
}

/// The Mac's microphone, through `AVAudioEngine`. macOS shows its
/// indicator whenever this runs; nothing it hears is written anywhere.
@MainActor
public final class MicrophoneSource: AudioSource {
    private var engine: AVAudioEngine?
    public private(set) var isRunning = false

    public init() {}

    /// Whether ABEL may use the microphone; asks the first time.
    public static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    public static var isAuthorized: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    /// macOS hasn't asked yet: asking now shows its prompt.
    public static var canAsk: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined }

    /// The microphone's state for ABEL, in words for its menu.
    public static var stateTitle: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: "Microphone: allowed"
        case .notDetermined: "Microphone: not asked yet"
        case .restricted: "Microphone: blocked by this Mac's settings"
        default: "Microphone: turned off"
        }
    }

    /// Forgets the answer macOS has stored for ABEL, so the next request asks
    /// again. Only ABEL's own microphone entry is touched.
    @discardableResult
    public static func resetDecision(bundleIdentifier: String = AbelLink.bundleIdentifier) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Microphone", bundleIdentifier]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// Privacy & Security › Microphone, where a microphone turned down is turned back on.
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!

    /// What ABEL says when it can't hear you, and where to fix it.
    public static let deniedSentence = "ABEL can't hear you: turn on Abel in System Settings › Privacy & Security › Microphone."

    public func start(_ handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        guard !isRunning else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        // Cancels ABEL's own voice from what it hears, so it can listen while it talks.
        try? input.setVoiceProcessingEnabled(true)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw AbelError("There's no microphone to listen with.") }
        input.installTap(onBus: 0, bufferSize: 2_048, format: format) { buffer, _ in handler(buffer) }
        engine.prepare()
        try engine.start()
        self.engine = engine
        isRunning = true
    }

    public func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isRunning = false
    }
}

/// An audio file played into ABEL as if it were the microphone, at real
/// speed or as fast as it reads: `Abel --simulate-audio` and tests.
@MainActor
public final class FileAudioSource: AudioSource {
    public let urls: [URL]
    public let realTime: Bool
    /// Silence after each file, in seconds, so each is its own sentence.
    public let gap: Double
    public private(set) var isRunning = false
    private var task: Task<Void, Never>?
    public var onEnd: (() -> Void)?

    /// After the last file, keep sending silence until stopped, as a
    /// microphone would: the recognizer ends a sentence only once it hears
    /// the quiet after it.
    public let holdsOpen: Bool

    public init(urls: [URL], realTime: Bool = true, gap: Double = 1.5, holdsOpen: Bool = false) {
        self.urls = urls; self.realTime = realTime; self.gap = gap; self.holdsOpen = holdsOpen
    }

    public func start(_ handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        guard !isRunning else { return }
        let files = try urls.map { try AVAudioFile(forReading: $0) }
        isRunning = true
        let realTime = realTime, gap = gap, holdsOpen = holdsOpen
        let opened = files
        task = Task { [weak self] in
            for file in opened {
                let format = file.processingFormat
                let chunk = AVAudioFrameCount(format.sampleRate / 10)
                while file.framePosition < file.length, !Task.isCancelled {
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk),
                          (try? file.read(into: buffer, frameCount: chunk)) != nil, buffer.frameLength > 0 else { break }
                    handler(buffer)
                    if realTime { try? await Task.sleep(for: .milliseconds(100)) }
                }
                if let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate * gap)) {
                    silence.frameLength = silence.frameCapacity
                    for channel in 0..<Int(format.channelCount) {
                        if let data = silence.floatChannelData?[channel] { data.update(repeating: 0, count: Int(silence.frameLength)) }
                    }
                    handler(silence)
                    if realTime { try? await Task.sleep(for: .seconds(gap)) }
                }
            }
            self?.onEnd?()
            if holdsOpen, let format = opened.last?.processingFormat {
                while !Task.isCancelled {
                    guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate / 10)) else { break }
                    silence.frameLength = silence.frameCapacity
                    for channel in 0..<Int(format.channelCount) {
                        if let data = silence.floatChannelData?[channel] { data.update(repeating: 0, count: Int(silence.frameLength)) }
                    }
                    handler(silence)
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            self?.isRunning = false
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        isRunning = false
    }
}

/// Hands each buffer of audio to every listening session, in order,
/// straight from the audio thread: one stream per session, so nothing
/// hops through tasks that could reorder it.
final class AudioFanOut: @unchecked Sendable {
    private let lock = NSLock()
    private var outputs: [String: AsyncStream<AVAudioPCMBuffer>.Continuation] = [:]

    func add(_ name: String) -> AsyncStream<AVAudioPCMBuffer> {
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream(bufferingPolicy: .bufferingNewest(1_000))
        lock.withLock { outputs[name] = continuation }
        return stream
    }

    func remove(_ name: String) {
        lock.withLock { outputs.removeValue(forKey: name) }?.finish()
    }

    func send(_ buffer: AVAudioPCMBuffer) {
        let current = lock.withLock { Array(outputs.values) }
        for output in current { output.yield(buffer) }
    }

    var isEmpty: Bool { lock.withLock { outputs.isEmpty } }
}

/// The real ears: one audio source and `TranscriptionSession`s on it. The
/// wake listener runs while the wake phrase is on; push-to-talk opens a
/// session of its own; while ABEL speaks, any words count as talking over it.
@available(macOS 26, *)
@MainActor
public final class DeviceEars: AbelEars {
    public var onWake: (() -> Void)?
    public var onWords: ((String) -> Void)?
    public var onFinal: ((String, String) -> Void)?
    public var onSilence: (() -> Void)?
    public var onTalk: (() -> Void)?
    public var onProblem: ((String) -> Void)?

    private let source: any AudioSource
    private let silenceAfterWake: Duration
    private let fanOut = AudioFanOut()
    private var wake: Listening?
    private var capture: Listening?
    private var startingWake = false
    private var wakeOn = false
    private var bargeIn = false
    /// After the wake phrase: the next words are the command.
    private var awaitingCommand = false
    private var silenceTimer: Task<Void, Never>?
    private var lastWakeAt = Date.distantPast
    private var languages: [String] = ["en-US"]
    private var vocabulary: [String] = []
    private var captureGeneration = 0

    /// One session on the audio: what feeds it, and what reads its words.
    private struct Listening {
        var name: String
        var session: TranscriptionSession
        var feeder: Task<Void, Never>
        var reader: Task<Void, Never>
    }

    public init(source: any AudioSource, silenceAfterWake: Duration = .seconds(8)) {
        self.source = source
        self.silenceAfterWake = silenceAfterWake
    }

    public func setWakeListening(_ on: Bool, languages: [String], vocabulary: [String]) {
        self.languages = languages
        self.vocabulary = vocabulary
        wakeOn = on
        if on { startWakeSession() } else if !bargeIn { stopWakeSession() }
    }

    public func startCapture(_ trigger: AbelMachine.Trigger, languages: [String], vocabulary: [String]) {
        self.languages = languages
        self.vocabulary = vocabulary
        if trigger == .wakePhrase {
            // The wake listener's next words are the command.
            awaitingCommand = true
            restartSilenceTimer()
            return
        }
        awaitingCommand = false
        silenceTimer?.cancel()
        captureGeneration += 1
        let generation = captureGeneration
        Task {
            // The microphone first: asking can't wait on the recognizer, which might not start.
            if source is MicrophoneSource, !MicrophoneSource.isAuthorized {
                guard await MicrophoneSource.requestAccess() else {
                    onProblem?(MicrophoneSource.deniedSentence)
                    return
                }
            }
            do {
                let listening = try await listen("capture", languages: languages, vocabulary: vocabulary) { [weak self] heard in
                    if !heard.text.isEmpty { self?.onWords?(heard.text) }
                }
                // Let go before it was ready: drop it.
                guard generation == captureGeneration else { await close(listening); return }
                capture = listening
                updateSource()
            } catch {
                onProblem?(error.localizedDescription)
            }
        }
    }

    public func finishCapture() {
        let generation = captureGeneration
        Task {
            // Push-to-talk can be let go before the recognizer is ready.
            for _ in 0..<100 where capture == nil && generation == captureGeneration {
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard let listening = capture else { onFinal?("", languages.first ?? "en-US"); return }
            capture = nil
            fanOut.remove(listening.name)
            await listening.feeder.value
            let transcript = await listening.session.finish()
            listening.reader.cancel()
            updateSource()
            onFinal?(transcript.text, transcript.locale)
        }
    }

    public func cancelCapture() {
        awaitingCommand = false
        silenceTimer?.cancel()
        captureGeneration += 1
        if let listening = capture {
            capture = nil
            Task { await close(listening) }
        }
        updateSource()
    }

    public func setBargeIn(_ on: Bool) {
        // Talking over ABEL needs the microphone already allowed: speaking
        // a reply never asks for it.
        bargeIn = on && (mayListenUnasked || wakeOn)
        if bargeIn { startWakeSession() } else if !wakeOn { stopWakeSession() }
    }

    /// The microphone is allowed already (or this isn't the microphone).
    private var mayListenUnasked: Bool { !(source is MicrophoneSource) || MicrophoneSource.isAuthorized }

    // MARK: Sessions

    private func listen(_ name: String, languages: [String], vocabulary: [String],
                        heard: @escaping @MainActor (Heard) -> Void) async throws -> Listening {
        let session = try await TranscriptionSession(locales: languages, contextualStrings: vocabulary)
        let audio = fanOut.add(name)
        let feeder = Task.detached {
            for await buffer in audio {
                nonisolated(unsafe) let buffer = buffer
                await session.append(buffer)
            }
        }
        let reader = Task { @MainActor in
            for await result in session.heard { heard(result) }
        }
        return Listening(name: name, session: session, feeder: feeder, reader: reader)
    }

    private func close(_ listening: Listening) async {
        fanOut.remove(listening.name)
        listening.feeder.cancel()
        listening.reader.cancel()
        await listening.session.cancel()
        updateSource()
    }

    // MARK: The microphone

    private func updateSource() {
        let needed = wake != nil || capture != nil
        if needed, !source.isRunning {
            if !mayListenUnasked {
                // Only listening you asked for asks for the microphone.
                guard capture != nil || wakeOn else { return }
                Task {
                    if await MicrophoneSource.requestAccess() { self.updateSource() } else {
                        self.onProblem?(MicrophoneSource.deniedSentence)
                    }
                }
                return
            }
            let fanOut = fanOut
            do {
                try source.start { buffer in fanOut.send(buffer) }
            } catch {
                onProblem?(error.localizedDescription)
            }
        } else if !needed, source.isRunning {
            source.stop()
        }
    }

    // MARK: The wake listener

    private func startWakeSession() {
        guard wake == nil, !startingWake else { return }
        startingWake = true
        let languages = languages, vocabulary = vocabulary
        Task {
            defer { startingWake = false }
            do {
                let listening = try await listen("wake", languages: languages, vocabulary: vocabulary) { [weak self] heard in
                    self?.wakeHeard(heard)
                }
                guard wakeOn || bargeIn else { await close(listening); return }
                wake = listening
                updateSource()
            } catch {
                onProblem?(error.localizedDescription)
            }
        }
    }

    private func stopWakeSession() {
        guard let listening = wake else { return }
        wake = nil
        Task { await close(listening) }
    }

    private func wakeHeard(_ heard: Heard) {
        let text = heard.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, capture == nil else { return }
        let match = wakeOn ? WakePhrase.match(text, locale: heard.locale) : nil
        if bargeIn, !awaitingCommand, match == nil, AbelText.words(text).count >= 2 {
            onTalk?()
            return
        }
        if let match {
            if !awaitingCommand, Date().timeIntervalSince(lastWakeAt) > 2 {
                lastWakeAt = Date()
                onWake?()
            }
            guard heard.isFinal else { onWords?(match.command); return }
            if !match.command.isEmpty { deliver(match.command, heard.locale) }
            return
        }
        guard awaitingCommand else { return }
        let command = WakePhrase.strippingWake(text)
        if heard.isFinal { deliver(command, heard.locale) } else { onWords?(command); restartSilenceTimer() }
    }

    private func deliver(_ command: String, _ locale: String) {
        guard awaitingCommand else { return }
        awaitingCommand = false
        silenceTimer?.cancel()
        onFinal?(command, locale)
    }

    private func restartSilenceTimer() {
        silenceTimer?.cancel()
        let wait = silenceAfterWake
        silenceTimer = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self, self.awaitingCommand else { return }
            self.awaitingCommand = false
            self.onSilence?()
        }
    }
}
