import Foundation

/// What ABEL understands at once, without asking an agent (ABS-204): a
/// fixed grammar in English and Portuguese, with command words matched
/// fuzzily ("cause everything" is still pause everything) and names left
/// as heard, for `AbelNames` to match against this Mac's chats and projects.
public enum AbelCommand: Sendable, Equatable {
    case whatNeedsMe
    case next
    case open(chat: String)
    /// The last reply of `chat`, or of the chat on screen.
    case readLast(chat: String?)
    case continueReading
    case approve(chat: String?)
    case deny(chat: String?)
    case stop(chat: String?)
    case pauseEverything
    case status(chat: String)
    /// A new chat in `project` (nil: a chat of its own), with `prompt`.
    case startChat(project: String?, prompt: String)
    case tell(chat: String, text: String)
    case sendIt
    case yes, no
    /// Never done by voice: ABEL opens the right screen instead.
    case forbidden(AbelForbidden, chat: String?)
    /// A chat's pull request, in the browser (ABS-205).
    case openPullRequest(chat: String)
    /// One of your shortcuts, by name (ABS-205).
    case runShortcut(name: String)
}

/// What ABEL never does by voice (ABS-202 §5).
public enum AbelForbidden: String, Sendable, Equatable, CaseIterable {
    case merge, push, fullAutonomy, delete
}

public enum AbelGrammar {
    /// How alike a heard command word must be to the real one.
    static let commandSimilarity = 0.8

    struct Pattern: Sendable {
        let words: [String]
        let build: @Sendable ([String]) -> AbelCommand?
        /// Only the words themselves, not ones like them.
        let exact: Bool
        init(_ phrase: String, exact: Bool = false, _ build: @escaping @Sendable ([String]) -> AbelCommand?) {
            words = phrase.split(separator: " ").map(String.init)
            self.exact = exact
            self.build = build
        }
    }

    /// Words said around a request that change nothing.
    static let leadingFillers: [[String]] = [
        ["abel"], ["please"], ["can", "you"], ["could", "you"], ["would", "you"], ["ok"], ["okay"], ["so"], ["now"],
        ["hey"], ["por", "favor"], ["pode"], ["voce", "pode"], ["agora"], ["entao"], ["ei"],
    ]
    static let trailingFillers: [[String]] = [
        ["please"], ["now"], ["for", "me"], ["por", "favor"], ["agora"], ["pra", "mim"], ["para", "mim"],
    ]
    /// What may follow an argument-less command and still be that command.
    static let harmlessTails: Set<String> = ["it", "that", "this", "isso", "isto", "ai", "please", "now", "agora"]

    static func none(_ command: AbelCommand) -> @Sendable ([String]) -> AbelCommand? {
        { rest in rest.allSatisfy { harmlessTails.contains($0) } ? command : nil }
    }

    static func chatArgument(_ make: @escaping @Sendable (String?) -> AbelCommand) -> @Sendable ([String]) -> AbelCommand? {
        { rest in
            let name = AbelNames.strippedFillers(rest)
            let named = name.allSatisfy { harmlessTails.contains($0) } ? [] : name
            return make(named.isEmpty ? nil : named.joined(separator: " "))
        }
    }

    static func requiredChat(_ make: @escaping @Sendable (String) -> AbelCommand) -> @Sendable ([String]) -> AbelCommand? {
        { rest in
            let name = AbelNames.strippedFillers(rest)
            return name.isEmpty ? nil : make(name.joined(separator: " "))
        }
    }

    /// Longest patterns first, so "stop the agent in" wins over "stop".
    static let patterns: [Pattern] = {
        var list: [Pattern] = []
        func add(_ phrases: [String], _ build: @escaping @Sendable ([String]) -> AbelCommand?, exact: Bool = false) {
            list += phrases.map { Pattern($0, exact: exact, build) }
        }
        add(["what needs me", "what needs my attention", "what needs attention", "whats waiting", "what is waiting",
             "whats waiting for me", "what is waiting for me", "who needs me", "anything need me",
             "o que precisa de mim", "o que esta esperando", "o que esta me esperando", "quem precisa de mim"],
            none(.whatNeedsMe))
        add(["next one", "next", "next chat", "the next one", "proximo", "proxima", "o proximo", "a proxima"], none(.next))
        add(["open", "open the chat", "go to", "show me", "switch to", "abrir", "abre", "abra", "ir para", "vai para", "mostra"],
            requiredChat { .open(chat: $0) })
        add(["read the last reply", "read the reply", "read the last message", "read the last answer", "read it",
             "what did it say", "ler a ultima resposta", "le a ultima resposta", "leia a ultima resposta", "ler a resposta",
             "leia a resposta"],
            chatArgument { .readLast(chat: $0) })
        add(["continue", "keep reading", "keep going", "go on", "read more", "continuar", "continua", "continue lendo", "mais"],
            none(.continueReading))
        // Answers to an agent's request: said exactly, never guessed at.
        add(["approve", "approved", "approve it", "approve that", "allow", "allow it", "allow that", "aprovar", "aprova",
             "aprove", "aprovado", "permitir", "permite"],
            chatArgument { .approve(chat: $0) }, exact: true)
        add(["deny", "denied", "deny it", "deny that", "decline", "decline it", "decline that", "reject", "reject it",
             "negar", "nega", "negue", "recusar", "recusa"],
            chatArgument { .deny(chat: $0) }, exact: true)
        add(["stop", "stop the agent", "stop the agent in", "stop agent", "parar", "para", "pare", "parar o agente",
             "parar o agente no", "para o agente"],
            chatArgument { .stop(chat: $0) })
        add(["pause everything", "pause all", "pause all agents", "pause all the agents", "pause every agent",
             "pausar tudo", "pausa tudo", "pause tudo", "pausar todos"],
            none(.pauseEverything))
        add(["status of", "status for", "whats the status of", "what is the status of", "how is", "how was", "hows",
             "how is it going with", "status do", "status da", "status de", "como esta", "como vai"],
            requiredChat { .status(chat: $0) })
        add(["start a chat in", "start a new chat in", "start chat in", "new chat in", "start a chat on",
             "iniciar um chat no", "iniciar um chat em", "iniciar um chat na", "inicia um chat no", "novo chat no",
             "comecar um chat no", "iniciar uma conversa no"],
            { rest in startChat(rest, inProject: true) })
        add(["start a chat to", "start a new chat to", "start a chat for", "iniciar um chat para", "novo chat para"],
            { rest in startChat(rest, inProject: false) })
        add(["tell", "say to", "send to", "ask", "diga ao", "diga a", "diga para", "fala pro", "fala para", "manda pro",
             "manda para", "pede ao", "pede para"],
            { rest in AbelNames.splitNameAndText(rest).map { .tell(chat: $0.name, text: $0.text) } })
        add(["open the pr for", "open the pull request for", "open pr for", "show the pr for", "open the pr of",
             "abrir o pr do", "abrir o pr da", "abre o pr do", "abrir o pull request do"],
            requiredChat { .openPullRequest(chat: $0) })
        add(["run shortcut", "run the shortcut", "run my shortcut", "run my", "start shortcut", "rodar atalho",
             "rodar o atalho", "roda o atalho", "executar atalho", "executar o atalho", "executa o atalho"],
            { rest in
                var words = rest
                if words.last == "shortcut" || words.last == "atalho" { words.removeLast() }
                return words.isEmpty ? nil : .runShortcut(name: words.joined(separator: " "))
            })
        add(["merge", "merge it", "merge the pr", "merge the pull request", "merge this", "merge that", "faz o merge",
             "fazer o merge", "fazer merge", "mesclar", "mescla"],
            chatArgument { .forbidden(.merge, chat: $0) })
        add(["push", "push it", "push the branch", "push the changes", "faz o push", "fazer push", "dar push", "da push"],
            chatArgument { .forbidden(.push, chat: $0) })
        add(["turn on full autonomy", "full autonomy", "enable full autonomy", "switch to full autonomy",
             "autonomia total", "ativar autonomia total", "liga autonomia total"],
            chatArgument { .forbidden(.fullAutonomy, chat: $0) })
        add(["delete", "delete the chat", "delete it", "delete this chat", "remove the chat", "apagar", "apaga",
             "deletar", "excluir", "exclui", "apagar o chat"],
            chatArgument { .forbidden(.delete, chat: $0) })
        return list.sorted { $0.words.count > $1.words.count }
    }()

    /// The command `text` asks for; nil when it's none of them, and goes
    /// to ABEL's chat instead.
    public static func parse(_ text: String) -> AbelCommand? {
        if AbelRouter.isSendIt(text) { return .sendIt }
        if AbelConfirmation.isYes(text) { return .yes }
        if AbelConfirmation.isNo(text) { return .no }
        let words = trimmed(AbelText.words(text))
        guard !words.isEmpty else { return nil }
        var best: (command: AbelCommand, length: Int, score: Double)?
        for pattern in patterns where pattern.words.count <= words.count {
            let head = Array(words.prefix(pattern.words.count))
            let score = AbelText.similarity(head.joined(separator: " "), pattern.words.joined(separator: " "))
            guard score >= (pattern.exact ? 1 : commandSimilarity), let command = pattern.build(Array(words.dropFirst(pattern.words.count))) else { continue }
            if best == nil || pattern.words.count > best!.length || (pattern.words.count == best!.length && score > best!.score) {
                best = (command, pattern.words.count, score)
            }
        }
        return best?.command
    }

    /// Whether `text` is a whole command that needs no name: what can be
    /// said while dictating and still be a command ("send it", "approve").
    public static func isBareCommand(_ text: String) -> Bool {
        switch parse(text) {
        case .sendIt, .whatNeedsMe, .next, .continueReading, .pauseEverything, .yes, .no: true
        case .readLast(nil), .approve(nil), .deny(nil), .stop(nil): true
        default: false
        }
    }

    static func trimmed(_ words: [String]) -> [String] {
        var words = words
        var changed = true
        while changed {
            changed = false
            for filler in leadingFillers where words.count > filler.count && Array(words.prefix(filler.count)) == filler {
                words.removeFirst(filler.count)
                changed = true
            }
            for filler in trailingFillers where words.count > filler.count && Array(words.suffix(filler.count)) == filler {
                words.removeLast(filler.count)
                changed = true
            }
        }
        return words
    }

    static let promptConnectors: Set<String> = ["to", "for", "that", "and", "para", "pra", "que"]

    /// "abstract to fix the palette overlay" → project "abstract", prompt "fix the palette overlay".
    static func startChat(_ rest: [String], inProject: Bool) -> AbelCommand? {
        guard inProject else {
            let prompt = rest.joined(separator: " ")
            return prompt.isEmpty ? nil : .startChat(project: nil, prompt: prompt)
        }
        guard let cut = rest.firstIndex(where: { promptConnectors.contains($0) }), cut > 0, cut + 1 < rest.count else { return nil }
        let project = AbelNames.strippedFillers(Array(rest[..<cut])).joined(separator: " ")
        let prompt = rest[(cut + 1)...].joined(separator: " ")
        return project.isEmpty ? nil : .startChat(project: project, prompt: prompt)
    }
}

extension AbelConfirmation {
    static let no: Set<String> = ["no", "nope", "no thanks", "cancel", "dont", "nao", "cancela", "cancelar", "nao obrigado"]

    public static func isNo(_ text: String) -> Bool { no.contains(AbelText.normalized(text)) }
}

/// Names as heard, matched against this Mac's chats and projects: "palid
/// overlay" is "Palette overlay", "the sidebar fixed chat" is "Sidebar fix".
public enum AbelNames {
    public enum Match<ID: Hashable & Sendable>: Sendable, Equatable {
        case one(ID, score: Double)
        /// Two or more fit about as well; ABEL asks which.
        case ambiguous([ID])
        case none
    }

    /// How alike a heard name must be to a real one.
    public static let threshold = 0.7

    static let fillers: [[String]] = [
        ["the", "chat", "about", "the"], ["the", "chat", "about"], ["the", "chat", "called"], ["the", "chat", "named"],
        ["the", "agent", "in"], ["agent", "in"], ["the", "chat", "for"], ["chat", "about"], ["the", "chat"], ["about", "the"],
        ["about"], ["called"], ["named"], ["the"], ["chat"], ["in"], ["on"], ["of"], ["from"], ["for"],
        ["o", "chat", "do"], ["o", "chat", "da"], ["o", "chat"], ["a", "conversa"], ["o"], ["a"], ["do"], ["da"], ["de"],
        ["no"], ["na"], ["sobre"], ["ao"], ["pro"], ["pra"],
    ]
    static let trailing: [[String]] = [["chat"], ["doing"], ["going"], ["now"], ["please"], ["indo"], ["agora"]]

    /// The words of a heard name without "the chat about…" around it.
    public static func strippedFillers(_ words: [String]) -> [String] {
        var words = words
        var changed = true
        while changed {
            changed = false
            for filler in fillers where words.count > filler.count && Array(words.prefix(filler.count)) == filler {
                words.removeFirst(filler.count)
                changed = true
            }
            for filler in trailing where words.count > filler.count && Array(words.suffix(filler.count)) == filler {
                words.removeLast(filler.count)
                changed = true
            }
        }
        return words
    }

    /// How alike a heard name is to a real one, 0 to 1.
    public static func score(_ heard: String, _ name: String) -> Double {
        let h = strippedFillers(AbelText.words(heard)), n = AbelText.words(name)
        guard !h.isEmpty, !n.isEmpty else { return 0 }
        if h == n { return 1 }
        let chars = AbelText.similarity(h.joined(), n.joined())
        func best(_ word: String, in words: [String]) -> Double { words.map { AbelText.similarity(word, $0) }.max() ?? 0 }
        let heardCovered = h.map { best($0, in: n) }.reduce(0, +) / Double(h.count)
        let nameCovered = n.map { best($0, in: h) }.reduce(0, +) / Double(n.count)
        let tokens = (heardCovered + nameCovered) / 2
        // Every word of the name said, plus a little more ("sidebar fix chat").
        let contained = n.allSatisfy { best($0, in: h) >= 0.85 } && h.count <= n.count + 2 ? 0.92 : 0
        return max(chars, tokens, contained)
    }

    /// The thing `heard` names among `candidates`.
    public static func match<ID: Hashable & Sendable>(_ heard: String, among candidates: [(id: ID, name: String)]) -> Match<ID> {
        let scored = candidates.map { (id: $0.id, score: score(heard, $0.name)) }
            .filter { $0.score >= threshold }
            .sorted { $0.score > $1.score }
        guard let top = scored.first else { return .none }
        let close = scored.filter { top.score - $0.score < 0.04 }
        if close.count > 1, top.score < 1 { return .ambiguous(close.map(\.id)) }
        return .one(top.id, score: top.score)
    }

    /// "sidebar fix to add a test" → ("sidebar fix", "add a test"): the
    /// name runs to the connecting word; without one, the first words.
    static func splitNameAndText(_ rest: [String]) -> (name: String, text: String)? {
        guard rest.count >= 2 else { return nil }
        let connectors: Set<String> = ["to", "that", "que", "para", "pra"]
        if let cut = rest.firstIndex(where: { connectors.contains($0) }), cut > 0, cut + 1 < rest.count {
            let name = strippedFillers(Array(rest[..<cut]))
            guard !name.isEmpty else { return nil }
            return (name.joined(separator: " "), rest[(cut + 1)...].joined(separator: " "))
        }
        // No connector: the first two words name the chat.
        let name = strippedFillers(Array(rest.prefix(2)))
        guard !name.isEmpty, rest.count > 2 else { return nil }
        return (name.joined(separator: " "), rest.dropFirst(2).joined(separator: " "))
    }
}

extension AbelText {
    /// 1 minus the edit distance over the longer length: 1 is the same.
    public static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        let x = Array(a), y = Array(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return 1 - Double(previous[y.count]) / Double(max(x.count, y.count))
    }
}

/// One chat as ABEL knows it: enough to say what needs you, give a
/// status, and match its name.
public struct AbelChatInfo: Codable, Sendable, Equatable, Identifiable {
    public enum State: String, Codable, Sendable {
        case needsYou, working, readyToReview, done
    }

    public var id: String
    public var title: String
    public var project: String?
    public var agent: String
    public var state: State
    /// What it waits for, in words: "wants to run `swift test`", "has a question".
    public var waiting: String?
    public var activeAt: Date
    public var pullRequest: Int?
    /// The pull request's checks: "passing", "failing", "pending".
    public var checks: String?
    public var branch: String?
    /// Where its pull request is on the web (ABS-205).
    public var pullRequestURL: String?

    public init(id: String, title: String, project: String? = nil, agent: String = "Claude", state: State = .done,
                waiting: String? = nil, activeAt: Date = Date(), pullRequest: Int? = nil, checks: String? = nil,
                branch: String? = nil, pullRequestURL: String? = nil) {
        self.id = id; self.title = title; self.project = project; self.agent = agent; self.state = state
        self.waiting = waiting; self.activeAt = activeAt; self.pullRequest = pullRequest; self.checks = checks
        self.branch = branch; self.pullRequestURL = pullRequestURL
    }
}

public struct AbelProjectInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

/// A command with its names matched: what ABEL will do.
public enum AbelIntent: Sendable, Equatable {
    case whatNeedsMe, next, continueReading, pauseEverything, sendIt, yes, no
    case open(chatId: String)
    case readLast(chatId: String?)
    case approve(chatId: String?)
    case deny(chatId: String?)
    case stop(chatId: String?)
    case status(chatId: String)
    case startChat(projectId: String?, prompt: String)
    case tell(chatId: String, text: String)
    case forbidden(AbelForbidden, chatId: String?)
    /// A command whose name matched nothing here.
    case notFound(command: String, heard: String)
    /// A name that fits more than one chat.
    case ambiguous(command: String, chatIds: [String])
    /// Not a command: ABEL's chat answers it.
    case askABEL(String)
    /// Other apps (ABS-205).
    case openApp(AbelAppInfo)
    case openFile(String)
    case openURL(String, chatId: String)
    case runShortcut(String)
}

public enum AbelResolver {
    public static func resolve(_ text: String, chats: [AbelChatInfo], projects: [AbelProjectInfo],
                               apps: [AbelAppInfo] = [], shortcuts: [String] = [],
                               home: String = NSHomeDirectory()) -> AbelIntent {
        guard let command = AbelGrammar.parse(text) else { return .askABEL(text) }
        let named = chats.map { (id: $0.id, name: $0.title) }
        func chat(_ heard: String?, _ kind: String, _ make: (String?) -> AbelIntent) -> AbelIntent {
            guard let heard else { return make(nil) }
            switch AbelNames.match(heard, among: named) {
            case let .one(id, _): return make(id)
            case let .ambiguous(ids): return .ambiguous(command: kind, chatIds: ids)
            case .none: return .notFound(command: kind, heard: heard)
            }
        }
        switch command {
        case .whatNeedsMe: return .whatNeedsMe
        case .next: return .next
        case .continueReading: return .continueReading
        case .pauseEverything: return .pauseEverything
        case .sendIt: return .sendIt
        case .yes: return .yes
        case .no: return .no
        case let .open(heard):
            // A chat first; else one of your folders, else an app.
            switch AbelNames.match(heard, among: named) {
            case let .one(id, _): return .open(chatId: id)
            case let .ambiguous(ids): return .ambiguous(command: "open", chatIds: ids)
            case .none: break
            }
            if let folder = AbelFolders.path(heard, home: home) { return .openFile(folder) }
            if case let .one(index, _) = AbelNames.match(heard, among: apps.enumerated().map { (id: $0.offset, name: $0.element.name) }) {
                return .openApp(apps[index])
            }
            return .notFound(command: "open", heard: heard)
        case let .openPullRequest(heard):
            return chat(heard, "openPullRequest") { id in
                guard let id, let url = chats.first(where: { $0.id == id })?.pullRequestURL else {
                    return .notFound(command: "pullRequest", heard: heard)
                }
                return .openURL(url, chatId: id)
            }
        case let .runShortcut(heard):
            guard case let .one(index, _) = AbelNames.match(heard, among: shortcuts.enumerated().map { (id: $0.offset, name: $0.element) })
            else { return .notFound(command: "shortcut", heard: heard) }
            return .runShortcut(shortcuts[index])
        case let .readLast(heard): return chat(heard, "readLast") { .readLast(chatId: $0) }
        case let .approve(heard): return chat(heard, "approve") { .approve(chatId: $0) }
        case let .deny(heard): return chat(heard, "deny") { .deny(chatId: $0) }
        case let .stop(heard): return chat(heard, "stop") { .stop(chatId: $0) }
        case let .status(heard): return chat(heard, "status") { .status(chatId: $0!) }
        case let .tell(heard, text): return chat(heard, "tell") { .tell(chatId: $0!, text: text) }
        case let .forbidden(action, heard):
            return chat(heard, action.rawValue) { .forbidden(action, chatId: $0) }
        case let .startChat(project, prompt):
            guard let project else { return .startChat(projectId: nil, prompt: prompt) }
            switch AbelNames.match(project, among: projects.map { (id: $0.id, name: $0.name) }) {
            case let .one(id, _): return .startChat(projectId: id, prompt: prompt)
            case .ambiguous, .none: return .notFound(command: "start", heard: project)
            }
        }
    }
}

/// The folders you'd name out loud: "open downloads", "open tilde slash
/// Downloads" (heard as "film slash download", even).
public enum AbelFolders {
    static let known: [(words: [String], folder: String)] = [
        (["downloads", "download", "transferencias"], "Downloads"),
        (["desktop", "mesa"], "Desktop"),
        (["documents", "documentos"], "Documents"),
        (["home", "inicio"], ""),
    ]

    public static func path(_ heard: String, home: String) -> String? {
        let words = AbelText.words(heard)
        guard words.count <= 6 else { return nil }
        for entry in known where words.contains(where: { entry.words.contains($0) }) {
            // "open the downloads folder", "tilde slash downloads": a folder; "download the logs": not.
            guard words.last.map({ entry.words.contains($0) || ["folder", "pasta", "directory"].contains($0) }) == true else { continue }
            return entry.folder.isEmpty ? home : (home as NSString).appendingPathComponent(entry.folder)
        }
        return nil
    }
}
