import Foundation
import AbstractCore

/// Project Settings › Clean up (ABS-206): a project's chats not active for
/// a while, what keeps some of them, and deleting the rest through the
/// fast delete.
extension AppModel {
    /// The project's chats last active before `age` ago, archived ones too,
    /// each with why it's kept, if it is. Only those old chats' branches are
    /// read for work never pushed.
    func cleanupCandidates(_ projectId: String, olderThan age: ChatCleanup.Age, now: Date = Date()) async -> [ChatCleanup.Candidate] {
        let chats = sessions.filter { $0.projectId == projectId && RemoteService.split($0.id) == nil }
        let old = ChatCleanup.candidates(chats.map { facts($0) }, olderThan: age, now: now)
        var read: [ChatCleanup.Facts] = []
        for candidate in old {
            var f = candidate.facts
            // Work never pushed matters only when nothing else keeps it.
            if candidate.reason == nil, f.session.reviewsSessionId == nil, let path = f.session.worktreePath,
               FileManager.default.fileExists(atPath: path) {
                let work = await ChatCleanup.unsavedWork(executor, worktree: path, preferredBase: project(projectId)?.defaultBaseRef)
                f.unpushedCommits = work.commits
                f.uncommittedFiles = work.uncommitted
            }
            read.append(f)
        }
        return ChatCleanup.candidates(read, olderThan: age, now: now)
    }

    private func facts(_ s: Session) -> ChatCleanup.Facts {
        let pr = pullRequests[s.id]
        return ChatCleanup.Facts(session: s, backgroundTasks: runningBackgroundTasks(s.id),
                                 pullRequest: pr?.state, pullRequestNumber: pr?.number)
    }

    /// The bytes a chat's worktree or folder holds, when deleting it frees
    /// them: not a reviewer's (it reads another chat's), nor one shared.
    func cleanupSize(_ s: Session) async -> Int64? {
        guard s.reviewsSessionId == nil, let path = s.worktreePath else { return nil }
        let key = Self.canonical(path)
        guard !sessions.contains(where: { $0.id != s.id && $0.reviewsSessionId == nil && $0.worktreePath.map(Self.canonical) == key })
        else { return nil }
        return await ChatTrash.size(of: path)
    }

    /// Deletes `ids` through the fast delete, waits for their folders, and
    /// says how much it freed (from `sizes`, measured for the review).
    @discardableResult
    func cleanUp(_ ids: [String], sizes: [String: Int64]) async -> String {
        var deleted: [String] = []
        for id in ids {
            if case .failed = await delete(id, removeWorktree: true, quiet: true) { continue }
            deleted.append(id)
        }
        await waitUntilCleared(deleted)
        let summary = ChatCleanup.summary(deleted: deleted.count, freed: deleted.compactMap { sizes[$0] }.reduce(0, +))
        flash(summary)
        return summary
    }
}
