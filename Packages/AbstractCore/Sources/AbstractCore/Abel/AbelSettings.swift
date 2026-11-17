import Foundation

/// What Settings › ABEL holds, kept in Abstract's store and handed to ABEL
/// with each `context`. ABEL keeps the last copy it got, so it still knows
/// them while Abstract is closed.
public struct AbelSettings: Codable, Sendable, Equatable {
    public static let storeKey = "abel.v1"

    /// The languages ABEL listens in, as BCP 47 codes: English, Portuguese
    /// (Brazil), or both.
    public static let supportedLanguages = ["en-US", "pt-BR"]

    /// Listen for "Hey Abel" ("Ei Abel") all the time. Off until you turn it on.
    public var wakePhrase: Bool
    /// Which of `supportedLanguages` ABEL listens in; never empty.
    public var languages: [String]
    /// The voice ABEL speaks with (an `AVSpeechSynthesisVoice` identifier);
    /// nil picks the system's voice for the language.
    public var voice: String?
    /// The chats whose finished replies ABEL reads aloud.
    public var speakReplies: [String]
    /// Show the orb. Off hides it; push-to-talk and the wake phrase still
    /// bring it up while ABEL listens or answers.
    public var showOrb: Bool
    /// The agent that runs ABEL's own chat (ABS-204), and the profile it
    /// starts from; any agent Abstract runs.
    public var agentId: String
    public var profileId: String?
    /// ABEL's own chat, once there is one.
    public var chatId: String?

    public init(wakePhrase: Bool = false, languages: [String] = ["en-US"], voice: String? = nil,
                speakReplies: [String] = [], showOrb: Bool = true, agentId: String = "claude",
                profileId: String? = nil, chatId: String? = nil) {
        self.wakePhrase = wakePhrase
        self.languages = Self.valid(languages)
        self.voice = voice
        self.speakReplies = speakReplies
        self.showOrb = showOrb
        self.agentId = agentId
        self.profileId = profileId
        self.chatId = chatId
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        wakePhrase = try c.decodeIfPresent(Bool.self, forKey: .wakePhrase) ?? false
        languages = Self.valid(try c.decodeIfPresent([String].self, forKey: .languages) ?? [])
        voice = try c.decodeIfPresent(String.self, forKey: .voice)
        speakReplies = try c.decodeIfPresent([String].self, forKey: .speakReplies) ?? []
        showOrb = try c.decodeIfPresent(Bool.self, forKey: .showOrb) ?? true
        agentId = try c.decodeIfPresent(String.self, forKey: .agentId) ?? "claude"
        profileId = try c.decodeIfPresent(String.self, forKey: .profileId)
        chatId = try c.decodeIfPresent(String.self, forKey: .chatId)
    }

    /// Whether ABEL reads `chatId`'s finished replies aloud: ABEL's own
    /// chat always.
    public func speaks(_ chatId: String) -> Bool { speakReplies.contains(chatId) || chatId == self.chatId }

    public mutating func setSpeaks(_ chatId: String, _ on: Bool) {
        speakReplies.removeAll { $0 == chatId }
        if on { speakReplies.append(chatId) }
    }

    /// Supported languages only, in order, at least English.
    static func valid(_ languages: [String]) -> [String] {
        let kept = supportedLanguages.filter(languages.contains)
        return kept.isEmpty ? ["en-US"] : kept
    }

    /// A language's name in Settings.
    public static func languageName(_ code: String) -> String {
        switch code {
        case "pt-BR": "Portuguese (Brazil)"
        default: "English"
        }
    }
}

/// The names ABEL listens for: this Mac's projects, chats and agents. They
/// bias the matcher toward what's here (ABS-202 §2: the recognizer itself
/// ignores contextual strings), and are still handed to it as such.
public struct AbelVocabulary: Codable, Sendable, Equatable {
    public var projects: [String]
    public var chats: [String]
    public var agents: [String]

    public init(projects: [String] = [], chats: [String] = [], agents: [String] = []) {
        self.projects = projects; self.chats = chats; self.agents = agents
    }

    /// The most a recognizer is given; the most recent chats come first.
    public static let limit = 100

    /// Built from what Abstract has: unarchived projects, the most recently
    /// active chats first, and every agent; duplicates and blanks dropped.
    public static func build(projects: [(name: String, archived: Bool)],
                             chats: [(title: String, archived: Bool, activeAt: Date)],
                             agents: [String]) -> AbelVocabulary {
        func cleaned(_ names: [String]) -> [String] {
            var seen = Set<String>()
            return names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert(AbelText.normalized($0)).inserted }
        }
        let projectNames = cleaned(projects.filter { !$0.archived }.map(\.name))
        let chatNames = cleaned(chats.filter { !$0.archived }.sorted { $0.activeAt > $1.activeAt }.map(\.title))
        let agentNames = cleaned(agents)
        let room = max(limit - projectNames.count - agentNames.count, 0)
        return AbelVocabulary(projects: projectNames, chats: Array(chatNames.prefix(room)), agents: agentNames)
    }

    /// What the recognizer is given: the wake phrases first, then every name.
    public var contextualStrings: [String] {
        ["Abel", "Hey Abel", "Ei Abel"] + projects + chats + agents
    }
}
