import AbstractCore
import Foundation

/// ABEL controlling Abstract (ABS-204): the instant commands, ABEL's own
/// chat for everything else, and the tools that chat's agent calls. Every
/// approval, and every action an agent asks for, is read back and waits
/// for "yes"; merge, push, full autonomy and delete are never done by voice.
extension AbelEngine {
    var chats: [AbelChatInfo] { context?.chats ?? [] }

    func chat(_ id: String?) -> AbelChatInfo? { id.flatMap { id in chats.first { $0.id == id } } }

    // MARK: Commands

    func command(_ text: String, language: String, trigger: AbelMachine.Trigger) async {
        let say = AbelPhrases(language: language)
        let intent = AbelResolver.resolve(text, chats: chats, projects: context?.projects ?? [])
        switch intent {
        case .whatNeedsMe:
            let waiting = chats.filter { $0.state == .needsYou }
            lastListed = waiting.map(\.id)
            self.say(say.needsYou(chats))
        case .next:
            guard let next = chats.first(where: { $0.state == .needsYou && $0.id != context?.shownChatId }) else {
                self.say(say.noNext)
                return
            }
            await open(next, language: language)
        case let .open(chatId):
            guard let chat = chat(chatId) else { return }
            await open(chat, language: language)
        case let .readLast(chatId):
            guard let target = chat(chatId ?? context?.shownChatId ?? lastListed.first) ?? chats.max(by: { $0.activeAt < $1.activeAt })
            else { self.say(say.noChatHere); return }
            await readLast(target, language: language)
        case .continueReading:
            guard let current = reading else { self.say(say.nothingToContinue); return }
            guard let next = current.text.paragraph(after: current.index) else {
                reading = nil
                self.say(say.endOfReply)
                return
            }
            reading = (current.text, current.index + 1, current.chat)
            self.say(next)
        case let .approve(chatId), let .deny(chatId):
            let allow = if case .approve = intent { true } else { false }
            await answer(chatId, allow: allow, language: language, askedBy: "you")
        case let .stop(chatId):
            guard let target = chat(chatId ?? context?.shownChatId) else { self.say(say.noChatHere); return }
            let reply = await abstract.ask(AbelLink.Request(kind: .stop, chatId: target.id))
            report(reply, did: "Stopped the agent in “\(target.title)”, asked by you", say: say.stopped(target.title))
        case .pauseEverything:
            let reply = await abstract.ask(AbelLink.Request(kind: .pauseAll))
            report(reply, did: "Paused every agent, asked by you", say: say.pausedAll)
        case let .status(chatId):
            guard let target = chat(chatId) else { return }
            self.say(say.status(target))
        case let .startChat(projectId, prompt):
            let project = context?.projects.first { $0.id == projectId }
            ask(say.startReadBack(prompt, in: project?.name), language: language) { yes in
                guard yes else { self.cancelled(language); return }
                let reply = await self.abstract.ask(AbelLink.Request(kind: .startChat, text: prompt, projectId: projectId))
                self.report(reply, did: "Started a chat\(project.map { " in \($0.name)" } ?? "") to “\(prompt)”, asked by you",
                            say: say.started(reply?.chatTitle ?? prompt))
            }
        case let .tell(chatId, text):
            guard let target = chat(chatId) else { return }
            ask(say.tellReadBack(target.title, text), language: language) { yes in
                guard yes else { self.cancelled(language); return }
                let reply = await self.abstract.ask(AbelLink.Request(kind: .tell, chatId: target.id, text: text))
                self.report(reply, did: "Told “\(target.title)”: “\(text)”, asked by you", say: say.told(target.title))
            }
        case .sendIt:
            await dictate(text, language: language, trigger: trigger)
        case .yes, .no:
            self.say(say.nothingToConfirm)
        case let .forbidden(action, chatId):
            await refuse(action, chatId: chatId ?? context?.shownChatId, language: language)
        case let .notFound(command, heard):
            self.say(command == "start" ? say.projectNotFound(heard) : say.notFound(heard))
        case let .ambiguous(_, ids):
            self.say(say.whichOne(ids.compactMap { chat($0)?.title }))
        case let .askABEL(question):
            let reply = await abstract.ask(AbelLink.Request(kind: .ask, text: question))
            guard let reply, reply.ok else {
                self.say(reply?.message ?? say.abstractClosed)
                return
            }
            record(.did, "Asked ABEL's chat: “\(question)”")
            self.say(say.askingABEL)
        }
    }

    func open(_ chat: AbelChatInfo, language: String) async {
        let say = AbelPhrases(language: language)
        let reply = await abstract.ask(AbelLink.Request(kind: .open, chatId: chat.id))
        let waiting = chat.waiting.map { " \(AbelPhrases.spoken("\(chat.title) \($0)"))." } ?? ""
        report(reply, did: "Opened “\(chat.title)”, asked by you", say: say.opening(chat.title) + waiting)
    }

    func readLast(_ chat: AbelChatInfo, language: String) async {
        let say = AbelPhrases(language: language)
        let reply = await abstract.ask(AbelLink.Request(kind: .reply, chatId: chat.id))
        guard let reply else { self.say(say.abstractClosed); return }
        let text = SpeakableText(markdown: reply.text ?? "")
        guard let first = text.first else { self.say(say.noReply); return }
        reading = (text, 0, chat.title)
        self.say("\(say.replied(chat.title)) \(first)")
    }

    /// Approve or deny the request a chat waits on: always read back, done
    /// only on "yes". Without a name: the chat on screen if it waits, else
    /// the first one that needs you.
    func answer(_ chatId: String?, allow: Bool, language: String, askedBy: String) async {
        let say = AbelPhrases(language: language)
        let shownWaits = chat(context?.shownChatId)?.state == .needsYou
        let target = chatId ?? (shownWaits ? context?.shownChatId : nil)
            ?? lastListed.first { chat($0)?.state == .needsYou } ?? chats.first { $0.state == .needsYou }?.id
        let reply = await abstract.ask(AbelLink.Request(kind: .pending, chatId: target))
        guard let pending = reply?.pending else { self.say(reply == nil ? say.abstractClosed : say.nothingWaiting); return }
        if pending.isQuestion || pending.onScreenOnly {
            _ = await abstract.ask(AbelLink.Request(kind: .open, chatId: pending.chatId))
            record(.refused, "Didn't answer \(pending.summary) in “\(pending.chatTitle)” by voice: it's answered on screen")
            self.say(pending.isQuestion ? say.questionInChat(pending.chatTitle) : say.approveOnScreen(pending.chatTitle))
            return
        }
        let question = allow ? say.allow(pending.summary, in: pending.chatTitle) : say.decline(pending.summary, in: pending.chatTitle)
        ask(question, language: language) { yes in
            guard yes else { self.cancelled(language); return }
            // Exactly the request read back: if it's gone, nothing is answered.
            let done = await self.abstract.ask(AbelLink.Request(kind: .answer, chatId: pending.chatId,
                                                                requestId: pending.requestId, allow: allow))
            self.report(done, did: "\(allow ? "Allowed" : "Declined") \(pending.summary) in “\(pending.chatTitle)”, asked by \(askedBy)",
                        say: allow ? say.allowed(pending.chatTitle) : say.declined(pending.chatTitle))
        }
    }

    func refuse(_ action: AbelForbidden, chatId: String?, language: String) async {
        let say = AbelPhrases(language: language)
        let target = chat(chatId)
        var opened = false
        if let target {
            let screen = action == .merge || action == .push ? "pullRequest" : "chat"
            opened = await abstract.ask(AbelLink.Request(kind: .showScreen, chatId: target.id, screen: screen))?.ok == true
        }
        record(.refused, "Didn't \(action.rawValue) by voice\(target.map { " in “\($0.title)”" } ?? "")")
        self.say(say.forbidden(action, chat: target?.title, opened: opened))
    }

    /// Says what happened, or why it didn't, and logs it.
    func report(_ reply: AbelLink.Reply?, did: String, say sentence: String) {
        guard let reply else { say(AbelPhrases(language: lastLanguage).abstractClosed); return }
        guard reply.ok else {
            record(.refused, reply.message ?? "That didn't work.")
            say(reply.message ?? "That didn't work.")
            return
        }
        record(.did, did)
        say(sentence)
    }

    // MARK: ABEL's chat's tools

    /// One tool call from ABEL's chat's agent. Only ABEL's own chat may
    /// call; acting tools are read back and need your "yes".
    func tool(_ name: String, arguments json: String, from chatId: String?) async -> (text: String, isError: Bool) {
        guard let chatId, chatId == settings.chatId else {
            return ("Only ABEL's own chat can use ABEL's tools.", true)
        }
        if let reason = machine.pauseReason { return (reason.sentence, true) }
        guard AbelTools.definitions.contains(where: { $0["name"]?.string == name }) else { return ("ABEL has no tool “\(name)”.", true) }
        let arguments = (try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))) ?? .object([:])
        await refreshContext()
        guard context != nil else { return ("Abstract isn't open.", true) }
        let say = AbelPhrases(language: lastLanguage)
        func named(_ key: String) -> AbelChatInfo? {
            guard let heard = arguments[key]?.string else { return nil }
            if let exact = chats.first(where: { $0.id == heard }) { return exact }
            if case let .one(id, _) = AbelNames.match(heard, among: chats.map { (id: $0.id, name: $0.title) }) { return chat(id) }
            return nil
        }
        switch name {
        case "list_chats":
            let state = arguments["state"]?.string ?? "all"
            let listed = chats.filter { chat in
                switch state {
                case "needs_you": chat.state == .needsYou
                case "working": chat.state == .working
                default: true
                }
            }
            return (listed.isEmpty ? "No chats." : listed.map(Self.line).joined(separator: "\n"), false)
        case "chat_status":
            guard let target = named("chat") else { return ("No chat matches “\(arguments["chat"]?.string ?? "")”.", true) }
            return (say.status(target), false)
        case "read_reply":
            guard let target = named("chat") else { return ("No chat matches “\(arguments["chat"]?.string ?? "")”.", true) }
            let reply = await abstract.ask(AbelLink.Request(kind: .reply, chatId: target.id))
            return (String((reply?.text ?? "That chat hasn't replied yet.").prefix(6_000)), false)
        case "start_chat":
            guard let prompt = arguments["prompt"]?.string, !prompt.isEmpty else { return ("Give the chat a prompt.", true) }
            var project: AbelProjectInfo?
            if let heard = arguments["project"]?.string, !heard.isEmpty {
                guard case let .one(id, _) = AbelNames.match(heard, among: (context?.projects ?? []).map { (id: $0.id, name: $0.name) })
                else { return ("No project matches “\(heard)”.", true) }
                project = context?.projects.first { $0.id == id }
            }
            guard await confirm(say.startReadBack(prompt, in: project?.name)) else { return ("The person said no.", true) }
            let reply = await abstract.ask(AbelLink.Request(kind: .startChat, text: prompt, projectId: project?.id))
            return outcome(reply, did: "Started a chat to “\(prompt)”, asked by ABEL's chat; you said yes",
                           done: "Started “\(reply?.chatTitle ?? prompt)”.")
        case "send_to_chat":
            guard let target = named("chat") else { return ("No chat matches “\(arguments["chat"]?.string ?? "")”.", true) }
            guard let text = arguments["text"]?.string, !text.isEmpty else { return ("There's no message to send.", true) }
            guard await confirm(say.tellReadBack(target.title, text)) else { return ("The person said no.", true) }
            let reply = await abstract.ask(AbelLink.Request(kind: .tell, chatId: target.id, text: text))
            return outcome(reply, did: "Told “\(target.title)”: “\(text)”, asked by ABEL's chat; you said yes",
                           done: "Sent to “\(target.title)”.")
        case "stop_chat":
            guard let target = named("chat") else { return ("No chat matches “\(arguments["chat"]?.string ?? "")”.", true) }
            let question = say.portuguese ? "Parar \(target.title)? Diga sim para confirmar." : "Stop \(target.title)? Say yes to confirm."
            guard await confirm(question) else { return ("The person said no.", true) }
            let reply = await abstract.ask(AbelLink.Request(kind: .stop, chatId: target.id))
            return outcome(reply, did: "Stopped “\(target.title)”, asked by ABEL's chat; you said yes", done: "Stopped “\(target.title)”.")
        case "answer_permission":
            guard let target = named("chat") else { return ("No chat matches “\(arguments["chat"]?.string ?? "")”.", true) }
            let allow = arguments["allow"]?.bool ?? false
            let reply = await abstract.ask(AbelLink.Request(kind: .pending, chatId: target.id))
            guard let pending = reply?.pending else { return ("Nothing is waiting in “\(target.title)”.", true) }
            guard !pending.isQuestion else { return ("“\(target.title)” asked a question; the person answers it in the chat.", true) }
            guard !pending.onScreenOnly else {
                return ("That request can't be read back whole, so the person approves it in “\(target.title)” on screen.", true)
            }
            let question = allow ? say.allow(pending.summary, in: pending.chatTitle) : say.decline(pending.summary, in: pending.chatTitle)
            guard await confirm(question) else { return ("The person said no.", true) }
            let done = await abstract.ask(AbelLink.Request(kind: .answer, chatId: pending.chatId, requestId: pending.requestId, allow: allow))
            return outcome(done, did: "\(allow ? "Allowed" : "Declined") \(pending.summary) in “\(pending.chatTitle)”, asked by ABEL's chat; you said yes",
                           done: "\(allow ? "Allowed" : "Declined") it.")
        default:
            return ("ABEL has no tool “\(name)”.", true)
        }
    }

    func outcome(_ reply: AbelLink.Reply?, did: String, done: String) -> (text: String, isError: Bool) {
        guard let reply else { return ("Abstract isn't open.", true) }
        guard reply.ok else {
            record(.refused, reply.message ?? "That didn't work.")
            return (reply.message ?? "That didn't work.", true)
        }
        record(.did, did)
        return (done, false)
    }

    /// One chat as a line for `list_chats`.
    static func line(_ chat: AbelChatInfo) -> String {
        let state = switch chat.state {
        case .needsYou: "needs you" + (chat.waiting.map { ": \($0)" } ?? "")
        case .working: "working"
        case .readyToReview: "ready to review"
        case .done: "done"
        }
        let project = chat.project.map { " in \($0)" } ?? ""
        let pr = chat.pullRequest.map { ", pull request #\($0)" + (chat.checks.map { " (checks \($0))" } ?? "") } ?? ""
        return "\(chat.title)\(project), \(chat.agent), \(state)\(pr) [id \(chat.id)]"
    }

    /// Reads `question` back and waits for your answer; false on anything
    /// but a clear yes, or after a while with no answer.
    func confirm(_ question: String) async -> Bool {
        guard pending == nil else { return false }
        let language = lastLanguage
        let window = confirmationWindow + .seconds(20)
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            var answered = false
            ask(question, language: language) { yes in
                guard !answered else { return }
                answered = true
                if !yes { self.cancelled(language) }
                continuation.resume(returning: yes)
            }
            Task { @MainActor in
                try? await Task.sleep(for: window)
                guard !answered else { return }
                answered = true
                self.pending = nil
                self.record(.refused, "No answer, so nothing was done")
                continuation.resume(returning: false)
            }
        }
    }
}
