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

    func setPluginEnabled(_ id: String, _ enabled: Bool) {
        plugins.setEnabled(id, enabled)
        if !enabled { leavePluginScreen(id) }
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
