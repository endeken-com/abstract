import AppKit
import AbstractCore

/// Acting on several chats at once (ABS-181, ABS-206): any chats, picked in
/// either layout, archived, unarchived, pinned or deleted together. Each goes
/// through the single action (here, or on the paired Mac it runs on), so
/// worktrees, folders, session logs and agent config go just as they do one
/// at a time.
extension AppModel {
    /// A ⌘ or ⇧ click on a chat in the rail (`shownChatOrder`). A ⌘ or ⇧
    /// click with nothing picked starts from the open chat, as Finder starts
    /// from the file already selected.
    func pickChat(_ id: String, _ click: ChatSelection.Click) {
        let order = shownChatOrder
        var base = chatSelection
        if base.isEmpty, click != .single, let open = selectedSessionId, open != id { base = base.clicking(open, .single, in: order) }
        chatSelection = base.clicking(id, click, in: order)
    }

    /// Every chat the rail shows (⌘A).
    func pickAllShown() { chatSelection = .all(shownChatOrder) }

    /// The picked chats, or the open one when none are.
    var pickedOrOpen: [String] {
        if !chatSelection.isEmpty { return chatSelection.ids }
        return selectedSessionId.map { [$0] } ?? []
    }

    /// What the actions need to know of each of `ids`, here or on a paired Mac.
    func bulkItems(_ ids: [String]) -> [BulkChatAction.Item] {
        ids.compactMap { id in
            let remote = RemoteService.split(id) != nil
            guard let s = remote ? self.remote.mirror(id) : session(id) else { return nil }
            let working = [.running, .provisioning].contains(s.status) || runningBackgroundTasks(id) > 0
            return BulkChatAction.Item(s, remote: remote, working: working)
        }
    }

    /// Does `action` to the picked chats it fits, asking first where it should.
    func perform(_ action: BulkChatAction, on ids: [String]) {
        let items = bulkItems(ids)
        let targets = action.targets(items)
        guard !targets.isEmpty else { return }
        switch action {
        case .archive:
            // One chat: the question Archive Chat always asks.
            if targets.count == 1, RemoteService.split(targets[0]) == nil { requestArchive = targets[0]; return }
            let working = items.filter { $0.working && targets.contains($0.id) }.map(\.id)
            let text = BulkChatAction.archiveConfirmation(count: targets.count, working: working.count)
            let alert = NSAlert()
            alert.messageText = text.title
            alert.informativeText = text.message
            alert.addButton(withTitle: "Archive")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            archiveChats(targets, stopping: working)
        case .unarchive:
            for id in targets { setArchived(id, false) }
            chatSelection = ChatSelection()
        case .pin, .unpin:
            for id in targets { setPinned(id, action == .pin) }
        case .delete:
            Task { await confirmDeleteChats(targets) }
        }
    }

    /// Archives `ids`, stopping the agents of `stopping` first.
    func archiveChats(_ ids: [String], stopping: [String] = []) {
        for id in stopping { stopAgent(id) }
        for id in ids { setArchived(id, true) }
        chatSelection = ChatSelection()
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
        chatSelection = ChatSelection()
        flash(report.summary, isError: !report.isClean)
    }

    /// Deletes `ids` one after another; one that fails leaves the rest going.
    /// Local chats leave at once and their folders clear in the background.
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
    /// which go with their worktrees. Reviewers and standalone chats have
    /// none to lose, nor do worktrees without submodules.
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
