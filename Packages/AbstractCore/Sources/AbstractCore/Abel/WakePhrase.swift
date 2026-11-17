import Foundation

/// "Hey Abel" and "Ei Abel", found in what the on-device recognizer heard
/// (ABS-202 §1). A sentence wakes ABEL when it starts with up to three
/// greetings and then "Abel". After a greeting, a word that sounds like it
/// ("able", "gable") counts too, but only when nothing or a command follows it ("Okay, able." yes; "Okay,
/// able, that's enough" no). In Portuguese a bare "Abel" opening a
/// sentence counts as well, since the recognizer often drops "Ei".
public enum WakePhrase {
    /// A wake found in a transcript, and what was said after it: the
    /// command, when it came in the same breath.
    public struct Match: Sendable, Equatable {
        public var command: String
        public init(command: String) { self.command = command }
    }

    static let greetings: Set<String> = [
        "hey", "hi", "ok", "okay", "kay", "k", "ei", "ey", "hei", "oi", "e", "a", "ah", "oh", "eh", "hay",
    ]
    /// What the recognizer makes of "Abel" now and then. They count only
    /// after a greeting and before a command: "Hey, Gable, what needs me?"
    /// wakes; "Hey Mabel, can you pass the salt?" doesn't.
    static let soundsLike: Set<String> = ["able", "gable", "mabel", "abe", "abel's", "abels", "label"]
    /// Words a command can start with, which tell a wake from "able to".
    static let commandStarts: Set<String> = [
        "what", "whats", "open", "read", "approve", "deny", "stop", "pause", "status", "start", "tell", "next",
        "continue", "run", "send", "yes", "no", "show", "hide", "dictate",
        "o", "abrir", "abre", "ler", "le", "aprovar", "aprova", "negar", "nega", "parar", "para", "pausar", "pausa",
        "iniciar", "inicia", "proximo", "continuar", "continua", "rodar", "roda", "enviar", "envia", "sim", "nao",
    ]

    /// The first wake in `transcript`, heard in `locale` (a BCP 47 code
    /// like "en-US" or "pt-BR"); nil when none.
    public static func match(_ transcript: String, locale: String) -> Match? {
        let portuguese = locale.lowercased().hasPrefix("pt")
        for sentence in sentences(transcript) {
            let words = AbelText.words(sentence)
            var index = 0
            while index < words.count, index < 3, greetings.contains(words[index]) { index += 1 }
            guard index < words.count else { continue }
            let word = words[index]
            let next = index + 1 < words.count ? words[index + 1] : nil
            let woke: Bool
            if word == "abel" {
                woke = index > 0 || portuguese
            } else if soundsLike.contains(word) {
                woke = index > 0 && (next == nil || commandStarts.contains(next!))
            } else {
                woke = false
            }
            if woke { return Match(command: remainder(of: transcript, after: sentence, skipping: index + 1)) }
        }
        return nil
    }

    /// What was said once ABEL is already awake, without the wake words
    /// it opened with: "Hey, Gable, add a test" → "add a test". Looser than
    /// `match`, since ABEL already knows it was called.
    public static func strippingWake(_ transcript: String) -> String {
        let words = AbelText.words(transcript)
        var index = 0
        while index < words.count, index < 3, greetings.contains(words[index]) { index += 1 }
        guard index < words.count, words[index] == "abel" || soundsLike.contains(words[index]) else { return transcript }
        let sentence = transcript[...]
        return remainder(of: transcript, after: sentence, skipping: index + 1)
    }

    /// Whether `transcript` wakes ABEL in `locale`.
    public static func wakes(_ transcript: String, locale: String) -> Bool {
        match(transcript, locale: locale) != nil
    }

    static func sentences(_ text: String) -> [Substring] {
        text.split(whereSeparator: { ".?!;\n".contains($0) })
    }

    /// The transcript from the word after the wake on, as it was heard.
    static func remainder(of transcript: String, after sentence: Substring, skipping count: Int) -> String {
        var rest = transcript[sentence.startIndex...]
        var skipped = 0
        while skipped < count {
            // Past any separators, then past one word.
            rest = rest.drop { !$0.isLetter && !$0.isNumber }
            guard !rest.isEmpty else { break }
            rest = rest.drop { $0.isLetter || $0.isNumber || $0 == "'" }
            skipped += 1
        }
        return rest.drop { !$0.isLetter && !$0.isNumber }.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Text as ABEL compares it: lowercased, accents folded, split into words.
public enum AbelText {
    public static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }

    public static func words(_ text: Substring) -> [String] { words(String(text)) }

    public static func words(_ text: String) -> [String] {
        fold(text).replacingOccurrences(of: "'", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// The words joined by single spaces: "Open the PR-43!" → "open the pr 43".
    public static func normalized(_ text: String) -> String { words(text).joined(separator: " ") }
}
