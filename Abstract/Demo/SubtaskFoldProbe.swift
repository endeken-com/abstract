import AppKit
import AbstractCore

/// Demo mode's check of folding a chat's sub-tasks (ABS-213).
/// `ABSTRACT_DEMO_SUBTASKS=<delay>` waits, adds a chat with three sub-tasks
/// (one with a sub-task of its own) to the demo's abstract project, then:
/// - says whether it starts collapsed (it stays so from the run before);
/// - expands it, collapses it the way its chevron and menu do, and has a
///   hidden sub-task ask for permission;
/// - searches for a hidden sub-task's name, and clears the search;
/// - opens a hidden sub-task the way the palette does;
/// - shows it collapsed by project too, and leaves it collapsed for the next run.
/// `ABSTRACT_DEMO_SUBTASKS_SHOT=<png>` saves the window at each step, the
/// step's name before the extension.
enum SubtaskFoldProbe {
    static let parentId = "demo-subtasks-parent"

    static func runIfRequested(_ model: AppModel) {
        guard let spec = ProcessInfo.processInfo.environment["ABSTRACT_DEMO_SUBTASKS"], let delay = Double(spec) else { return }
        Task {
            try? await Task.sleep(for: .seconds(delay))
            await run(model)
        }
    }

    private static func run(_ model: AppModel) async {
        guard let abstract = model.projects.first(where: { $0.name == "abstract" }) else { log("subtask probe: no project"); return }
        let startedCollapsed = model.collapsedChats.contains(parentId)
        let now = Date()
        func chat(_ id: String, _ name: String, parent: String?, minutesAgo: Double) -> Session {
            var s = Session(id: id, projectId: abstract.id, name: name, providerId: "claude", status: .finished,
                            createdAt: now.addingTimeInterval(-minutesAgo * 60 - 60), lastEventAt: now.addingTimeInterval(-minutesAgo * 60))
            s.parentSessionId = parent
            return s
        }
        let sessions = [
            chat(parentId, "Orchestrate the release checklist", parent: nil, minutesAgo: 1),
            chat("demo-subtasks-1", "Review the changelog draft", parent: parentId, minutesAgo: 2),
            chat("demo-subtasks-2", "Polish the What's new card", parent: parentId, minutesAgo: 3),
            chat("demo-subtasks-3", "Check the update feed", parent: parentId, minutesAgo: 4),
            chat("demo-subtasks-3a", "Verify the signed DMG", parent: "demo-subtasks-3", minutesAgo: 5),
        ]
        for s in sessions { try? model.store.save(s) }
        model.reload()
        let children = Set(sessions.dropFirst().map(\.id))

        // The demo shares the app's defaults: put back what it changes.
        let arrangement = UserDefaults.standard.string(forKey: "sidebar.arrangement")
        defer {
            if let arrangement { UserDefaults.standard.set(arrangement, forKey: "sidebar.arrangement") }
            else { UserDefaults.standard.removeObject(forKey: "sidebar.arrangement") }
        }
        UserDefaults.standard.set(SidebarChats.Arrangement.status.rawValue, forKey: "sidebar.arrangement")
        model.destination = .home
        try? await Task.sleep(for: .seconds(1.5))

        func shown() -> String {
            let order = model.shownChatOrder
            return "shows \(order.filter(children.contains).count) of \(children.count) sub-tasks, parent \(order.contains(parentId) ? "shown" : "missing")"
        }
        log("subtask probe: launched \(startedCollapsed ? "collapsed" : "expanded"); \(shown())")
        if startedCollapsed { await shot("-relaunched") }

        model.setSubtasksCollapsed(parentId, false)
        await shot("-expanded")
        log("subtask probe: expanded; \(shown())")

        model.setSubtasksCollapsed(parentId, true)
        await shot("-collapsed")
        log("subtask probe: collapsed; \(shown())")

        model.setStatus("demo-subtasks-2", .waitingInput)
        await shot("-collapsed-needs-you")
        let group = SidebarChats.sections(model.sidebarChats()).first { $0.chats.contains { $0.id == parentId } }?.group
        log("subtask probe: hidden sub-task asks; parent in \(group?.title ?? "nowhere"); \(shown())")

        NotificationCenter.default.post(name: SidebarView.demoSearch, object: "signed DMG")
        await shot("-search")
        log("subtask probe: searching \"signed DMG\"; \(shown()); remembered \(model.collapsedChats.contains(parentId) ? "collapsed" : "expanded")")
        NotificationCenter.default.post(name: SidebarView.demoSearch, object: "")
        await shot("-search-cleared")
        log("subtask probe: search cleared; \(shown())")

        // The palette, a notification and the parent's tool row all open a chat this way.
        model.open("demo-subtasks-3a")
        await shot("-opened")
        log("subtask probe: opened a hidden sub-task; selected \(model.selectedSessionId == "demo-subtasks-3a"), "
            + "parent \(model.collapsedChats.contains(parentId) ? "collapsed" : "expanded"); \(shown())")

        model.setStatus("demo-subtasks-2", .finished)
        model.destination = .home
        model.setSubtasksCollapsed(parentId, true)
        UserDefaults.standard.set(SidebarChats.Arrangement.project.rawValue, forKey: "sidebar.arrangement")
        await shot("-collapsed-by-project")
        log("subtask probe: by project, collapsed; \(shown())")
        log("subtask probe: done")
    }

    private static func shot(_ step: String) async {
        try? await Task.sleep(for: .seconds(0.8))
        guard let path = ProcessInfo.processInfo.environment["ABSTRACT_DEMO_SUBTASKS_SHOT"], let image = WindowCapture.image() else { return }
        let url = URL(fileURLWithPath: path)
        let named = url.deletingPathExtension().path + step + "." + (url.pathExtension.isEmpty ? "png" : url.pathExtension)
        try? image.write(to: URL(fileURLWithPath: named))
        log("subtask probe: shot \(named)")
    }
}
