import Foundation

/// Where something you said to ABEL goes (ABS-203): into the reply box of
/// the chat on screen, or "send it" sends that box. ABS-204 adds commands
/// and ABEL's own chat in front of this.
public enum AbelRoute: Sendable, Equatable {
    case dictate(chatId: String, text: String)
    case sendDraft(chatId: String)
    /// Nothing to do; ABEL says why.
    case say(String)
}

public enum AbelRouter {
    /// "Send it", in English or Portuguese.
    static let sendPhrases: Set<String> = [
        "send it", "send", "send this", "send that", "send the message", "send message", "ok send it", "okay send it",
        "envia", "enviar", "envie", "manda", "mande", "pode enviar", "pode mandar", "envia isso", "manda isso",
    ]

    public static func isSendIt(_ text: String) -> Bool {
        sendPhrases.contains(AbelText.normalized(text))
    }

    /// Dictation and "send it", for the chat on screen. `context` is nil
    /// when Abstract isn't open.
    public static func route(_ text: String, context: AbelLink.Context?, language: String = "en-US") -> AbelRoute {
        let say = AbelPhrases(language: language)
        guard let context else { return .say(say.abstractClosed) }
        guard let chatId = context.shownChatId else { return .say(say.openAChat) }
        if isSendIt(text) { return .sendDraft(chatId: chatId) }
        return .dictate(chatId: chatId, text: text)
    }
}

/// What ABEL says, in English or Portuguese: the language you spoke in.
public struct AbelPhrases: Sendable {
    public let portuguese: Bool

    public init(language: String) { portuguese = language.lowercased().hasPrefix("pt") }

    public var abstractClosed: String {
        portuguese ? "O Abstract não está aberto. Abra-o pelo menu do ABEL." : "Abstract isn't open. You can open it from ABEL's menu."
    }
    public var openAChat: String {
        portuguese ? "Abra um chat no Abstract e eu escrevo o que você disser na caixa de resposta."
            : "Open a chat in Abstract, and I'll put what you say in its reply box."
    }
    public func dictated(_ chat: String) -> String { portuguese ? "Escrito em \(chat)." : "Added to \(chat)." }
    public func sent(_ chat: String) -> String { portuguese ? "Enviado para \(chat)." : "Sent to \(chat)." }
    public func replied(_ chat: String) -> String { portuguese ? "\(chat) respondeu:" : "\(chat) says:" }
    public var listening: String { portuguese ? "Ouvindo…" : "Listening…" }
    public var notHeard: String { portuguese ? "Não ouvi nada." : "I didn't catch that." }
}

/// Dictated words added to a reply box.
public enum AbelDictation {
    /// `words` after what's already typed, with one space between, so
    /// several takes read as one message.
    public static func appending(_ words: String, to draft: String) -> String {
        let words = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return draft }
        guard let last = draft.last else { return words }
        return last.isWhitespace ? draft + words : draft + " " + words
    }
}
