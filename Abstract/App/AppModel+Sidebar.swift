import Foundation
import AbstractCore

/// What the sidebar knows of every chat, here and on paired Macs, for
/// `SidebarChats` to group.
extension AppModel {
    /// Every chat the sidebar can show: this Mac's, then those on paired Macs connected now.
    func sidebarChats() -> [SidebarChats.Chat] {
        let here = remote.identity.name
        // Projects and their icons are resolved once here, not once per chat:
        // a linear project lookup and an icon-file check per chat made every
        // sidebar refresh cost projects × chats (ABS-159).
        let projectsById = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var iconsByProjectId: [String: SidebarChats.Icon] = [:]
        let localProject = { (id: String?) -> Project? in id.flatMap { projectsById[$0] ?? self.remote.project($0) } }
        let localChildren = Dictionary(grouping: sessions.filter { $0.parentSessionId != nil }, by: { $0.parentSessionId! })
        let local = sessions.filter { !$0.id.hasPrefix(RemoteService.mirrorPrefix) }.map { s in
            let project = localProject(s.projectId)
            let icon: SidebarChats.Icon
            if let project, let projectId = s.projectId {
                if let cached = iconsByProjectId[projectId] { icon = cached } else {
                    icon = SidebarChats.icon(project: project, isRemote: false, remoteImage: nil)
                    iconsByProjectId[projectId] = icon
                }
            } else { icon = .agentLogo }
            return SidebarChats.Chat(session: s, pullRequest: pullRequests[s.id].map(SidebarChats.PullRequestFacts.init),
                              // A chat with no folder has nothing to review.
                              hasChanges: s.worktreePath == nil ? false : branchStates[s.id]?.hasUnmergedWork,
                              backgroundTasks: runningBackgroundTasks(s.id), projectName: project?.name,
                              mac: here, icon: icon,
                              subtaskProgress: localChildren[s.id].map { children in
                                  .init(done: children.count { [.idle, .finished].contains($0.status) }, total: children.count)
                              }, stalled: stallState(s.id)?.isStalled ?? false)
        }
        let paired = remote.paired.compactMap { remote.links[$0.id] }.flatMap { link -> [SidebarChats.Chat] in
            guard let snapshot = link.snapshot else { return [] }
            let projects = Dictionary(snapshot.projects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let busy = Set(snapshot.backgroundTasks ?? [])
            let children = Dictionary(grouping: snapshot.sessions.filter { $0.parentSessionId != nil }, by: { $0.parentSessionId! })
            return snapshot.sessions.map { hosted in
                var s = hosted
                s.id = RemoteService.mirrorId(device: link.device.id, session: hosted.id)
                let hostedProject = hosted.projectId.flatMap { projects[$0] }
                return SidebarChats.Chat(session: s, pullRequest: snapshot.pullRequests?[hosted.id].map(SidebarChats.PullRequestFacts.init),
                                         hasChanges: hosted.worktreePath == nil ? false : snapshot.unmergedWork?[hosted.id],
                                         backgroundTasks: max(runningBackgroundTasks(s.id), busy.contains(hosted.id) ? 1 : 0),
                                         projectName: hostedProject?.name,
                                         mac: link.device.peer.name, isRemote: true,
                                         icon: SidebarChats.icon(project: hostedProject, isRemote: true,
                                                                 remoteImage: hosted.projectId.flatMap { snapshot.projectIcons?[$0] }),
                                         subtaskProgress: children[hosted.id].map { group in
                                             .init(done: group.count { [.idle, .finished].contains($0.status) }, total: group.count)
                                         })
            }
        }
        return local + paired
    }

    /// Reads where each chat's branch stands, once, so the sidebar can tell
    /// work waiting for review from work that's done. A turn's end reads its
    /// chat's again (`setStatus`).
    func readEveryBranch() async {
        let chats = sessions.filter { $0.archivedAt == nil && $0.worktreePath != nil && !$0.id.hasPrefix(RemoteService.mirrorPrefix) }
            .sorted { ($0.lastEventAt ?? $0.createdAt) > ($1.lastEventAt ?? $1.createdAt) }
        for chat in chats where branchStates[chat.id] == nil {
            await refreshBranch(chat.id)
        }
    }
}
