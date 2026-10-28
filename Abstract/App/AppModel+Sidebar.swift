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

    /// Keep every unarchived chat's standing current without opening it.
    func watchBranches() async {
        await readEveryBranch(refreshAll: true)
        guard !isDemo else { return }
        var lastFullRead = ContinuousClock.now
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(120))
            if Task.isCancelled { break }
            let full = ContinuousClock.now - lastFullRead >= .seconds(600)
            await readEveryBranch(refreshAll: true, limit: full ? nil : 40)
            if full { lastFullRead = .now }
        }
    }

    /// Recent chats first, with bounded git work so large sidebars stay responsive.
    func readEveryBranch(refreshAll: Bool = false, limit: Int? = nil) async {
        let chats = sessions.filter { $0.archivedAt == nil && $0.worktreePath != nil && !$0.id.hasPrefix(RemoteService.mirrorPrefix)
            && (refreshAll || branchStates[$0.id] == nil) }
            .sorted { ($0.lastEventAt ?? $0.createdAt) > ($1.lastEventAt ?? $1.createdAt) }
        let ids = chats.prefix(limit ?? chats.count).map(\.id)
        var remaining = ids.makeIterator()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<min(4, ids.count) {
                if let id = remaining.next() { group.addTask { await self.refreshBranch(id) } }
            }
            while await group.next() != nil {
                if Task.isCancelled { group.cancelAll(); break }
                if let id = remaining.next() { group.addTask { await self.refreshBranch(id) } }
            }
        }
    }
}
