import AbstractCore
import AppKit
import Foundation

/// What ABEL does in Abstract by voice (ABS-204). Acting goes through the
/// same actions plugins use (ABS-92), named "ABEL", so each chat says
/// "Sent by ABEL", "Answered by ABEL" and so on, never as if you'd done it.
/// ABEL has already read each one back and heard "yes" where it must.
extension AppModel {
    static let abelName = "ABEL"

    /// The chats ABEL knows: on this Mac, not archived, needing you first.
    func abelChats() -> [AbelChatInfo] {
        let rank: [AbelChatInfo.State: Int] = [.needsYou: 0, .working: 1, .readyToReview: 2, .done: 3]
        return sidebarChats().filter { !$0.id.hasPrefix(RemoteService.mirrorPrefix) && $0.session.archivedAt == nil }
            .map { chat -> AbelChatInfo in
                let state: AbelChatInfo.State = switch SidebarChats.status(of: chat) {
                case .needsYou: .needsYou
                case .working: .working
                case .readyToReview: .readyToReview
                default: .done
                }
                return AbelChatInfo(id: chat.id, title: chat.session.name, project: project(chat.session.projectId)?.name,
                                    agent: ProviderRegistry.name(chat.session.providerId), state: state,
                                    waiting: state == .needsYou ? abelWaiting(chat.id) : nil, activeAt: chat.activeAt,
                                    pullRequest: chat.pullRequest?.number, checks: chat.pullRequest?.checks?.rawValue,
                                    branch: chat.session.branch, pullRequestURL: pullRequests[chat.id]?.url?.absoluteString)
            }
            .sorted { (rank[$0.state] ?? 9, $1.activeAt) < (rank[$1.state] ?? 9, $0.activeAt) }
    }

    /// What a chat that needs you waits for, in words.
    func abelWaiting(_ chatId: String) -> String {
        guard let request = pendingPermissions(chatId).first else { return "is waiting for your reply" }
        return request.toolName == AgentQuestion.toolName ? "has a question" : "wants to \(abelSummary(chatId, request).text)"
    }

    /// What allowing a request lets through, read back whole: "run `swift
    /// test`", "edit Sources/App/Row.swift". `onScreen` when it can't be:
    /// a tangled or long command, a file outside the chat's folder, or any
    /// other tool. Those are approved in the chat, never by voice.
    func abelSummary(_ chatId: String, _ request: PendingPermission) -> (text: String, onScreen: Bool) {
        let pending = PluginPendingRequest(chatId: chatId, requestId: request.requestId, toolName: request.toolName,
                                           input: request.input, requestedAt: request.requestedAt)
        if let command = pending.command {
            return AbelReadBack.canReadBack(command: command) ? ("run `\(command)`", false) : ("run a long command", true)
        }
        if let path = PluginPermissions.path(pending) {
            let verb = switch request.toolName.lowercased() {
            case "edit", "multiedit", "write", "notebookedit": "edit"
            case "read": "read"
            default: "use \(request.toolName) on"
            }
            if let readable = AbelReadBack.readablePath(path, in: session(chatId)?.worktreePath) {
                return ("\(verb) \(readable)", false)
            }
            return ("\(verb) a file outside its folder", true)
        }
        return ("use \(request.toolName)", true)
    }

    func answerAbelCommand(_ request: AbelLink.Request) async -> AbelLink.Reply {
        func local(_ id: String?) -> Session? {
            guard let id, !id.hasPrefix(RemoteService.mirrorPrefix) else { return nil }
            return session(id)
        }
        do {
            switch request.kind {
            case .open:
                guard let chat = local(request.chatId) else { return .failed("That chat isn't here any more.") }
                destination = .session(chat.id)
                NSApp.activate()
                return AbelLink.Reply(ok: true, chatTitle: chat.name)
            case .reply:
                guard let chat = local(request.chatId) else { return .failed("That chat isn't here any more.") }
                loadTimelineIfNeeded(chat.id)
                return AbelLink.Reply(ok: true, chatTitle: chat.name, text: feed(chat.id).timeline.lastReply)
            case .pending:
                let ids = request.chatId.map { [$0] } ?? abelChats().filter { $0.state == .needsYou }.map(\.id)
                for id in ids {
                    guard let chat = local(id), let waiting = pendingPermissions(id).first else { continue }
                    let summary = abelSummary(id, waiting)
                    let question = waiting.toolName == AgentQuestion.toolName
                    return AbelLink.Reply(ok: true, chatTitle: chat.name, pending: AbelLink.Pending(
                        chatId: id, chatTitle: chat.name, requestId: waiting.requestId, summary: summary.text,
                        isQuestion: question, onScreenOnly: !question && summary.onScreen))
                }
                return AbelLink.Reply(ok: true)
            case .answer:
                guard let chatId = request.chatId, let chat = local(chatId), let requestId = request.requestId,
                      let allow = request.allow else { return .failed("That answer couldn't be read.") }
                _ = try await performPluginAction(PluginAction(capability: .permissionsAnswer, chatId: chatId,
                                                               requestId: requestId, allow: allow), pluginName: Self.abelName)
                return AbelLink.Reply(ok: true, chatTitle: chat.name)
            case .stop:
                guard let chat = local(request.chatId) else { return .failed("That chat isn't here any more.") }
                _ = try await performPluginAction(PluginAction(capability: .chatsControl, chatId: chat.id, control: .stop),
                                                  pluginName: Self.abelName)
                return AbelLink.Reply(ok: true, chatTitle: chat.name)
            case .pauseAll:
                pauseEverything()
                return AbelLink.Reply(ok: true)
            case .startChat:
                guard let prompt = request.text, !prompt.isEmpty else { return .failed("A new chat needs a prompt.") }
                let project = request.projectId.flatMap { id in projects.first { $0.id == id } }
                if request.projectId != nil, project == nil { return .failed("That project isn't on this Mac.") }
                // Never Full autonomy by voice: a project that starts there starts at Accept edits.
                let policy = project?.defaultPermissionPolicy == .bypass ? PermissionPolicy.autoEdits.rawValue : nil
                let key = project.map { PluginSnapshot.projectKey(macId: remote.identity.id, projectId: $0.id) }
                let result = try await performPluginAction(PluginAction(capability: .chatsCreate, projectKey: key, text: prompt,
                                                                        policy: policy), pluginName: Self.abelName)
                let id = result["chatId"]?.string
                return AbelLink.Reply(ok: true, chatTitle: id.flatMap { session($0)?.name }, chatId: id)
            case .tell:
                guard let chat = local(request.chatId), let text = request.text, !text.isEmpty else {
                    return .failed("There's no message to send.")
                }
                _ = try await performPluginAction(PluginAction(capability: .chatsMessage, chatId: chat.id, text: text),
                                                  pluginName: Self.abelName)
                return AbelLink.Reply(ok: true, chatTitle: chat.name)
            case .showScreen:
                guard let chat = local(request.chatId) else { return .failed("That chat isn't here any more.") }
                destination = .session(chat.id)
                if request.screen == "pullRequest" { showPane(.review, in: chat.id) }
                NSApp.activate()
                return AbelLink.Reply(ok: true, chatTitle: chat.name)
            case .ask:
                guard let text = request.text, !text.isEmpty else { return .failed("There was nothing to ask.") }
                let id = try await askAbelChat(text)
                return AbelLink.Reply(ok: true, chatTitle: AbelTools.chatName, chatId: id)
            case .context, .dictate, .sendDraft:
                return .failed("Abstract can't do that here.")
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: ABEL's own chat

    /// Sends `text` to ABEL's chat, starting it first if there isn't one:
    /// a chat of its own named ABEL, pinned, run by the agent and profile
    /// picked in Settings › ABEL, with ABEL's instructions and tools.
    func askAbelChat(_ text: String) async throws -> String {
        if let id = abelSettings.chatId, let chat = session(id), chat.archivedAt == nil {
            try sendFollowUp(chat.id, text: text)
            return chat.id
        }
        let agentId = ProviderRegistry.provider(abelSettings.agentId) != nil ? abelSettings.agentId : "claude"
        let picked = abelSettings.profileId.flatMap { id in profiles.first { $0.id == id } }
        let instructions = [AbelTools.instructions, picked?.instructions].compactMap { $0 }.joined(separator: "\n\n")
        // The chat's id is known only once it exists, and its agent starts
        // with it: until then the tools go to the chat started from this
        // one-off profile id, which no other chat can have.
        let nonce = "abel-\(UUID().uuidString)"
        let profile = ProfileSnapshot(id: nonce, name: picked?.name ?? AbelTools.chatName, instructions: instructions)
        abelStartingProfile = nonce
        defer { abelStartingProfile = nil }
        let id = try await startChat(projectId: nil, providerId: agentId, prompt: text, baseRef: nil, policy: .ask,
                                     name: AbelTools.chatName, nameSource: .manual, profile: profile, select: false)
        setPinned(id, true)
        updateAbelSettings { $0.chatId = id }
        engine.record(sessionId: id, OutputLine(stream: .note, line: "ABEL's own chat: what you ask ABEL by voice comes here, and its answers are read aloud."))
        return id
    }

    /// The `abstract` command that serves ABEL's tools to `session`, when
    /// it's ABEL's chat.
    func abelToolsCommand(for session: Session) -> String? {
        guard session.id == abelSettings.chatId || (abelStartingProfile != nil && session.profileId == abelStartingProfile)
        else { return nil }
        let tool = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/abstract").path
        return FileManager.default.isExecutableFile(atPath: tool) ? tool : nil
    }
}
