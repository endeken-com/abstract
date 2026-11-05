import AppKit
import SwiftUI
import AbstractCore

/// Demo mode's Project Settings check.
/// `ABSTRACT_DEMO_PROJECT_SETTINGS=<delay>` waits, gives payments-api two
/// remembered permission rules, opens its settings and walks the page in
/// Graphite, Paper and Ink: the top, the middle, the end, a section reached
/// from the rail, and a window too narrow for the rail. It logs which
/// section the rail lights at each step.
/// `ABSTRACT_DEMO_PROJECT_SETTINGS_SHOT=<png>` saves the window at each
/// step, the step's name before the extension.
enum ProjectSettingsProbe {
    static func runIfRequested(_ model: AppModel) {
        guard let spec = ProcessInfo.processInfo.environment["ABSTRACT_DEMO_PROJECT_SETTINGS"], let delay = Double(spec) else { return }
        Task {
            try? await Task.sleep(for: .seconds(delay))
            await run(model)
        }
    }

    private static func run(_ model: AppModel) async {
        guard let project = model.projects.first(where: { $0.name == "payments-api" }) ?? model.projects.first else {
            log("settings probe: no project"); return
        }
        if model.permissionRules(for: project.id).isEmpty {
            model.savePermissionRule(PermissionRule(projectId: project.id, kind: .command, pattern: "npm test*", decision: .allow))
            model.savePermissionRule(PermissionRule(projectId: project.id, kind: .path, pattern: "**/.env*", decision: .deny,
                                                    expiresAt: Date().addingTimeInterval(7 * 86_400)))
        }
        // The pointer resting on the page would light a row.
        if let window = mainWindow, let screen = window.screen {
            CGWarpMouseCursorPosition(CGPoint(x: window.frame.maxX - 20, y: screen.frame.maxY - window.frame.maxY + 20))
        }
        let theme = UserDefaults.standard.string(forKey: "theme")
        model.destination = .projectSettings(project.id)
        for name in ["graphite", "paper", "ink"] {
            UserDefaults.standard.set(ThemeChoice(rawValue: name).rawValue, forKey: "theme")
            scroll(to: 0)
            await shot("-\(name)-top", settle: 1.5)
            scroll(to: 0.5)
            await shot("-\(name)-middle")
            scroll(to: 1)
            await shot("-\(name)-end")
        }
        UserDefaults.standard.set("graphite", forKey: "theme")
        scroll(to: 0)
        try? await Task.sleep(for: .seconds(0.5))
        if let window = mainWindow {
            let frame = window.frame
            window.setFrame(NSRect(x: frame.minX, y: frame.minY, width: 860, height: frame.height), display: true)
            await shot("-graphite-narrow", settle: 1.2)
            window.setFrame(frame, display: true)
        }
        if ProcessInfo.processInfo.environment["ABSTRACT_DEMO_PROJECT_SETTINGS_STATES"] != nil {
            await states(model, projectId: project.id)
        }
        if let theme { UserDefaults.standard.set(theme, forKey: "theme") } else { UserDefaults.standard.removeObject(forKey: "theme") }
        log("settings probe: done")
    }

    /// `ABSTRACT_DEMO_PROJECT_SETTINGS_STATES=1` then fills the page:
    /// "Saved" after a rename, a long name, a prefix git refuses, a skill
    /// library, many profiles, a linked tracker, and (with
    /// `ABSTRACT_DEMO_PROJECT_SETTINGS_PLUGIN=<folder>`) a plugin's tools.
    private static func states(_ model: AppModel, projectId: String) async {
        scroll(to: 0)
        let name = model.project(projectId)?.name ?? ""
        model.renameProject(projectId, to: name + "-renamed")
        await shot("-state-saved", settle: 0.4)
        await shot("-state-saved-gone", settle: 2.6)
        // A remembered rule is a save too.
        model.savePermissionRule(PermissionRule(projectId: projectId, kind: .tool, pattern: "WebFetch", decision: .allow))
        await shot("-state-saved-rule", settle: 0.4)
        model.renameProject(projectId, to: "payments-api-with-a-name-long-enough-to-run-out-of-room-in-the-header")
        // Changed under the open page: its field must take the new prefix, not save its old draft over it.
        model.updateProject(projectId) { $0.branchPrefix = "wes guirra/" }
        try? await Task.sleep(for: .seconds(1.5))
        log("settings probe: prefix after 1.5 s=\(model.project(projectId)?.branchPrefix ?? "nil")")

        // A skill library of 14, three on here.
        let library = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("probe-skills-\(UUID().uuidString.prefix(6))")
        for i in 1...14 {
            let folder = library.appendingPathComponent("skill-\(i)")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? "---\nname: skill-\(i)\ndescription: Probe skill \(i).\n---\nBody.\n"
                .write(to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        }
        model.addSkillFolder(library.path)
        for skill in model.librarySkills.prefix(3) { model.setSkill(skill.id, assigned: true, projectId: projectId) }

        // Thirty profiles, all but two offered.
        while model.profiles.count < 30 {
            var profile = model.addProfile()
            profile.name = "Profile \(model.profiles.count)"
            model.saveProfile(profile)
        }
        let all = model.profiles.map(\.id)
        model.updateProject(projectId) { $0.profileIds = Array(all.dropLast(2)) }

        // A linked Linear project.
        let linear = PromptAttachment.linearTrackerId
        if model.plugins.plugin(linear) == nil,
           let folder = model.plugins.bundledFolders.first(where: { $0.lastPathComponent == "linear.abstractplugin" }) {
            _ = try? model.plugins.install(from: folder, sourceKind: .bundled, enable: true)
        }
        TrackerProjectLink.write(TrackerProjectLink(team: .init(id: "team:ENG", name: "Engineering", key: "ENG"),
                                                    project: .init(id: "project:p-core", name: "Core")),
                                 to: model.plugins.manager.storage(for: linear), projectId: projectId)
        model.noteTrackerLinksChanged()

        if let path = ProcessInfo.processInfo.environment["ABSTRACT_DEMO_PROJECT_SETTINGS_PLUGIN"] {
            do { _ = try model.plugins.install(from: URL(fileURLWithPath: path), sourceKind: .bundled, enable: true) }
            catch { log("settings probe: plugin install failed: \(error)") }
        }
        if let project = model.project(projectId) {
            log("settings probe: states skills=\(model.librarySkills.count) profiles=\(model.profiles.count) "
                + "trackers=\(model.projectIssueTrackers(projectId).linked.count) sections=\(model.plugins.contributions(.projectSettings).count) "
                + "pluginTools=\(model.pluginTools(in: project).count) prefix=\(project.branchPrefix ?? "nil")")
        }
        // A popover list's height: its rows', up to 360 pt, then it scrolls.
        for count in [3, 30] {
            let host = NSHostingView(rootView: PopoverList {
                ForEach(0..<count, id: \.self) { i in Toggle("Profile \(i)", isOn: .constant(true)) }
            })
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .seconds(0.3))
            host.layoutSubtreeIfNeeded()
            log("settings probe: popover list of \(count) is \(Int(host.fittingSize.width))x\(Int(host.fittingSize.height))")
        }
        for (i, fraction) in [0, 0.3, 0.55, 0.8, 1].enumerated() {
            scroll(to: CGFloat(fraction))
            await shot("-state-\(i)", settle: i == 0 ? 1.5 : 0.8)
        }
    }

    private static var mainWindow: NSWindow? { NSApp.windows.first { $0.canBecomeMain && $0.isVisible } }

    /// Scrolls the page's scroll view to a fraction of its height.
    private static func scroll(to fraction: CGFloat) {
        guard let scroll = scrollViews(mainWindow?.contentView)
            .max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }),
              let document = scroll.documentView else { return }
        // The page starts under the title bar: its top is above the clip view's zero.
        let inset = scroll.contentView.contentInsets.top
        let target = max(0, document.frame.height - scroll.contentView.bounds.height + inset) * fraction - inset
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? target : document.frame.height - scroll.contentView.bounds.height - target))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private static func scrollViews(_ view: NSView?) -> [NSScrollView] {
        guard let view else { return [] }
        return ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
    }

    private static func shot(_ suffix: String, settle: Double = 0.8) async {
        try? await Task.sleep(for: .seconds(settle))
        guard let path = ProcessInfo.processInfo.environment["ABSTRACT_DEMO_PROJECT_SETTINGS_SHOT"],
              let image = WindowCapture.image() ?? WindowCapture.image(method: .cacheDisplay) else {
            log("settings probe: no shot \(suffix)")
            return
        }
        let url = URL(fileURLWithPath: path)
        let out = url.deletingPathExtension().path + suffix + "." + url.pathExtension
        try? image.write(to: URL(fileURLWithPath: out))
        log("settings probe: shot \(out)")
    }
}
