import Foundation

/// What ABEL says about chats (ABS-204), in English or Portuguese: short
/// sentences, meant to be heard, never more than a few at once.
extension AbelPhrases {
    /// "Two chats need you. Sidebar fix wants to run `swift test`. Palette overlay has a question."
    public func needsYou(_ chats: [AbelChatInfo]) -> String {
        let waiting = chats.filter { $0.state == .needsYou }
        guard !waiting.isEmpty else { return portuguese ? "Nada precisa de você agora." : "Nothing needs you right now." }
        let count = waiting.count == 1 ? (portuguese ? "Um chat precisa de você." : "One chat needs you.")
            : (portuguese ? "\(number(waiting.count)) chats precisam de você." : "\(number(waiting.count).capitalized) chats need you.")
        let listed = waiting.prefix(3).map { chat in
            "\(chat.title) \(chat.waiting.map(Self.spoken) ?? (portuguese ? "está esperando" : "is waiting"))."
        }
        let more = waiting.count > 3 ? [portuguese ? "E mais \(waiting.count - 3)." : "And \(waiting.count - 3) more."] : []
        return ([count] + listed + more).joined(separator: " ")
    }

    /// One chat's state in a sentence or two.
    public func status(_ chat: AbelChatInfo, now: Date = Date()) -> String {
        var parts: [String] = []
        switch chat.state {
        case .needsYou:
            parts.append("\(chat.title) \(chat.waiting.map(Self.spoken) ?? (portuguese ? "está esperando por você" : "is waiting for you")).")
        case .working:
            parts.append(portuguese ? "\(chat.title) está trabalhando, há \(ago(chat.activeAt, now))."
                : "\(chat.title) is working, for \(ago(chat.activeAt, now)).")
        case .readyToReview:
            parts.append(portuguese ? "\(chat.title) terminou e tem mudanças para revisar." : "\(chat.title) is done and has changes to review.")
        case .done:
            parts.append(portuguese ? "\(chat.title) terminou há \(ago(chat.activeAt, now))." : "\(chat.title) finished \(ago(chat.activeAt, now)) ago.")
        }
        if let pr = chat.pullRequest {
            let checks = chat.checks.map { portuguese ? ", checks \(checkWord($0))" : ", checks \(checkWord($0))" } ?? ""
            parts.append(portuguese ? "Pull request \(pr)\(checks)." : "Pull request \(pr)\(checks).")
        }
        return parts.joined(separator: " ")
    }

    func checkWord(_ checks: String) -> String {
        switch checks.lowercased() {
        case "success", "passing", "passed": portuguese ? "passando" : "passing"
        case "failure", "failing", "failed": portuguese ? "falhando" : "failing"
        default: portuguese ? "rodando" : "running"
        }
    }

    func ago(_ date: Date, _ now: Date) -> String {
        let minutes = max(Int(now.timeIntervalSince(date) / 60), 0)
        if minutes < 1 { return portuguese ? "menos de um minuto" : "less than a minute" }
        if minutes < 60 { return minutes == 1 ? (portuguese ? "um minuto" : "a minute") : "\(minutes) \(portuguese ? "minutos" : "minutes")" }
        let hours = minutes / 60
        if hours < 24 { return hours == 1 ? (portuguese ? "uma hora" : "an hour") : "\(hours) \(portuguese ? "horas" : "hours")" }
        let days = hours / 24
        return days == 1 ? (portuguese ? "um dia" : "a day") : "\(days) \(portuguese ? "dias" : "days")"
    }

    func number(_ n: Int) -> String {
        let en = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
        let pt = ["zero", "um", "dois", "três", "quatro", "cinco", "seis", "sete", "oito", "nove", "dez"]
        guard n < 11 else { return String(n) }
        return portuguese ? pt[n].capitalized : en[n]
    }

    /// Backticks are for the screen; the words are what's read.
    public static func spoken(_ text: String) -> String { text.replacingOccurrences(of: "`", with: "") }

    public func opening(_ chat: String) -> String { portuguese ? "Abrindo \(chat)." : "Opening \(chat)." }
    public func notFound(_ heard: String) -> String {
        portuguese ? "Não encontrei um chat chamado \(heard)." : "I couldn't find a chat called \(heard)."
    }
    public func projectNotFound(_ heard: String) -> String {
        portuguese ? "Não encontrei um projeto chamado \(heard)." : "I couldn't find a project called \(heard)."
    }
    public func whichOne(_ titles: [String]) -> String {
        let list = titles.prefix(3).joined(separator: portuguese ? " ou " : " or ")
        return portuguese ? "Qual deles: \(list)?" : "Which one: \(list)?"
    }
    public var noNext: String { portuguese ? "Nenhum outro chat precisa de você." : "No other chat needs you." }
    public var noReply: String { portuguese ? "Esse chat ainda não respondeu." : "That chat hasn't replied yet." }
    public var endOfReply: String { portuguese ? "Essa é a resposta toda." : "That's the whole reply." }
    public var nothingToContinue: String { portuguese ? "Não estou lendo nada agora." : "I'm not reading anything right now." }
    public var nothingWaiting: String { portuguese ? "Nada está esperando uma resposta." : "Nothing is waiting for an answer." }
    public var nothingToConfirm: String { portuguese ? "Não há nada esperando um sim." : "There's nothing waiting for a yes." }
    public func allow(_ summary: String, in chat: String) -> String {
        portuguese ? "Deixar \(chat) \(Self.spoken(summary))? Diga sim para permitir."
            : "Let \(chat) \(Self.spoken(summary))? Say yes to allow."
    }
    public func decline(_ summary: String, in chat: String) -> String {
        portuguese ? "Recusar o pedido de \(chat) para \(Self.spoken(summary))? Diga sim para recusar."
            : "Turn down \(chat)'s request to \(Self.spoken(summary))? Say yes to turn it down."
    }
    public func questionInChat(_ chat: String) -> String {
        portuguese ? "\(chat) fez uma pergunta. Responda no chat; vou abri-lo."
            : "\(chat) asked a question. Answer it in the chat; I've opened it."
    }
    public func approveOnScreen(_ chat: String) -> String {
        portuguese ? "Não consigo ler esse pedido inteiro em voz alta. Aprove em \(chat); abri o chat."
            : "I can't read that request back whole. Approve it in \(chat); I've opened it."
    }
    public func allowed(_ chat: String) -> String { portuguese ? "Permitido em \(chat)." : "Allowed in \(chat)." }
    public func declined(_ chat: String) -> String { portuguese ? "Recusado em \(chat)." : "Declined in \(chat)." }
    public func stopped(_ chat: String) -> String { portuguese ? "Parei \(chat)." : "Stopped \(chat)." }
    public var pausedAll: String { portuguese ? "Pausei todos os agentes." : "Paused every agent." }
    public var noChatHere: String { portuguese ? "Diga qual chat." : "Say which chat." }
    public func startReadBack(_ prompt: String, in project: String?) -> String {
        let place = project.map { portuguese ? " no \($0)" : " in \($0)" } ?? ""
        return portuguese ? "Iniciar um chat\(place) para \(prompt)? Diga sim para iniciar."
            : "Start a chat\(place) to \(prompt)? Say yes to start."
    }
    public func started(_ chat: String) -> String { portuguese ? "Iniciei o chat \(chat)." : "Started the chat \(chat)." }
    public func tellReadBack(_ chat: String, _ text: String) -> String {
        portuguese ? "Dizer a \(chat): \(text)? Diga sim para enviar." : "Tell \(chat): \(text)? Say yes to send."
    }
    public func told(_ chat: String) -> String { portuguese ? "Enviado para \(chat)." : "Sent to \(chat)." }
    public var askingABEL: String { portuguese ? "Vou ver." : "Let me check." }

    /// What ABEL says instead of doing what's never done by voice.
    public func forbidden(_ action: AbelForbidden, chat: String?, opened: Bool) -> String {
        let place = chat.map { portuguese ? " de \($0)" : " for \($0)" } ?? ""
        switch action {
        case .merge:
            return portuguese
                ? "Eu não faço merge por voz." + (opened ? " Abri o pull request\(place) para você fazer lá." : "")
                : "I don't merge by voice." + (opened ? " I've opened the pull request\(place) so you can do it there." : "")
        case .push:
            return portuguese
                ? "Eu não faço push por voz." + (opened ? " Abri o pull request\(place) para você fazer lá." : "")
                : "I don't push by voice." + (opened ? " I've opened the pull request\(place) so you can do it there." : "")
        case .fullAutonomy:
            return portuguese ? "Autonomia total nunca é ligada por voz. Mude no campo de resposta do chat."
                : "Full autonomy is never turned on by voice. Change it under the chat's reply box."
        case .delete:
            return portuguese ? "Eu não apago nada por voz." + (opened ? " Abri o chat\(place)." : "")
                : "I don't delete anything by voice." + (opened ? " I've opened the chat\(place)." : "")
        }
    }
}
