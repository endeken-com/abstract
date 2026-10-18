import Foundation
import AbstractCore

/// What the sidebar knows of every chat, here and on paired Macs, for
/// `SidebarChats` to group.
extension AppModel {
    /// Every chat the sidebar can show: this Mac's, then those on paired Macs connected now.
    func sidebarChats() -> [SidebarChats.Chat] {
        let here = remote.identity.name
        let local = sessions.filter { !$0.id.hasPrefix(RemoteService.mirrorPrefix) }.map { s in
            SidebarChats.Chat(session: s, pullRequest: pullRequests[s.id].map(SidebarChats.PullRequestFacts.init),
                              // A chat with no folder has nothing to review.
                              hasChanges: s.worktreePath == nil ? false : branchStates[s.id]?.hasUnmergedWork,
                              backgroundTasks: runningBackgroundTasks(s.id), projectName: project(s.projectId)?.name,
                              mac: here,
                              icon: SidebarChats.icon(project: project(s.projectId), isRemote: false, remoteImage: nil))
        }
        let paired = remote.paired.compactMap { remote.links[$0.id] }.flatMap { link -> [SidebarChats.Chat] in
            guard let snapshot = link.snapshot else { return [] }
            let projects = Dictionary(snapshot.projects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let busy = Set(snapshot.backgroundTasks ?? [])
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
                                                                 remoteImage: hosted.projectId.flatMap { snapshot.projectIcons?[$0] }))
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
