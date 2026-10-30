import AppKit
import AbstractCore

/// Demo mode's project tracker links check (ABS-143).
/// `ABSTRACT_DEMO_TRACKERS=<delay>` waits, turns on the bundled Linear and
/// Jira plugins, then links the first chat's project to neither, Linear,
/// Jira and both, turns Jira off and on, and sends a Linear and a Jira
/// issue. It logs what the composer shows, searches and tells the agent at
/// each step. `ABSTRACT_DEMO_TRACKERS_SHOT=<png>` saves the window at each
/// step, the step's name before the extension.
enum IssueTrackerProbe {
    static func runIfRequested(_ model: AppModel) {
        guard let spec = ProcessInfo.processInfo.environment["ABSTRACT_DEMO_TRACKERS"], let delay = Double(spec) else { return }
        Task {
            try? await Task.sleep(for: .seconds(delay))
            await run(model)
        }
    }

    static let linear = PromptAttachment.linearTrackerId
    static let jira = "sh.abstract.jira"

    private static func run(_ model: AppModel) async {
        for name in ["linear.abstractplugin", "jira.abstractplugin"] {
            guard let folder = model.plugins.bundledFolders.first(where: { $0.lastPathComponent == name }) else { continue }
            _ = try? model.plugins.install(from: folder, sourceKind: .bundled, enable: true)
        }
        // The pointer resting on a sidebar row would cover the shots with its card.
        if let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }), let screen = window.screen {
            let point = NSPoint(x: window.frame.maxX - 200, y: window.frame.maxY - 300)
            CGWarpMouseCursorPosition(CGPoint(x: point.x, y: screen.frame.maxY - point.y))
        }
        if model.selectedSessionId == nil, let first = model.sessions.first { model.open(first.id) }
        guard let sessionId = model.selectedSessionId, let projectId = model.session(sessionId)?.projectId else {
            log("tracker probe: no chat in a project"); return
        }
        model.composerDrafts.draft(sessionId).attachments = [
            PromptAttachment(kind: .trackerIssue, title: "Status dot for archived chats", reference: "ENG-318",
                             url: "https://linear.app/acme/issue/ENG-318", tracker: linear, trackerName: "Linear"),
            PromptAttachment(kind: .trackerIssue, title: "Checkout retries twice", reference: "PROJ-42",
                             url: "https://acme.atlassian.net/browse/PROJ-42", tracker: jira, trackerName: "Jira"),
        ]
        log("tracker probe: icons linear template=\(TrackerIcons.image(linear)?.isTemplate.description ?? "none") jira template=\(TrackerIcons.image(jira)?.isTemplate.description ?? "none")")
        let core = TrackerProjectLink(team: .init(id: "team:ENG", name: "Engineering", key: "ENG"),
                                      project: .init(id: "project:p-core", name: "Core"))
        let proj = TrackerProjectLink(project: .init(id: "project:PROJ", name: "Sample project", key: "PROJ"))
        let linearStorage = model.plugins.manager.storage(for: linear)
        let jiraStorage = model.plugins.manager.storage(for: jira)

        func link(_ linearLink: TrackerProjectLink?, _ jiraLink: TrackerProjectLink?) {
            TrackerProjectLink.write(linearLink, to: linearStorage, projectId: projectId)
            TrackerProjectLink.write(jiraLink, to: jiraStorage, projectId: projectId)
            model.noteTrackerLinksChanged()
        }

        for (step, linearLink, jiraLink) in [("neither", nil, nil), ("linear", core, nil), ("jira", nil, proj), ("both", core, proj)]
            as [(String, TrackerProjectLink?, TrackerProjectLink?)] {
            link(linearLink, jiraLink)
            await report(model, projectId: projectId, step: step)
        }

        model.setPluginEnabled(jira, false)
        await report(model, projectId: projectId, step: "jira-off")
        log("tracker probe: jira-off saved link kept=\(TrackerProjectLink.read(jiraStorage, projectId: projectId) == proj) sections=\(model.plugins.contributions(.projectSettings).map(\.pluginId))")
        model.setPluginEnabled(jira, true)
        await report(model, projectId: projectId, step: "jira-on")
        log("tracker probe: jira-on sections=\(model.plugins.contributions(.projectSettings).map(\.pluginId))")

        // Both chips go with a message, and keep their marks in it.
        let attachments = model.composerDrafts.draft(sessionId).attachments
        model.composerDrafts.draft(sessionId).attachments = []
        try? model.sendFollowUp(sessionId, text: "Both issues are about the same retry path.", attachments: attachments)
        try? await Task.sleep(for: .seconds(2))
        shot("-sent")

        model.destination = .projectSettings(projectId)
        try? await Task.sleep(for: .seconds(1.5))
        shot("-project-settings")
        // Down to Issue tracker, under Tools (MCP).
        if let scroll = scrollViews(NSApp.windows.first { $0.canBecomeMain && $0.isVisible }?.contentView)
            .max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }),
           let document = scroll.documentView {
            let target = (document.frame.height - scroll.contentView.bounds.height) * 0.62
            scroll.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? target : document.frame.height - scroll.contentView.bounds.height - target))
            scroll.reflectScrolledClipView(scroll.contentView)
            try? await Task.sleep(for: .seconds(0.8))
            shot("-project-settings-section")
        }
        model.open(sessionId)
    }

    private static func report(_ model: AppModel, projectId: String, step: String) async {
        let trackers = model.projectIssueTrackers(projectId)
        log("tracker probe: \(step) shown=\(trackers.shown().map(\.title)) linked=\(trackers.linked.map { "\($0.tracker.title):\($0.link.title)" }) scopes=\(trackers.scopes().sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }) help=“\(AttachmentButtons.trackerHelp(trackers))” env=\(trackers.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })")
        try? await Task.sleep(for: .seconds(1))
        shot("-\(step)")
    }

    private static func scrollViews(_ view: NSView?) -> [NSScrollView] {
        guard let view else { return [] }
        return ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
    }

    private static func shot(_ suffix: String) {
        // With the display asleep only the app's own drawing can be read.
        guard let path = ProcessInfo.processInfo.environment["ABSTRACT_DEMO_TRACKERS_SHOT"],
              let image = WindowCapture.image() ?? WindowCapture.image(method: .cacheDisplay) else {
            log("tracker probe: no shot \(suffix), windows " + NSApp.windows.map { "\($0.className) visible=\($0.isVisible) main=\($0.canBecomeMain)" }.joined(separator: ", "))
            return
        }
        let url = URL(fileURLWithPath: path)
        let out = url.deletingPathExtension().path + suffix + "." + url.pathExtension
        try? image.write(to: URL(fileURLWithPath: out))
        log("tracker probe: shot \(out)")
    }
}
