import AppKit
import AbstractCore

/// Demo mode's bulk delete check (ABS-181). `ABSTRACT_DEMO_BULK_DELETE=<delay>`
/// waits, archives every chat, picks them the way clicks do (a click, a
/// ⇧-click, a ⌘-click), then deletes the picks plus one chat that doesn't
/// exist, and logs the report and whether each chat's worktree, session log
/// and row are gone. `ABSTRACT_DEMO_BULK_DELETE_SHOT=<png>` saves the window
/// with the picks showing.
enum BulkDeleteProbe {
    static func runIfRequested(_ model: AppModel) {
        guard let spec = ProcessInfo.processInfo.environment["ABSTRACT_DEMO_BULK_DELETE"], let delay = Double(spec) else { return }
        Task {
            try? await Task.sleep(for: .seconds(delay))
            await run(model)
        }
    }

    private static func run(_ model: AppModel) async {
        let chats = model.sessions.filter { $0.parentSessionId == nil }
        for chat in chats { model.setArchived(chat.id, true) }
        model.showArchived = true
        let order = SidebarChats.sections(model.sidebarChats()).first { $0.group == .archived }?.chats.map(\.id) ?? []
        log("bulk delete probe: \(order.count) archived")
        guard order.count >= 3 else { log("bulk delete probe: needs 3 archived chats"); return }

        // A click, a ⇧-click to the third, a ⌘-click dropping the second.
        model.pickArchived(order[0], .single, in: order)
        model.pickArchived(order[2], .extend, in: order)
        log("bulk delete probe: after ⇧-click \(model.archivedSelection.count) picked")
        model.pickArchived(order[1], .toggle, in: order)
        let picked = model.archivedSelection.ids
        log("bulk delete probe: after ⌘-click \(picked.count) picked, \(picked == [order[0], order[2]] ? "first and third" : "\(picked)")")
        try? await Task.sleep(for: .seconds(1))
        if let path = ProcessInfo.processInfo.environment["ABSTRACT_DEMO_BULK_DELETE_SHOT"], let image = WindowCapture.image() {
            try? image.write(to: URL(fileURLWithPath: path))
            log("bulk delete probe: shot \(path)")
        }

        let text = BulkChatDelete.confirmation(count: picked.count)
        log("bulk delete probe: asks “\(text.title)” \(text.message)")
        let worktrees = picked.compactMap { model.session($0)?.worktreePath }
        let report = await model.deleteChats(picked + ["missing-chat"])
        log("bulk delete probe: \(report.summary)")
        let logs = model.engine.logsURL
        for id in picked {
            let row = (try? model.store.session(id)) == nil ? "row gone" : "ROW LEFT"
            let file = FileManager.default.fileExists(atPath: logs.appendingPathComponent("\(id).jsonl").path) ? "LOG LEFT" : "log gone"
            log("bulk delete probe: \(id.prefix(8)) \(row), \(file), \(model.session(id) == nil ? "out of the model" : "STILL IN THE MODEL")")
        }
        for path in worktrees {
            log("bulk delete probe: worktree \((path as NSString).lastPathComponent) \(FileManager.default.fileExists(atPath: path) ? "LEFT" : "removed")")
        }
        log("bulk delete probe: unpicked \(order[1].prefix(8)) \(model.session(order[1]) != nil ? "kept" : "DELETED")")
        log("bulk delete probe: done")
    }
}
