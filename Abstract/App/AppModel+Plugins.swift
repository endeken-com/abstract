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

    /// The current palette, the way a plugin receives it.
    func pluginTheme() -> Theme {
        ThemeState.shared.theme(for: NSApp.effectiveAppearance)
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
}
