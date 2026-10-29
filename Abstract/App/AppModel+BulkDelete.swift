import AppKit
import AbstractCore

/// Deleting several archived chats at once (ABS-181). Each goes through the
/// single delete (here, or on the paired Mac it runs on), so worktrees,
/// folders, session logs and agent config go just as they do one at a time.
extension AppModel {
    /// A click on an archived chat in `order`, the Archived group as shown.
    /// A ⌘ or ⇧ click with nothing picked starts from the open chat, as
    /// Finder starts from the file already selected.
    func pickArchived(_ id: String, _ click: ChatSelection.Click, in order: [String]) {
        var base = archivedSelection
        if base.isEmpty, click != .single, let open = selectedSessionId { base = base.clicking(open, .single, in: order) }
        archivedSelection = base.clicking(id, click, in: order)
    }

    /// Asks once for all of `ids`, then deletes them and says how it went.
    func confirmDeleteChats(_ ids: [String]) async {
        guard !ids.isEmpty else { return }
        let losing = await chatsLosingSubmoduleWork(ids)
        let text = BulkChatDelete.confirmation(count: ids.count, losingSubmoduleWork: losing)
        let alert = NSAlert()
        alert.messageText = text.title
        alert.informativeText = text.message
        alert.addButton(withTitle: losing == 0 ? "Delete" : "Delete Anyway")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let report = await deleteChats(ids)
        archivedSelection = ChatSelection()
        flash(report.summary, isError: !report.isClean)
    }

    /// Deletes `ids` one after another; one that fails leaves the rest going.
    func deleteChats(_ ids: [String]) async -> BulkChatDelete.Report {
        await BulkChatDelete.run(ids) { id in
            if let (_, host) = RemoteService.split(id) {
                do {
                    try await remote.perform(id, .deleteChat(sessionId: host, removeWorktree: true))
                    return .deleted
                } catch { return .failed(error.localizedDescription) }
            }
            return await delete(id, removeWorktree: true, quiet: true)
        }
    }

    /// How many of this Mac's `ids` hold submodule commits no remote has,
    /// which go with their worktrees. Reviewers and standalone chats have none to lose.
    private func chatsLosingSubmoduleWork(_ ids: [String]) async -> Int {
        let worktrees = ids.compactMap { id -> (String, String)? in
            guard let s = session(id), RemoteService.split(id) == nil, s.projectId != nil, s.reviewsSessionId == nil,
                  let path = s.worktreePath else { return nil }
            return (id, path)
        }
        var losing = 0
        for (id, path) in worktrees {
            if await unpushedSubmoduleWarning(executor(for: id), worktree: path) != nil { losing += 1 }
        }
        return losing
    }
}
