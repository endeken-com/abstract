import AppKit
import Foundation
import AbstractCore

/// Plugins, from the model's side: the allowlisted snapshot a plugin may
/// see, and navigation when one is turned off or removed. A plugin never
/// sees this model — only the snapshot built here (ABS-84 §4).
extension AppModel {
    /// The snapshot for one plugin's grants. Built from the same facts the
    /// sidebar joins, so local and paired-Mac chats arrive in one list.
    func pluginSnapshot(capabilities: Set<PluginCapability>, revision: Int) -> PluginSnapshot {
        let thisMac = remote.identity.id
        var macs = [PluginSnapshot.Mac(id: thisMac, name: remote.identity.name, isThisMac: true, reachable: true)]
        for device in remote.paired {
            macs.append(.init(id: device.id, name: device.peer.name, isThisMac: false,
                              reachable: remote.links[device.id]?.snapshot != nil))
        }

        var projects = self.projects.map {
            PluginSnapshot.Project(key: PluginSnapshot.projectKey(macId: thisMac, projectId: $0.id),
                                   name: $0.name, macId: thisMac, archived: $0.archivedAt != nil)
        }
        for device in remote.paired {
            for project in remote.links[device.id]?.snapshot?.projects ?? [] {
                projects.append(.init(key: PluginSnapshot.projectKey(macId: device.id, projectId: project.id),
                                      name: project.name, macId: device.id, archived: project.archivedAt != nil))
            }
        }

        let chats = sidebarChats().map { chat -> PluginSnapshot.ChatInput in
            if let (device, _) = RemoteService.split(chat.id) {
                return .init(chat: chat,
                             projectKey: chat.session.projectId.map { PluginSnapshot.projectKey(macId: device, projectId: $0) },
                             macId: device)
            }
            return .init(chat: chat,
                         projectKey: chat.session.projectId.map { PluginSnapshot.projectKey(macId: thisMac, projectId: $0) },
                         macId: thisMac)
        }
        return PluginSnapshot.build(revision: revision, capabilities: capabilities,
                                    macs: macs, projects: projects, chats: chats)
    }

    /// What a plugin's live data is made of. Reading it under observation
    /// is how a screen redraws, and the background host notices, when a
    /// chat moves — without polling.
    var pluginLiveFingerprint: Int {
        var hasher = Hasher()
        for session in sessions {
            hasher.combine(session.id); hasher.combine(session.status); hasher.combine(session.name)
            hasher.combine(session.archivedAt); hasher.combine(session.pinnedAt); hasher.combine(session.lastEventAt)
            hasher.combine(session.branch); hasher.combine(session.projectId)
        }
        hasher.combine(projects.map(\.id))
        // A pull request's checks and review move without the count moving.
        for id in pullRequests.keys.sorted() {
            hasher.combine(id)
            if let pr = pullRequests[id] { hasher.combine(SidebarChats.PullRequestFacts(pr)) }
        }
        for id in branchStates.keys.sorted() { hasher.combine(id); hasher.combine(branchStates[id]?.dirty) }
        hasher.combine(remote.paired.map(\.id))
        // A request can arrive or be answered without its chat's status moving.
        for id in permissions.keys.sorted() { hasher.combine(id); hasher.combine(permissions[id]?.map(\.requestId)) }
        for (id, link) in remote.links { hasher.combine(id); hasher.combine(link.snapshot?.sessions.count ?? -1) }
        return hasher.finalize()
    }

    /// The palette a plugin draws in: the theme picked in Abstract
    /// (ABS-134). The Mac's appearance, which is what `NSApp` reports, only
    /// counts under Match System; Graphite stays dark on a Mac set to Light.
    func pluginAppearance() -> PluginAppearance {
        let look = ThemeState.look(of: NSApp.effectiveAppearance)
        return .resolve(choice: ThemeState.shared.current, systemDark: look.dark, increasedContrast: look.increasedContrast)
    }

    func setPluginEnabled(_ id: String, _ enabled: Bool, transcriptProjectKeys: [String]? = nil) {
        plugins.setEnabled(id, enabled, transcriptProjectKeys: transcriptProjectKeys)
        if !enabled { leavePluginScreen(id) }
    }

    /// The project keys a plugin may pick from at review: this Mac's projects.
    func pluginProjectChoices() -> [(key: String, name: String)] {
        projects.map { (PluginSnapshot.projectKey(macId: remote.identity.id, projectId: $0.id), $0.name) }
    }

    /// Names for picked project keys, in pick order, for review sentences.
    func pluginProjectNames(_ keys: [String]) -> [String] {
        let byKey = Dictionary(uniqueKeysWithValues: pluginProjectChoices().map { ($0.key, $0.name) })
        return keys.compactMap { byKey[$0] }
    }

    // MARK: Data pulls (ABS-95)

    /// Usage from the same ledger Settings → Usage reads, with each
    /// response attributed to the chat whose worktree it ran in.
    func pluginUsage(view: String, page: PluginPage, chatId: String?) async -> JSONValue {
        if usage.loadedAt == nil { await usage.load() }
        let entries = usage.records.map { record in
            PluginData.UsageEntry(chatId: pluginChatId(forCwd: record.cwd), record: record)
        }
        return PluginData.usage(entries: entries, view: view, chatId: chatId, page: page)
    }

    /// The chat a folder belongs to, the way Usage names its workspaces:
    /// the chat whose worktree holds it, if any.
    private func pluginChatId(forCwd cwd: String) -> String? {
        let path = cwd.hasPrefix("/private/") ? String(cwd.dropFirst("/private".count)) : cwd
        guard !path.isEmpty else { return nil }
        return sessions.first { session in
            guard let root = session.worktreePath, !root.isEmpty else { return false }
            return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }?.id
    }

    /// Finished turns across this Mac's chats (or one chat's), oldest first.
    func pluginTurns(page: PluginPage, chatId: String?) -> JSONValue {
        PluginData.turns(chats: pluginTimelines(chatId: chatId).map { (chatId: $0.id, timeline: $0.timeline) }, page: page)
    }

    /// Messages from the picked projects' chats only. A chat named in the
    /// request still has to be in one of them.
    func pluginTranscript(page: PluginPage, chatId: String?, allowedProjectKeys: [String]) -> JSONValue {
        let thisMac = remote.identity.id
        let chats = pluginTimelines(chatId: chatId).map { chat in
            (chatId: chat.id,
             projectKey: chat.projectId.map { PluginSnapshot.projectKey(macId: thisMac, projectId: $0) },
             timeline: chat.timeline)
        }
        return PluginData.transcript(chats: chats, allowedProjectKeys: Set(allowedProjectKeys), page: page)
    }

    /// This Mac's chats with their logs read, oldest first. Reading a log
    /// is the same work opening the chat does; a paired Mac's chats keep
    /// their messages on that Mac, so they aren't included.
    private func pluginTimelines(chatId: String?) -> [(id: String, projectId: String?, timeline: Timeline)] {
        sessions
            .filter { chatId == nil || $0.id == chatId }
            .sorted { $0.createdAt < $1.createdAt }
            .map { session in
                loadTimelineIfNeeded(session.id)
                return (id: session.id, projectId: session.projectId, timeline: feed(session.id).timeline)
            }
    }

    func pluginAutomations(page: PluginPage) -> JSONValue {
        let thisMac = remote.identity.id
        let items = automations.map { automation in
            (automation: automation,
             projectKey: automation.projectId.map { PluginSnapshot.projectKey(macId: thisMac, projectId: $0) },
             lastRun: (try? store.lastRun(automationId: automation.id)) ?? nil)
        }
        return PluginData.automations(items: items, page: page)
    }

    // MARK: Waiting requests (ABS-111)

    /// Every permission request and question waiting in a chat here or
    /// on a paired Mac, the way a plugin that may answer them sees them.
    func pluginPendingRequests() -> [PluginPendingRequest] {
        permissions.flatMap { chatId, requests -> [PluginPendingRequest] in
            guard let session = session(chatId) else { return [] }
            return requests.map {
                PluginPendingRequest(chatId: chatId, requestId: $0.requestId, toolName: $0.toolName, input: $0.input,
                                     requestedAt: $0.requestedAt, root: session.worktreePath)
            }
        }
    }

    /// Whose requests are waiting, for `permission.resolved`.
    func pluginPendingTargets() -> Set<PluginAction.Target> {
        Set(permissions.flatMap { chatId, requests in
            requests.map { PluginAction.Target(chatId: chatId, requestId: $0.requestId) }
        })
    }

    /// What answering would let through, for the ask: the command or file
    /// the request is about.
    func pluginAnswerPreview(_ action: PluginAction) -> String? {
        let pending = pluginPendingRequests()
        let target = action.batch.first ?? action.chatId.flatMap { chatId in
            action.requestId.map { PluginAction.Target(chatId: chatId, requestId: $0) }
        }
        guard let target, let request = pending.first(where: {
            $0.chatId == target.chatId && $0.requestId == target.requestId
        }) else { return nil }
        if let command = request.command { return command }
        return PluginPermissions.path(request).map { "\(request.toolName) \($0)" } ?? request.toolName
    }

    /// Answers one request as the chat's own card would, and notes on its
    /// tool row where it was answered.
    private func answerFromPlugin(_ chatId: String, requestId: String, allow: Bool?, answers: [String: String],
                                  pluginName: String) throws {
        guard let request = pendingPermissions(chatId).first(where: { $0.requestId == requestId }) else {
            throw AbstractError.message("That request isn't waiting any more.")
        }
        guard !answers.isEmpty || allow != nil else { throw AbstractError.message("That answer couldn't be read.") }
        if allow == true, !PluginPermissions.mayAllowFromPlugin(PluginPendingRequest(
            chatId: chatId, requestId: requestId, toolName: request.toolName, input: request.input, requestedAt: request.requestedAt)) {
            throw AbstractError.message("That command is too long to show here. Allow it in its chat.")
        }
        recordAnswerNote("Answered from \(pluginName)", requestId: requestId, toolName: request.toolName,
                         input: request.input, in: chatId)
        if !answers.isEmpty {
            answerQuestion(chatId, requestId: requestId, answers: answers)
        } else if let allow {
            answerPermission(chatId, requestId: requestId, allow: allow)
        }
        if !chatId.hasPrefix(RemoteService.mirrorPrefix) {
            engine.record(sessionId: chatId, OutputLine(stream: .note, line: "Answered by \(pluginName)."))
        }
    }

    // MARK: Actions (ABS-92)

    /// The ask for one action, named the way the person knows the chat,
    /// project or automation it touches.
    func pluginActionDescription(_ action: PluginAction, pluginName: String) -> String {
        action.describe(
            pluginName: pluginName,
            chatTitle: (action.chatId ?? action.reviewOf).flatMap { session($0)?.name },
            projectName: action.projectKey.flatMap { key in
                projects.first {
                    PluginSnapshot.projectKey(macId: remote.identity.id, projectId: $0.id) == key
                }?.name
            },
            automationName: action.automationId.flatMap { id in automations.first { $0.id == id }?.name })
    }

    /// Carries out one action the bridge granted and, where its kind
    /// asks first, the person allowed. Everything it does in a chat is
    /// marked with the plugin's name, so the chat never reads as if the
    /// person had done it themselves.
    func performPluginAction(_ action: PluginAction, pluginName: String) async throws -> JSONValue {
        switch action.capability {
        case .chatsCreate:
            guard let prompt = action.text else { throw AbstractError.message("A new chat needs a prompt.") }
            if let reviewed = action.reviewOf {
                return try await startPluginReviewer(of: reviewed, agentId: action.agentId, prompt: prompt, pluginName: pluginName)
            }
            var project: Project?
            if let projectKey = action.projectKey {
                project = projects.first {
                    PluginSnapshot.projectKey(macId: remote.identity.id, projectId: $0.id) == projectKey
                }
                guard project != nil else { throw AbstractError.message("That project isn't on this Mac.") }
            }
            if let agentId = action.agentId, ProviderRegistry.provider(agentId) == nil {
                throw AbstractError.message("Abstract doesn't know that agent.")
            }
            let id = try await startChat(
                projectId: project?.id,
                providerId: action.agentId ?? project?.defaultProviderId ?? "claude",
                prompt: prompt, baseRef: nil,
                policy: action.policy.flatMap(PermissionPolicy.init(rawValue:))
                    ?? project?.defaultPermissionPolicy ?? .ask,
                select: false)
            engine.record(sessionId: id, OutputLine(stream: .note, line: "Started by \(pluginName)."))
            return .object(["chatId": .string(id)])

        case .chatsMessage where action.sendsReview:
            guard let chatId = action.chatId, session(chatId) != nil, !chatId.hasPrefix(RemoteService.mirrorPrefix) else {
                throw AbstractError.message("That chat isn't here any more.")
            }
            guard !comments(chatId).isEmpty else { throw AbstractError.message("There are no comments in Review to send.") }
            engine.record(sessionId: chatId, OutputLine(stream: .note, line: "Review sent by \(pluginName)."))
            // As your own Send does: the comments go with the words, are
            // kept as notes on their lines, and leave Review.
            try sendFollowUp(chatId, text: messageWithReview(chatId, text: action.text ?? ""))
            keepCommentsAsNotes(chatId)
            discardComments(chatId)
            return .object(["sent": .bool(true)])

        case .chatsMessage:
            guard let chatId = action.chatId, let text = action.text, session(chatId) != nil else {
                throw AbstractError.message("That chat isn't here any more.")
            }
            if chatId.hasPrefix(RemoteService.mirrorPrefix) {
                try await sendRemoteFollowUp(chatId, text: text)
            } else {
                engine.record(sessionId: chatId, OutputLine(stream: .note, line: "Sent by \(pluginName)."))
                do {
                    try sendFollowUp(chatId, text: text)
                } catch {
                    engine.record(sessionId: chatId,
                                  OutputLine(stream: .note, line: "\(pluginName)'s message couldn't be sent."))
                    throw error
                }
            }
            return .object(["sent": .bool(true)])

        case .chatsControl:
            guard let chatId = action.chatId, let control = action.control, session(chatId) != nil else {
                throw AbstractError.message("That chat isn't here any more.")
            }
            let words = switch control {
            case .stop: "stopped this agent"
            case .pause: "paused this agent"
            case .resume: "resumed this agent"
            }
            switch control {
            case .stop: stopAgent(chatId)
            case .pause: stop(chatId)
            case .resume: resume(chatId)
            }
            if !chatId.hasPrefix(RemoteService.mirrorPrefix) {
                engine.record(sessionId: chatId, OutputLine(stream: .note, line: "\(pluginName) \(words)."))
            }
            return .object(["done": .bool(true)])

        case .permissionsAnswer where !action.batch.isEmpty:
            // All still waiting and exactly the same command, or none answered.
            let requests = try PluginPermissions.batch(action.batch, pending: pluginPendingRequests())
            guard requests.allSatisfy(PluginPermissions.mayAllowFromPlugin) else {
                throw AbstractError.message("That command is too long to show here. Allow it in each chat.")
            }
            for request in requests {
                try answerFromPlugin(request.chatId, requestId: request.requestId, allow: true, answers: [:],
                                     pluginName: pluginName)
            }
            return .object(["done": .bool(true), "answered": .number(Double(requests.count))])

        case .permissionsAnswer:
            guard let chatId = action.chatId, let requestId = action.requestId else {
                throw AbstractError.message("That answer needs the chat and the request it answers.")
            }
            try answerFromPlugin(chatId, requestId: requestId, allow: action.allow, answers: action.answers,
                                 pluginName: pluginName)
            return .object(["done": .bool(true)])

        case .automationsRun:
            guard let automationId = action.automationId,
                  let automation = automations.first(where: { $0.id == automationId }) else {
                throw AbstractError.message("That automation isn't here any more.")
            }
            let run = await runAutomationNow(automation)
            return .object(["started": .bool(run != nil && run?.status != .failed),
                            "automationId": .string(automationId)])

        default:
            throw AbstractError.message("Abstract doesn't know that action.")
        }
    }

    // MARK: Review (ABS-112)

    /// A read-only chat on another agent, in the reviewed chat's worktree,
    /// which it reads without taking over. Named for what it reviews.
    private func startPluginReviewer(of reviewedId: String, agentId: String?, prompt: String,
                                     pluginName: String) async throws -> JSONValue {
        guard let reviewed = session(reviewedId), !reviewedId.hasPrefix(RemoteService.mirrorPrefix),
              reviewed.reviewsSessionId == nil, let path = reviewed.worktreePath else {
            throw AbstractError.message("Only a chat on this Mac, working in its own folder, can be reviewed.")
        }
        let agentId = agentId ?? reviewed.providerId
        guard ProviderRegistry.provider(agentId) != nil else { throw AbstractError.message("Abstract doesn't know that agent.") }
        guard providerStatus[agentId]?.available != false else {
            throw AbstractError.message("\(ProviderRegistry.name(agentId)) isn't installed on this Mac.")
        }
        let id = try await startChat(
            projectId: reviewed.projectId, providerId: agentId, prompt: prompt, baseRef: nil, policy: .readOnly,
            existing: WorktreeInfo(path: path, branch: reviewed.branch),
            name: "\(ProviderRegistry.name(agentId))'s review of “\(reviewed.name)”", nameSource: .manual,
            reviewing: reviewedId, select: false)
        engine.record(sessionId: id, OutputLine(stream: .note, line: "Started by \(pluginName) to review “\(reviewed.name)”."))
        return .object(["chatId": .string(id)])
    }

    /// A plugin's findings, as line comments in the chat's Review marked
    /// with who wrote them. They wait there for you to send or delete.
    func addPluginReviewComments(_ chatId: String, author: String, _ comments: [PluginReviewComment]) -> Int {
        guard let s = session(chatId) else { return 0 }
        var lines: [String: [Substring]] = [:]
        for comment in comments {
            // The line's code, quoted back to the agent, when the file reads.
            if lines[comment.path] == nil, let root = s.worktreePath, !chatId.hasPrefix(RemoteService.mirrorPrefix) {
                lines[comment.path] = PluginReviewComment.lines(inWorktree: root, path: comment.path)
            }
            let code = lines[comment.path].flatMap { comment.line <= $0.count ? String($0[comment.line - 1]) : nil } ?? ""
            addComment(chatId, on: LineRef(path: comment.path, line: comment.line, side: .new), code: code,
                       text: comment.text, source: "\(author)'s review", author: author)
        }
        return comments.count
    }

    /// What sending a chat's Review would send, for the ask: each comment,
    /// who wrote it, and where.
    func reviewSendPreview(_ chatId: String, text: String?) -> String {
        let all = comments(chatId)
        // One line per comment, whatever it holds, so none can pass for
        // another; a plugin's comments say so.
        func flat(_ text: String, _ limit: Int) -> String {
            let line = String(text.unicodeScalars.map { CharacterSet.controlCharacters.union(.newlines).contains($0) ? " " : Character($0) })
            return line.count > limit ? line.prefix(limit) + "… (\(line.count - limit) more characters)" : line
        }
        var lines = all.prefix(8).map { c in
            "• \(c.author.map { "\(flat($0, 40)), added by a plugin" } ?? "You") on \(flat(c.ref.path, 80)):\(c.ref.line): \(flat(c.text, 120))"
        }
        if all.count > 8 { lines.append("and \(all.count - 8) more") }
        if let text, !text.isEmpty { lines.insert(flat(text, 300), at: 0) }
        return lines.isEmpty ? "There are no comments in Review." : lines.joined(separator: "\n")
    }

    /// Run a plugin's Review command (ABS-112): its background script is
    /// handed the chat, what the Review compares, and the agent picked.
    func invokePluginReview(_ contribution: ResolvedPluginContribution, chatId: String, agentId: String?, scope: String) {
        let invocation = PluginInvocation(place: .review, contributionId: contribution.contribution.id,
                                          chatId: chatId, agentId: agentId, scope: scope)
        guard pluginBackground?.invoke(contribution.pluginId, invocation) == true else {
            flash("\(contribution.pluginName) isn't running. Turn it on, with its background script, in Settings → Plugins.",
                  isError: true)
            return
        }
    }

    func removePlugin(_ id: String) {
        plugins.remove(id)
        leavePluginScreen(id)
    }

    /// A plugin that's off loses its screen and its side-panel tabs:
    /// Abstract goes home, and every chat's panels forget the plugin.
    /// Its menu items, ⌘K commands, Settings page and Home cards are
    /// derived from what's usable, so they are already gone.
    private func leavePluginScreen(_ id: String) {
        if case .plugin(let showing, _) = destination, showing == id { destination = .home }
        pluginInvocations[id] = nil
        for sessionId in Set(sessions.map(\.id)).union(layouts.keys) {
            if layout(for: sessionId).items(of: .plugin)
                .contains(where: { PluginContributions.parsePaneItemId($0.id)?.pluginId == id }) {
                updateLayout(sessionId) { $0.removePluginTabs(pluginId: id) }
            }
        }
    }

    /// Open a plugin's tab in this chat's side panel (ABS-96).
    func showPluginPanelTab(_ contribution: ResolvedPluginContribution, in sessionId: String) {
        updateLayout(sessionId) { $0.showPluginTab(paneItemId: PluginContributions.paneItemId(for: contribution)) }
    }

    /// Run a plugin's chat menu item or ⌘K command: its screen opens and is
    /// handed the invocation, with the chat it was run from when it has one.
    func invokePlugin(_ contribution: ResolvedPluginContribution, chatId: String? = nil) {
        pluginInvocations[contribution.pluginId] = PluginInvocation(
            place: contribution.place, contributionId: contribution.contribution.id, chatId: chatId)
        let viewId = plugins.plugin(contribution.pluginId)?.view?.id ?? contribution.contribution.id
        destination = .plugin(contribution.pluginId, viewId)
    }

    /// The one chat a placed plugin sits beside, as its snapshot row —
    /// only built under `chats.read` (the context builder checks again).
    func pluginChatRow(chatId: String, capabilities: Set<PluginCapability>) -> PluginSnapshot.Chat? {
        guard capabilities.contains(.chatsRead) else { return nil }
        return pluginSnapshot(capabilities: capabilities, revision: 0).chats?.first { $0.id == chatId }
    }

    // MARK: Pull Request switches (ABS-109)

    /// Flip a plugin's switch in a chat's Pull Request tab: its background
    /// script is told first, and the switch moves only if it was.
    func setPluginSwitch(_ contribution: ResolvedPluginContribution, chatId: String, on: Bool) {
        let invocation = PluginInvocation(place: .pullRequest, contributionId: contribution.contribution.id,
                                          chatId: chatId, on: on)
        guard pluginBackground?.invoke(contribution.pluginId, invocation) == true else {
            flash("\(contribution.pluginName) isn't running. Turn it on, with its background script, in Settings → Plugins.",
                  isError: true)
            return
        }
        plugins.setSwitch(pluginId: contribution.pluginId, contributionId: contribution.contribution.id, chatId: chatId, on: on)
    }

    /// A chat's pull request in full, as far as Abstract has read it.
    func pluginPullRequest(chatId: String) -> JSONValue {
        guard let pr = pullRequests[chatId] else { return .object(["pullRequest": .null]) }
        return .object(["pullRequest": PluginData.pullRequest(pr)])
    }

    /// Keeps every pull request a switch is on for read in full, its
    /// reviews and comments included, as the Pull Request tab does while
    /// it's open. A switch goes off once its pull request is merged or
    /// closed, or its chat is gone, and its plugin is told.
    func refreshSwitchedPullRequests() async {
        for item in plugins.switchesOn {
            let chatId = item.chatId
            let finished = pullRequests[chatId].map { $0.state != .open } ?? false
            if session(chatId) == nil || finished {
                let invocation = PluginInvocation(place: .pullRequest, contributionId: item.contributionId, chatId: chatId, on: false)
                _ = pluginBackground?.invoke(item.pluginId, invocation)
                plugins.setSwitch(pluginId: item.pluginId, contributionId: item.contributionId, chatId: chatId, on: false)
                continue
            }
            _ = try? await refreshPullRequest(chatId)
        }
    }
}
