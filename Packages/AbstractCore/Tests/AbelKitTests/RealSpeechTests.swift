@preconcurrency import AVFoundation
import AbelKit
import AbstractCore
import Foundation
import Testing

/// Real speech, no microphone (ABS-203): `say` makes the audio, Apple's
/// on-device recognizer hears it, and the wake rule decides. Wake phrases
/// in English and Portuguese must wake ABEL; near misses ("a bell", "able
/// to") must not. Each language runs only where its recognizer model and
/// a voice for it are installed; a Mac without them says so and skips.
@Suite(.serialized) struct RealSpeechTests {
    static let directory: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("abel-speech-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// `say` into an audio file; nil when the voice isn't installed.
    static func say(_ text: String, voice: String?, name: String) -> URL? {
        let url = directory.appendingPathComponent("\(name).aiff")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = (voice.map { ["-v", $0] } ?? []) + ["-o", url.path, text]
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        return process.terminationStatus == 0 && FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func voiceInstalled(_ name: String) -> Bool {
        AVSpeechSynthesisVoice.speechVoices().contains { $0.name == name }
    }

    /// Whether this Mac can run `locale`'s part: recognizer model and voice.
    static func ready(_ locale: String, voice: String) async -> Bool {
        guard #available(macOS 26, *) else { return false }
        let ok = await TranscriptionSession.isInstalled(locale) && voiceInstalled(voice)
        if !ok { print("ABEL real-speech tests for \(locale) skipped: its recognizer model or the \(voice) voice isn't on this Mac.") }
        return ok
    }

    struct Line: Sendable, CustomTestStringConvertible {
        var text: String
        var locale: String
        var voice: String
        var wakes: Bool
        var command: String?
        var testDescription: String { "\(wakes ? "wakes" : "doesn't wake"): \(text)" }
    }

    static let english: [Line] = [
        Line(text: "Hey Abel, what needs me?", locale: "en-US", voice: "Samantha", wakes: true, command: "what needs me"),
        Line(text: "Hey Abel, read the last reply", locale: "en-US", voice: "Samantha", wakes: true, command: "read the last reply"),
        Line(text: "Hey Abel, next one", locale: "en-US", voice: "Samantha", wakes: true, command: "next one"),
        Line(text: "Hey Abel", locale: "en-US", voice: "Samantha", wakes: true, command: nil),
        Line(text: "I heard a bell ring in the hallway", locale: "en-US", voice: "Samantha", wakes: false),
        Line(text: "We should be able to ship it today", locale: "en-US", voice: "Samantha", wakes: false),
        Line(text: "Hey, a bell just rang", locale: "en-US", voice: "Samantha", wakes: false),
        Line(text: "Put a label on the table", locale: "en-US", voice: "Samantha", wakes: false),
        Line(text: "Hey Abby, are you coming?", locale: "en-US", voice: "Samantha", wakes: false),
    ]

    static let portuguese: [Line] = [
        Line(text: "Ei Abel, o que precisa de mim?", locale: "pt-BR", voice: "Luciana", wakes: true, command: "o que precisa de mim"),
        Line(text: "Ei Abel", locale: "pt-BR", voice: "Luciana", wakes: true, command: nil),
        Line(text: "Ele é muito hábil com isso", locale: "pt-BR", voice: "Luciana", wakes: false),
        Line(text: "O Abel ligou ontem à noite", locale: "pt-BR", voice: "Luciana", wakes: false),
    ]

    @Test(arguments: english + portuguese)
    func theRecognizerAndWakeRuleAgree(_ line: Line) async throws {
        guard #available(macOS 26, *), await Self.ready(line.locale, voice: line.voice) else { return }
        let name = AbelText.normalized(line.text).replacingOccurrences(of: " ", with: "-") + "-" + line.locale
        let audio = try #require(Self.say(line.text, voice: line.voice, name: name))
        let started = Date()
        let heard = try await TranscriptionSession.transcribe(file: audio, locales: [line.locale])
        let seconds = Date().timeIntervalSince(started)
        let match = WakePhrase.match(heard.text, locale: line.locale)
        print(String(format: "ABEL heard %@ “%@” as “%@” in %.2f s: %@", line.locale, line.text, heard.text, seconds,
                     match == nil ? "no wake" : "wake"))
        #expect((match != nil) == line.wakes, "heard “\(heard.text)”")
        if let command = line.command {
            #expect(AbelText.normalized(match?.command ?? "") == AbelText.normalized(command), "heard “\(heard.text)”")
        }
    }

    @Test func picksPortugueseWhenBothLanguagesListen() async throws {
        guard #available(macOS 26, *), await Self.ready("pt-BR", voice: "Luciana"), await Self.ready("en-US", voice: "Samantha")
        else { return }
        let audio = try #require(Self.say("Ler a última resposta", voice: "Luciana", name: "ler-a-ultima-resposta"))
        let heard = try await TranscriptionSession.transcribe(file: audio, locales: ["en-US", "pt-BR"])
        #expect(heard.locale == "pt-BR", "heard \(heard.all)")
        #expect(AbelText.normalized(heard.text) == "ler a ultima resposta")
        let english = try #require(Self.say("Read the last reply", voice: "Samantha", name: "read-the-last-reply"))
        #expect(try await TranscriptionSession.transcribe(file: english, locales: ["en-US", "pt-BR"]).locale == "en-US")
    }

    /// The whole path the microphone takes: audio in real-time-sized
    /// chunks into the ears' wake listener, which wakes ABEL and hands over
    /// the command; a near miss in between wakes nothing.
    @MainActor
    @Test func theWakeListenerWakesOnlyForTheWakePhrase() async throws {
        guard #available(macOS 26, *), await Self.ready("en-US", voice: "Samantha") else { return }
        let nearMiss = try #require(Self.say("We should be able to ship it today", voice: "Samantha", name: "near-miss-stream"))
        let wake = try #require(Self.say("Hey Abel, what needs me?", voice: "Samantha", name: "wake-stream"))
        let source = FileAudioSource(urls: [nearMiss, wake], realTime: false, gap: 2)
        let ears = DeviceEars(source: source, silenceAfterWake: .seconds(5))
        var wakes = 0
        var finals: [String] = []
        ears.onWake = {
            wakes += 1
            ears.startCapture(.wakePhrase, languages: ["en-US"], vocabulary: [])
        }
        ears.onFinal = { text, _ in finals.append(text) }
        ears.setWakeListening(true, languages: ["en-US"], vocabulary: [])
        await eventually(seconds: 30) { !finals.isEmpty }
        ears.setWakeListening(false, languages: ["en-US"], vocabulary: [])
        #expect(wakes == 1)
        #expect(finals.map(AbelText.normalized) == ["what needs me"])
    }

    @MainActor
    @Test func theWakeListenerWakesInPortuguese() async throws {
        guard #available(macOS 26, *), await Self.ready("pt-BR", voice: "Luciana") else { return }
        let wake = try #require(Self.say("Ei Abel, o que precisa de mim?", voice: "Luciana", name: "ei-abel-stream"))
        // The silence after it, as a microphone would hear, ends the sentence.
        let source = FileAudioSource(urls: [wake], realTime: false, gap: 6)
        let ears = DeviceEars(source: source, silenceAfterWake: .seconds(20))
        var wakes = 0
        var finals: [String] = []
        var heard: [String] = []
        ears.onWake = {
            wakes += 1
            ears.startCapture(.wakePhrase, languages: ["pt-BR"], vocabulary: [])
        }
        ears.onWords = { heard.append($0) }
        ears.onFinal = { text, _ in finals.append(text) }
        ears.setWakeListening(true, languages: ["pt-BR"], vocabulary: [])
        await eventually(seconds: 30) { !finals.isEmpty }
        ears.setWakeListening(false, languages: ["pt-BR"], vocabulary: [])
        #expect(wakes == 1, "heard \(heard)")
        #expect(finals.map(AbelText.normalized) == ["o que precisa de mim"])
    }

    /// ABEL's voice, written into a buffer, and heard back by the recognizer.
    @Test func whatABELSaysCanBeHeardBack() async throws {
        guard #available(macOS 26, *), await Self.ready("en-US", voice: "Samantha") else { return }
        let sentence = "Sidebar fix says: I added a test for the grouping."
        let buffer = try #require(await SystemVoice.render(sentence, language: "en-US"))
        #expect(buffer.frameLength > 0)
        let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
        #expect(seconds > 1 && seconds < 10)
        let url = Self.directory.appendingPathComponent("abel-said.caf")
        let file = try AVAudioFile(forWriting: url, settings: buffer.format.settings)
        try file.write(from: buffer)
        let heard = try await TranscriptionSession.transcribe(file: url, locales: ["en-US"])
        #expect(AbelText.normalized(heard.text).contains("added a test for the grouping"), "heard “\(heard.text)”")
    }
}

@MainActor
func eventually(seconds: Double, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
}
