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

    /// A plugin that's off loses its screen: Abstract goes home.
    private func leavePluginScreen(_ id: String) {
        if case .plugin(let showing, _) = destination, showing == id { destination = .home }
    }
}
