import AppKit
import Darwin
import SwiftUI
import AbstractCore

/// Demo mode: `Abstract.app/Contents/MacOS/Abstract --demo [--snapshot <dir>]`.
///
/// Seeds throwaway git repositories and starts real chats against a scripted
/// stand-in agent. With `--snapshot`, it walks every main screen in both
/// themes, writes PNGs of the window, and quits. Nothing touches the real
/// database or the developer's repositories.
@MainActor
final class DemoBootstrap {
    static let current: DemoBootstrap? = {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--demo") else { return nil }
        // Also from the environment: a path on the command line reads to
        // AppKit as a document to open, and then no window opens at launch.
        let snapshot = args.firstIndex(of: "--snapshot").flatMap { i in i + 1 < args.count ? args[i + 1] : nil }
            ?? ProcessInfo.processInfo.environment["ABSTRACT_DEMO_SNAPSHOT"]
        setvbuf(stdout, nil, _IONBF, 0)
        return DemoBootstrap(snapshotDir: snapshot)
    }()

    let root: URL
    let snapshotDir: String?

    init(snapshotDir: String?) {
        self.snapshotDir = snapshotDir
        root = FileManager.default.temporaryDirectory.appendingPathComponent("abstract-demo-\(Int(Date().timeIntervalSince1970))-\(getpid())")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("ABSTRACT_DATA_DIR", root.appendingPathComponent("data").path, 1)
    }

    func makeModel() -> AppModel {
        let dataDir = root.appendingPathComponent("data")
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        let store = try! Store(path: dataDir.appendingPathComponent("abstract.sqlite").path)
        try? store.setSetting("worktreeTemplate", root.path + "/worktrees/{repo}-{hash}/{slug}")
        let engine = SessionEngine(executor: LocalExecutor.shared, logDirectory: dataDir.appendingPathComponent("sessions"))
        return AppModel(store: store, engine: engine, executor: LocalExecutor.shared, isDemo: true)
    }

    func run(_ model: AppModel) async {
        // Launched from a script, the app can start in the background with no
        // window; ask to come forward until it has one.
        Task { @MainActor in
            for _ in 0..<60 where !NSApp.windows.contains(where: { $0.canBecomeMain && $0.isVisible }) {
                NSApp.activate()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        log("demo: seeding repositories in \(root.path)")
        let abstract = await makeRepo("abstract", model)
        let payments = await makeRepo("payments-api", model)
        let marketing = await makeRepo("marketing-site", model)
        model.reload()
        log("demo: \(model.projects.count) projects")

        await chat(model, abstract, "Derive chat status from process liveness", .autoEdits)
        if ProcessInfo.processInfo.environment["ABSTRACT_DEMO_REPLAY"] != nil, let first = model.sessions.first {
            model.destination = .session(first.id)
        }
        ScrollProbe.runIfRequested()
        SelectionProbe.runIfRequested()
        await chat(model, marketing, "Tighten the hero copy and fix layout shift on mobile", .autoEdits, provider: "codex")
        await chat(model, payments, "Retry idempotent webhook deliveries with exponential backoff", .ask)
        log("demo: \(model.sessions.count) chats started")
        await waitUntil(model) { m in m.sessions.filter { [.idle, .waitingInput, .finished].contains($0.status) }.count >= 3 }
        log("demo: chat states " + model.sessions.map { "\($0.name.prefix(20))=\($0.status.rawValue)" }.joined(separator: ", "))
        // A long recorded chat as a chat's history, for scrolling tests.
        if let path = ProcessInfo.processInfo.environment["ABSTRACT_DEMO_HISTORY"] { Task { await self.loadHistory(path, model) } }
        RemoteProbe.runIfRequested(model)
        FindProbe.runIfRequested(model)
        FileSearchProbe.runIfRequested(model)
        ReviewFindProbe.runIfRequested(model)
        IssueTrackerProbe.runIfRequested(model)

        let running = abstract.map { p in Task { await self.chat(model, p, "Add a command palette with fuzzy search", .autoEdits) } }
        _ = running

        let here = TimeZone.current.identifier
        let bump = """
            ## Bump dependencies

            1. Update every package to its latest compatible version.
            2. Run the full test suite with `swift test`.
            3. If anything broke, fix what's obvious and list the rest.

            Summarise the changes in a short table: package, old version, new version.
            """
        var nightly = Automation(name: "Nightly dependency bump", prompt: bump, providerId: "claude", projectId: abstract?.id, triggers: [
            AutomationTrigger(rrule: "FREQ=DAILY;BYHOUR=9;BYMINUTE=0;BYSECOND=0", timezone: here),
            AutomationTrigger(rrule: "FREQ=WEEKLY;BYDAY=FR;BYHOUR=17;BYMINUTE=30;BYSECOND=0", timezone: "Europe/Lisbon"),
        ])
        nightly.nextRunAt = nightly.nextOccurrence(after: Date())
        try? model.store.save(nightly)
        var triage = Automation(name: "Triage new issues", prompt: "Label and prioritise issues opened since yesterday.",
                                providerId: "claude", projectId: payments?.id,
                                rrule: "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;BYHOUR=8;BYMINUTE=30", timezone: here)
        triage.nextRunAt = triage.nextOccurrence(after: Date())
        try? model.store.save(triage)
        // A little history for the Runs tab; no new chats.
        let done = model.sessions.first { $0.projectId == abstract?.id && $0.status == .idle }
        try? model.store.save(AutomationRun.skipped(automationId: nightly.id, reason: .projectUnchanged,
                                                    at: Date().addingTimeInterval(-86_400 * 3)))
        // Triage's last run is waiting on a person, so the list shows it.
        if let waiting = model.sessions.first(where: { $0.status == .waitingInput }) {
            try? model.store.save(AutomationRun(automationId: triage.id, firedAt: Date().addingTimeInterval(-7_200), trigger: .schedule,
                                                status: .created, sessionId: waiting.id))
        }
        try? model.store.save(AutomationRun(automationId: nightly.id, firedAt: Date().addingTimeInterval(-86_400 * 2), trigger: .schedule,
                                            status: .failed, error: "git worktree add: 'auto-nightly-dependency-bump' is already checked out"))
        try? model.store.save(AutomationRun(automationId: nightly.id, firedAt: Date().addingTimeInterval(-86_400), trigger: .schedule,
                                            status: .created, sessionId: done?.id))
        try? model.store.save(AutomationRun(automationId: nightly.id, firedAt: Date().addingTimeInterval(-3_600), trigger: .manual,
                                            status: .created, sessionId: done?.id))
        // Workflows: both ready-made ones, a chat waiting between steps of
        // one, and an automation that follows it when a pull request merges.
        model.reload()
        let design = model.addWorkflow(from: WorkflowTemplate.all[0])
        model.addWorkflow(from: WorkflowTemplate.all[1])
        if var chat = model.session(done?.id) {
            chat.workflow = WorkflowProgress(workflow: design.snapshot(profiles: model.profiles), step: 0, state: .waiting)
            try? model.store.save(chat)
        }
        var qa = Automation(name: "Check merged work", prompt: "Test what this chat's pull request changed, end to end.",
                            providerId: "claude", projectId: abstract?.id, triggers: [], workspaceMode: .newWorktree)
        qa.events = [.pullRequestMerged, .workflowFinished]
        qa.eventTarget = .triggeringChat
        qa.workflowId = model.workflows.last?.id
        try? model.store.save(qa)
        try? model.store.save(AutomationRun(automationId: qa.id, firedAt: Date().addingTimeInterval(-7_200), trigger: .event,
                                            status: .created, sessionId: done?.id, event: .pullRequestMerged, sourceSessionId: done?.id))
        model.reload()
        // Project settings for payments-api, set after its chats started so
        // none of them ran the setup script.
        if let payments {
            _ = try? await model.executor.run("git", ["remote", "add", "origin", "git@github.com:github/payments-api.git"],
                                              cwd: payments.rootPath)
            model.updateProject(payments.id) { p in
                p.namingInstructions = "Start branches with fix/ or feat/. Keep titles short, in sentence case."
                p.setupScript = "echo \"Setting up $(basename \"$PWD\")\"\nls"
                p.runScript = "echo \"payments-api running on :8080\""
                p.teardownScript = "docker compose down"
            }
            await checkCodeHost(model, payments)
        }

        guard let snapshotDir else { return }
        log("demo: capturing snapshots")
        await Snapshotter(model: model, directory: snapshotDir).captureAll()
        NSApp.terminate(nil)
    }

    /// Once the demo's chats have started (each opens as it does), a long
    /// recorded chat as one chat's history, opened, for scrolling tests.
    private func loadHistory(_ path: String, _ model: AppModel) async {
        try? await Task.sleep(for: .seconds(8))
        if let first = model.sessions.first(where: { $0.status != .running }), let text = try? String(contentsOfFile: path, encoding: .utf8) {
            let lines = text.split(separator: "\n").compactMap { try? JSONDecoder().decode(OutputLine.self, from: Data($0.utf8)) }
            let timeline = ChatStream.timeline(lines, currentProvider: "claude")
            model.feed(first.id).reset(timeline)
            model.open(first.id)
            log("demo: history of \(timeline.entries.count) events in “\(first.name)”")
        }
    }

    /// A 128 × 128 PNG, transparent around a rounded square.
    private static func logo() -> Data {
        let image = NSImage(size: NSSize(width: 128, height: 128), flipped: false) { rect in
            NSColor(srgbRed: 0.36, green: 0.42, blue: 0.95, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 12, dy: 12), xRadius: 24, yRadius: 24).fill()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 44, dy: 44)).fill()
            return true
        }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128, bitsPerSample: 8, samplesPerPixel: 4,
                                      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        guard let bitmap else { return Data() }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: 128, height: 128))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:]) ?? Data()
    }

    private func makeRepo(_ name: String, _ model: AppModel) async -> Project? {
        let dir = root.appendingPathComponent("repos").appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("src/sessions"), withIntermediateDirectories: true)
        let row = """
        import SwiftUI

        /// One chat in the sidebar.
        struct SessionRow: View {
            let session: Session

            // Rows read their status straight from the model.


            var body: some View {
            let status = session.status
            HStack(spacing: 8) {
                StatusDot(status: status)
                Text(session.name)
                    .lineLimit(1)
                Spacer()
            }
            }
        }

        """
        try? row.write(to: dir.appendingPathComponent("src/sessions/SessionRow.swift"), atomically: true, encoding: .utf8)
        try? "# \(name)\n\nDemo repository created by Abstract.\n".write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        // A few everyday files, so the file tree and editor show their icons and colours.
        let extras = [
            "Dockerfile": "FROM node:20-alpine AS build\nWORKDIR /app\nCOPY package*.json ./\nRUN npm ci\nCOPY . .\nEXPOSE 3000\nCMD [\"npm\", \"start\"]\n",
            "Makefile": "build: deps\n\tswift build -c release  # optimised\n\ndeps:\n\tswift package resolve\n",
            "package.json": "{\n  \"name\": \"\(name)\",\n  \"private\": true,\n  \"scripts\": { \"start\": \"node server.js\" }\n}\n",
            ".gitignore": ".build/\nnode_modules/\n*.log\n",
            "infra/main.tf": "resource \"aws_s3_bucket\" \"logs\" {\n  bucket = \"\(name)-logs\"\n}\n",
        ]
        for (path, text) in extras {
            let url = dir.appendingPathComponent(path)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
        // An image, for Files' preview and the links and thumbnails in the chat.
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try? Self.logo().write(to: dir.appendingPathComponent("assets/logo.png"))
        let exec = model.executor
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "demo@abstract.local"], ["config", "user.name", "Abstract Demo"],
                     ["add", "-A"], ["commit", "-qm", "Initial commit"]] {
            _ = try? await exec.run("git", args, cwd: dir.path)
        }
        let probe: AppModel.Probe
        do { probe = try await model.probe(directory: dir.path) } catch { log("demo: probe failed for \(name): \(error.localizedDescription)"); return nil }
        try? model.addProject(probe, name: name, baseRef: "main", providerId: "claude", policy: .autoEdits)
        return model.projects.first { $0.rootPath == probe.rootPath }
    }

    private func chat(_ model: AppModel, _ project: Project?, _ prompt: String, _ policy: PermissionPolicy, provider: String = "claude") async {
        guard let project else { return }
        do {
            // A replay stays on screen while the other chats start.
            let replaying = ProcessInfo.processInfo.environment["ABSTRACT_DEMO_REPLAY"] != nil
            try await model.startChat(projectId: project.id, providerId: provider, prompt: prompt, baseRef: "main", policy: policy,
                                      select: !replaying || model.sessions.isEmpty)
        } catch {
            log("demo: chat failed: \(error.localizedDescription)")
        }
    }

    func waitUntil(_ model: AppModel, timeout: TimeInterval = 30, _ condition: (AppModel) -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(model), Date() < deadline { try? await Task.sleep(for: .milliseconds(200)) }
    }

    /// payments-api's origin is on github.com: its code host is the bundled
    /// GitHub plugin, on by default (ABS-139), asked through its script and
    /// `gh` as a real project would be. marketing-site has no origin, so none.
    private func checkCodeHost(_ model: AppModel, _ payments: Project) async {
        for _ in 0..<40 where model.codeHostsStarting { try? await Task.sleep(for: .milliseconds(250)) }
        // Its origin was only just added.
        model.projectOrigins[payments.id] = nil
        guard let host = await model.codeHost(for: payments) else {
            log("demo: code host for payments-api: none (\(model.plugins.usable.map(\.id).sorted()))")
            return
        }
        let access = await host.access()
        log("demo: code host for payments-api: \(host.title) via \(host.pluginId), gh \(access.isReady ? "signed in" : "\(access)")")
        if let marketing = model.projects.first(where: { $0.name == "marketing-site" }) {
            log("demo: code host for marketing-site: \(await model.codeHost(for: marketing)?.title ?? "none")")
        }
    }
}

/// Walks the app through its screens and writes a PNG of each.
@MainActor
struct Snapshotter {
    let model: AppModel
    let directory: String

    func captureAll() async {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        NSApp.activate()
        // Bootstrap starts at launch, so the window may not exist yet.
        // Launched from a script while another app is in front, the window can
        // take a while; asking to activate again brings it sooner.
        let deadline = Date().addingTimeInterval(90)
        while !NSApp.windows.contains(where: { $0.canBecomeMain && $0.isVisible }), Date() < deadline {
            NSApp.activate()
            try? await Task.sleep(for: .milliseconds(500))
        }
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(600))
        let idle = model.sessions.first { $0.status == .idle }
        let needsYou = model.sessions.first { $0.status == .waitingInput }

        shootAppIcon()

        let themes: [ThemeChoice] = ProcessInfo.processInfo.arguments.contains("--quick") ? [.graphite] : [.graphite, .paper, .ink]
        // `--plugins-only`: just the bundled plugins, in each theme.
        let pluginsOnly = ProcessInfo.processInfo.arguments.contains("--plugins-only")
        for theme in themes {
            UserDefaults.standard.set(theme.rawValue, forKey: "theme")
            try? await Task.sleep(for: .milliseconds(500))
            let t = theme.rawValue
            if pluginsOnly {
                await shootPlugins(theme: t, beside: idle?.id)
                continue
            }

            model.destination = .home
            await shot("\(t)-01-home")

            if let working = model.sessions.first(where: { $0.status == .running }) ?? idle {
                model.open(working.id)
                await shot("\(t)-02-chat-working")
            }
            if let idle {
                model.open(idle.id)
                if model.comments(idle.id).isEmpty {
                    model.addComment(idle.id, on: LineRef(path: "src/sessions/SessionRow.swift", line: 11, side: .new),
                                     code: "let status = session.derivedStatus",
                                     text: "Keep the stored status for archived chats; they have no process to check.")
                }
                seedPullRequests(model, for: idle)
                await shot("\(t)-03-chat-done", settle: 1.2)
                if t != "ink" { await shootNarrowSidePanel(in: idle.id, theme: t) }
                // The sidebar groups chats by what they need; then by project, as it used to.
                UserDefaults.standard.set(SidebarChats.Arrangement.project.rawValue, forKey: "sidebar.arrangement")
                await shot("\(t)-37-sidebar-by-project", settle: 0.8)
                UserDefaults.standard.set(SidebarChats.Arrangement.status.rawValue, forKey: "sidebar.arrangement")
                // Every tool row opens at once: rows must grow into their new height.
                UserDefaults.standard.set(TranscriptMode.verbose.rawValue, forKey: "chat.transcript")
                await shot("\(t)-03b-chat-verbose", settle: 1.2)
                UserDefaults.standard.set(TranscriptMode.normal.rawValue, forKey: "chat.transcript")
                // Open and close a command: the rows below move with it, no gap, no overlap.
                if t == "graphite", let (row, call) = Self.firstCall(in: model.feed(idle.id), kind: .command) {
                    try? await Task.sleep(for: .milliseconds(600))
                    model.feed(idle.id).expansion.set("call:\(call)", true, row: row)
                    await shot("\(t)-03d-command-open", settle: 0.6)
                    model.feed(idle.id).expansion.set("call:\(call)", false, row: row)
                    await shot("\(t)-03e-command-closed", settle: 0.6)
                }
                // Hide and bring back the sidebar: this once looped AppKit's layout.
                for hidden in [true, false, true, false] {
                    withAnimation(.snappy(duration: 0.22)) { UserDefaults.standard.set(hidden, forKey: "sidebar.hidden") }
                    try? await Task.sleep(for: .milliseconds(350))
                }
                UserDefaults.standard.set(true, forKey: "sidebar.hidden")
                await shot("\(t)-12-sidebar-hidden", settle: 0.8)
                UserDefaults.standard.set(false, forKey: "sidebar.hidden")
                await shot("\(t)-13-sidebar-shown", settle: 0.8)
                model.openFile("src/sessions/SessionRow.swift", in: idle.id)
                model.openFile("Dockerfile", in: idle.id)
                model.showPane(.files, in: idle.id)
                await shot("\(t)-04-files", settle: 1.5)
                // An image previews, fitted and then at its actual size.
                model.openFile("assets/logo.png", in: idle.id, preview: true)
                await shot("\(t)-04c-image-fit", settle: 1.0)
                model.activeImageDocument?.zoomToActualSize()
                await shot("\(t)-04d-image-actual", settle: 0.6)
                model.showPane(.review, in: idle.id)
                await shot("\(t)-23-pull-request", settle: 1.2)
                model.showPane(.terminal, in: idle.id)
                await shot("\(t)-10-terminal", settle: 2.0)
                model.togglePanel(.side, in: idle.id)
                await shot("\(t)-11-terminal-below-chat", settle: 2.0)
                model.resetLayout(idle.id)
                if t == "graphite" { await shootAttachments(model, in: idle.id) }
                if t == "graphite" { await shootRevund(model, in: idle.id) }
                if t == "graphite" { await shootBackgroundTasks(model, in: idle.id) }
            }
            if let needsYou {
                model.open(needsYou.id)
                await shot("\(t)-05-needs-you", settle: 1.0)
            }

            model.showNewChat(in: model.projects.first?.id)
            await shot("\(t)-06-new-chat", settle: 0.8)
            model.newChatProjectId = nil

            model.isPaletteOpen = true
            await shot("\(t)-07-palette", settle: 0.6)
            model.isPaletteOpen = false

            UserDefaults.standard.set("general", forKey: "settingsTab")
            model.isSettingsOpen = true
            await shot("\(t)-14-settings", settle: 0.8)
            UserDefaults.standard.set("profiles", forKey: "settingsTab")
            await shot("\(t)-29-icons-profiles", settle: 0.8)
            UserDefaults.standard.set("workflows", forKey: "settingsTab")
            await shot("\(t)-29-icons-workflows", settle: 0.8)
            if t == "graphite" {
                // The usage pane reads the agents' real logs: the first read takes a while.
                UserDefaults.standard.set("usage", forKey: "settingsTab")
                for _ in 0..<180 where model.usage.loadedAt == nil || model.accounts.refreshedAt == nil {
                    try? await Task.sleep(for: .milliseconds(500))
                }
                await shot("\(t)-25-usage", settle: 1.5)
                await tallShot("\(t)-26-usage-full")
                UserDefaults.standard.set("appearance", forKey: "settingsTab")
                await tallShot("\(t)-27-appearance-full")
                UserDefaults.standard.set("integrations", forKey: "settingsTab")
                await shot("\(t)-28-integrations", settle: 1.5)
                // Every other pane, whole.
                for tab in SettingsTab.allCases where ![.usage, .appearance, .integrations].contains(tab) {
                    UserDefaults.standard.set(tab.rawValue, forKey: "settingsTab")
                    await tallShot("\(t)-29-settings-\(tab.rawValue)")
                }
                UserDefaults.standard.set("general", forKey: "settingsTab")
            }
            UserDefaults.standard.set("general", forKey: "settingsTab")
            model.isSettingsOpen = false
            if t == "graphite", let idle { await shootFonts(model, in: idle.id) }

            if let idle, let path = idle.worktreePath {
                model.showNewChat(in: idle.projectId, worktree: path)
                await shot("\(t)-15-new-chat-in-worktree", settle: 1.2)
                model.newChatProjectId = nil
            }

            UserDefaults.standard.set("", forKey: "automations.open")
            model.destination = .automations
            await shot("\(t)-08-automations", settle: 0.8)
            if let first = model.automations.first {
                UserDefaults.standard.set(first.id, forKey: "automations.open")
                await shot("\(t)-16-automation-page", settle: 1.0)
                UserDefaults.standard.set("", forKey: "automations.open")
                // The same page on its Runs tab.
                UserDefaults.standard.set("history", forKey: "automations.tab")
                try? await Task.sleep(for: .milliseconds(400))
                UserDefaults.standard.set(first.id, forKey: "automations.open")
                await shot("\(t)-16c-automation-runs", settle: 1.0)
                UserDefaults.standard.set("", forKey: "automations.open")
                UserDefaults.standard.set("", forKey: "automations.tab")
            }
            if t == "graphite", let onEvents = model.automations.first(where: { !$0.events.isEmpty }) {
                UserDefaults.standard.set(onEvents.id, forKey: "automations.open")
                await shot("\(t)-16b-automation-events", settle: 1.0)
                UserDefaults.standard.set("", forKey: "automations.open")
            }
            // A new automation's page, opening on its describe box. Leaving
            // Automations below drops the page, so the next theme starts on the list.
            model.newAutomationRequest += 1
            await shot("\(t)-36-new-automation", settle: 1.0)
            model.destination = .worktrees
            await shot("\(t)-09-worktrees", settle: 1.2)
            model.destination = .pullRequests
            await shot("\(t)-24-pull-requests", settle: 1.0)
            if let payments = model.projects.first(where: { $0.name == "payments-api" }) {
                model.destination = .projectSettings(payments.id)
                await shot("\(t)-17-project-settings", settle: 1.5)
                await tallShot("\(t)-18-project-settings-full")
            }
            await shootPlugins(theme: t, beside: idle?.id)
        }
        UserDefaults.standard.set(ThemeChoice.graphite.rawValue, forKey: "theme")
        await projectLifecycleCheck()
    }

    /// Every bundled plugin, on (ABS-134): each screen, Kanban's three tabs,
    /// and each tab beside a chat. A theme's plugins must draw in it from
    /// the first frame, whatever the Mac is set to.
    private func shootPlugins(theme t: String, beside sessionId: String?) async {
        for folder in model.plugins.bundledFolders {
            guard let inspection = try? PluginPackage.inspect(folder: folder),
                  model.plugins.plugin(inspection.manifest.id) == nil else { continue }
            _ = try? model.plugins.install(from: folder, sourceKind: .bundled, enable: true)
        }
        if let sessionId { seedPluginStorage(beside: sessionId) }
        let kanban = "sh.abstract.kanban"
        for plugin in model.plugins.usable.sorted(by: { $0.id < $1.id }) {
            guard let view = plugin.manifest?.view else { continue }
            let name = plugin.id.split(separator: ".").last.map(String.init) ?? plugin.id
            let views = plugin.id == kanban ? ["board", "list", "mine"] : [""]
            for tab in views {
                if !tab.isEmpty { _ = try? model.plugins.manager.storage(for: kanban).set(.string(tab), forKey: "view") }
                // Away and back, so the screen opens fresh, as it would.
                model.destination = .home
                try? await Task.sleep(for: .milliseconds(200))
                model.destination = .plugin(plugin.id, view.id)
                await shot("\(t)-40-plugin-\(name)\(tab.isEmpty ? "" : "-\(tab)")", settle: 1.6)
            }
        }
        _ = try? model.plugins.manager.storage(for: kanban).set(.string("board"), forKey: "view")
        guard let sessionId else { return }
        model.open(sessionId)
        for contribution in model.plugins.contributions(.chatPanel) {
            let name = contribution.pluginId.split(separator: ".").last.map(String.init) ?? contribution.pluginId
            model.showPluginPanelTab(contribution, in: sessionId)
            await shot("\(t)-41-panel-\(name)", settle: 1.6)
        }
        model.resetLayout(sessionId)
        await shootLinkStatus(theme: t, in: sessionId)
    }

    /// Link status (ABS-126): a reply naming a merged pull request, an open
    /// issue and a Linear ticket, each with its status after it. The
    /// statuses are seeded, so nothing is asked of GitHub or Linear.
    private func shootLinkStatus(theme t: String, in sessionId: String) async {
        let plugin = "sh.abstract.link-status"
        guard model.plugins.plugin(plugin)?.isUsable == true else { return }
        let seeded: [(String, String, PluginLinkStatus)] = [
            ("github", "https://github.com/acme/shop/pull/43", PluginLinkStatus(label: "Merged", tone: .merged)),
            ("github", "https://github.com/acme/shop/pull/44", PluginLinkStatus(label: "Open · Checks failing", tone: .failing)),
            ("github", "https://github.com/acme/shop/issues/12", PluginLinkStatus(label: "Open", tone: .open)),
            ("linear", "https://linear.app/acme/issue/SHOP-7", PluginLinkStatus(label: "In Progress · ada", tone: .open)),
        ]
        for (decorator, url, status) in seeded {
            model.pluginLinks.seed(PluginLinks.Match(pluginId: plugin, contributionId: decorator, url: url), status)
        }
        let feed = model.feed(sessionId)
        let before = feed.timeline
        var shown = before
        shown.append(.text(role: .user, text: "Where are we with https://linear.app/acme/issue/SHOP-7/empty-carts?", blockId: nil, partial: false))
        shown.append(.text(role: .assistant, text: """
            The discount fix landed in https://github.com/acme/shop/pull/43, which closes \
            [the empty-cart issue](https://github.com/acme/shop/issues/12) once it ships.

            - The follow-up, https://github.com/acme/shop/pull/44, still has a failing lint check.
            - https://linear.app/acme/issue/SHOP-7 stays in progress until both are out.
            """, blockId: nil, partial: false))
        feed.reset(shown)
        model.open(sessionId)
        await shot("\(t)-42-link-status", settle: 1.6)
        feed.reset(before)
    }

    /// What Follow PR and Second opinion would have stored for a chat, so
    /// their tabs show something to read. Nothing in it is due, so neither
    /// background script acts on it.
    private func seedPluginStorage(beside sessionId: String) {
        let at = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3_000))
        let follow = JSONValue(any: [
            "follows": [sessionId: ["number": 42, "seen": [], "failing": [], "pending": [], "dueAt": NSNull(),
                                    "waiting": false, "day": "", "sent": 0]],
            "history": [sessionId: [["at": at, "number": 42, "count": 3, "kinds": ["code", "code", "check"]]]],
        ] as [String: Any])
        for (key, value) in follow.object ?? [:] {
            _ = try? model.plugins.manager.storage(for: "sh.abstract.follow-pr").set(value, forKey: key)
        }
        let review = JSONValue(any: [sessionId: ["agentId": "codex", "agentName": "Codex", "scope": "uncommitted",
                                                 "reviewerId": "none", "round": 1, "phase": "waiting"]] as [String: Any])
        _ = try? model.plugins.manager.storage(for: "sh.abstract.second-opinion").set(review, forKey: "reviews")
    }

    /// The whole settings page: the window made tall enough, then put back.
    private func tallShot(_ name: String) async {
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }) else { return }
        let frame = window.frame
        window.setFrame(NSRect(x: frame.minX, y: frame.maxY - 1500, width: frame.width, height: 1500), display: true)
        await shot(name, settle: 1.2)
        window.setFrame(frame, display: true)
    }

    /// Keep a screenshot of the side panel at the smallest useful window width.
    /// The Run action is available in this demo project, and Review makes a
    /// third tab so the strip must scroll while New tab stays in view.
    private func shootNarrowSidePanel(in sessionId: String, theme: String) async {
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }) else { return }
        let frame = window.frame
        let targetId = model.sessions.first { session in
            session.worktreePath != nil && Project.nonBlank(model.project(session.projectId)?.runScript) != nil
        }?.id ?? sessionId
        let activeId = model.layout(for: targetId).side.active?.id
        model.open(targetId)
        model.showPane(.review, in: targetId)
        window.setFrame(NSRect(x: frame.minX, y: frame.minY, width: 820, height: frame.height), display: true)
        await shot("\(theme)-03c-chat-narrow", settle: 1.2)
        window.setFrame(frame, display: true)
        if let activeId { model.updateLayout(targetId) { $0.activate(activeId) } }
        model.open(sessionId)
    }

    /// A new chat in payments-api is set up before its agent starts (its
    /// origin can't be reached, so the base is the copy already here, and
    /// the setup script's output shows in the chat), Run opens (then reuses)
    /// a Run terminal, and deleting the chat runs the teardown script.
    /// Sparse checkout applies to the new worktree.
    private func projectLifecycleCheck() async {
        guard let root = DemoBootstrap.current?.root, let p = model.projects.first(where: { $0.name == "payments-api" }) else { return }
        let marker = root.appendingPathComponent("teardown-ran").path
        // A chosen symbol and colour, and the picker itself (drawn off screen).
        model.setProjectIcon(p.id, symbol: "shippingbox", color: "sage")
        model.destination = .projectSettings(p.id)
        await shot("graphite-19-project-icon", settle: 1.0)
        if let current = model.project(p.id) {
            let renderer = ImageRenderer(content: IconPicker(
                value: IconValue(symbol: current.iconSymbol, color: current.iconColor, imagePath: current.iconImagePath),
                name: current.name, onChange: { _ in }, onUpload: { _ in }, dismiss: {})
                .environment(model).environment(\.colorScheme, .dark))
            renderer.scale = 2
            if let tiff = renderer.nsImage?.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("graphite-19b-icon-picker.png"))
            }
        }
        model.updateProject(p.id) { p in
            p.sparseCheckout = ["src"]
            p.teardownScript = "echo \"$PWD\" > '\(marker)'"
            p.setupScript = "echo \"Setting up $(basename \"$PWD\")\"\nls\nsleep 2\necho ready"
        }
        let id: String
        do {
            id = try await model.startChat(projectId: p.id, providerId: "claude", prompt: "Check the lifecycle scripts", baseRef: "main",
                                           policy: .autoEdits)
        } catch {
            log("demo: lifecycle chat failed: \(error.localizedDescription)")
            return
        }
        // Mid-setup: the card under the prompt, the script's output coming in.
        var seen: (phases: String, log: [String]) = ("", [])
        let deadline = Date().addingTimeInterval(60)
        var shotMidSetup = false
        while let setup = model.setups[id], Date() < deadline {
            seen = (ChatSetup.Step.allCases.map { "\($0)=\(setup.phase($0))" }.joined(separator: " "), setup.log)
            if !shotMidSetup, setup.phase(.script) == .running, !setup.log.isEmpty {
                shotMidSetup = true
                await shot("graphite-20-chat-setup", settle: 0.4)
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        log("demo: lifecycle setup ended \(model.setups[id] == nil ? "and the agent started" : "unfinished: \(seen.phases)"); "
            + "last phases \(seen.phases); script printed \(seen.log.joined(separator: " | "))")
        guard let s = model.session(id), let path = s.worktreePath else { return }
        log("demo: lifecycle chat status \(s.status.rawValue), base \(s.baseRef ?? "?"), alive=\(model.isAlive(id))")
        let top = (try? FileManager.default.contentsOfDirectory(atPath: path))?.filter { $0 != ".git" }.sorted() ?? []
        log("demo: lifecycle worktree \(s.branch ?? "?") has \(top.joined(separator: ","))")
        func terminals() -> [String] {
            model.layout(for: s.id).items(of: .terminal).map { item in
                let host = TerminalRegistry.shared.existingHost(for: item.id)
                let text = host.map { String(decoding: $0.terminal.getTerminal().getBufferAsData(), as: UTF8.self) } ?? ""
                let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                return "[\(host?.title ?? "?")] " + lines.suffix(4).joined(separator: " | ")
            }
        }
        model.runProjectScript(in: s.id)
        await shot("graphite-21-run-terminal", settle: 2.5)
        model.runProjectScript(in: s.id)
        try? await Task.sleep(for: .seconds(2))
        log("demo: lifecycle after two runs: \(terminals())")
        await model.delete(s.id, removeWorktree: true)
        let wrote = (try? String(contentsOfFile: marker, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        log("demo: lifecycle teardown \(wrote.map { "ran in \($0)" } ?? "did NOT run"); worktree gone=\(!FileManager.default.fileExists(atPath: path))")

        // A custom icon is copied in, shown, and deleted again by Use Default.
        let source = root.appendingPathComponent("icon-source.png")
        let art = NSImage(size: NSSize(width: 640, height: 400), flipped: false) { rect in
            NSColor(hex: 0x6B7A63).setFill(); rect.fill()
            NSColor.white.setFill(); NSBezierPath(ovalIn: rect.insetBy(dx: 220, dy: 100)).fill()
            return true
        }
        if let tiff = art.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: source)
        }
        model.importProjectIcon(p.id, from: source)
        let copied = model.project(p.id)?.iconImagePath
        model.destination = .projectSettings(p.id)
        await shot("graphite-22-custom-icon", settle: 1.0)
        model.resetProjectIcon(p.id)
        log("demo: icon copied to \(copied ?? "nil"), removed on reset=\(copied.map { !FileManager.default.fileExists(atPath: $0) } ?? false)")

        // Re-pointing: an unrelated repository is refused, a copy of this one accepted.
        let unrelated = root.appendingPathComponent("unrelated").path
        let moved = root.appendingPathComponent("moved/payments-api").path
        try? FileManager.default.createDirectory(atPath: unrelated, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: (moved as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? "x\n".write(toFile: unrelated + "/x.txt", atomically: true, encoding: .utf8)
        for args in [["init", "-q", "-b", "main"], ["add", "-A"], ["-c", "user.email=d@d", "-c", "user.name=d", "commit", "-qm", "x"]] {
            _ = try? await model.executor.run("git", args, cwd: unrelated)
        }
        _ = try? await model.executor.run("cp", ["-R", p.rootPath, moved], cwd: nil)
        for target in [unrelated, model.projects.first { $0.name == "abstract" }?.rootPath ?? "/", moved] {
            do {
                try await model.relocateProject(p.id, to: target)
                log("demo: relocate to \(target) accepted; root now \(model.project(p.id)?.rootPath ?? "?")")
            } catch {
                log("demo: relocate to \(target) refused: \(error.localizedDescription)")
            }
        }
    }

    /// A pull request for the finished chat (one check failing, a review
    /// asking for changes) and a merged one for another, as a code host
    /// answers them (ABS-139).
    private func seedPullRequests(_ model: AppModel, for chat: Session) {
        guard let branch = chat.branch, let projectId = chat.projectId else { return }
        func ago(_ seconds: TimeInterval) -> String { ISO8601DateFormatter().string(from: Date().addingTimeInterval(-seconds)) }
        let open = #"""
        {"number": 128, "title": "\#(chat.name)", "state": "open", "isDraft": false,
         "url": "https://github.com/acme/abstract/pull/128", "head": "\#(branch)", "base": "main",
         "author": "wes", "reviewDecision": "changesRequested", "mergeable": "MERGEABLE", "mergeState": "BLOCKED",
         "additions": 10, "deletions": 2, "changedFiles": 2, "updatedAt": "\#(ago(600))",
         "checks": [
           {"name": "unit tests", "workflow": "CI", "outcome": "passed", "url": "https://github.com/acme/abstract/actions/runs/1"},
           {"name": "lint", "workflow": "CI", "outcome": "failed", "url": "https://github.com/acme/abstract/actions/runs/2"},
           {"name": "ui snapshots", "workflow": "CI", "outcome": "pending"}
         ],
         "reviews": [{"author": "ana", "verdict": "changesRequested", "body": "Archived chats have no process, so `derivedStatus` would call them errored. Keep the stored status for those."}],
         "comments": [{"author": "vercel", "association": "NONE", "isBot": true, "body": "Preview deployed."}],
         "threads": [
          {"id": "T1", "isResolved": false, "isOutdated": false, "path": "src/sessions/SessionRow.swift", "line": 11,
           "diffHunk": "@@ -9,6 +9,6 @@ struct SessionRow: View {\n     var body: some View {\n-    let status = session.status\n+    let status = session.derivedStatus",
           "comments": [
             {"id": "C1", "author": "ana", "body": "This reads liveness on every redraw. Can the registry publish changes instead?", "createdAt": "\#(ago(3_000))"},
             {"id": "C2", "author": "wes", "body": "It's a set lookup, so it's cheap, but a published value would avoid the redraws. I'll change it.", "createdAt": "\#(ago(2_400))"},
             {"id": "C3", "author": "ana", "body": "Thanks.", "createdAt": "\#(ago(2_000))"}
           ]},
          {"id": "T2", "isResolved": true, "isOutdated": false, "path": "src/sessions/SessionStatus+Derived.swift", "line": 4,
           "comments": [{"id": "C4", "author": "ana", "body": "Nit: document the archived case.", "createdAt": "\#(ago(2_900))"}]}
         ]}
        """#
        let merged = #"""
        {"number": 121, "title": "Retry idempotent webhook deliveries", "state": "merged", "isDraft": false,
         "head": "abstract/retry-webhooks", "base": "main", "author": "wes", "updatedAt": "\#(ago(86_400))"}
        """#
        func decode(_ text: String) -> PullRequest? {
            (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))).flatMap(PullRequest.init(contract:))
        }
        guard let pr = decode(open), let old = decode(merged) else { return }
        model.pullRequests[chat.id] = pr
        model.projectPullRequests[projectId] = [pr, old]
        if let other = model.sessions.first(where: { $0.id != chat.id && $0.status != .running && $0.projectId != nil }) {
            var mergedPR = old
            mergedPR.head = other.branch ?? old.head
            model.pullRequests[other.id] = mergedPR
            model.projectPullRequests[other.projectId!, default: []].append(mergedPR)
        }
    }

    /// A message sent with an issue and a screenshot, and more waiting in the composer.
    private func shootAttachments(_ model: AppModel, in sessionId: String) async {
        model.open(sessionId)
        model.showPane(.files, in: sessionId)
        let size = NSSize(width: 480, height: 300)
        let picture = NSImage(size: size, flipped: false) { rect in
            NSGradient(starting: .systemIndigo, ending: .systemTeal)?.draw(in: rect, angle: 30)
            return true
        }
        let png = picture.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
        let screenshot = png.flatMap { try? AttachmentStore.importImage($0, named: "archived-status.png") }
        let issue = PromptAttachment(kind: .githubIssue, title: "Archived chats show the wrong status", reference: "#42",
                                     url: "https://github.com/acme/app/issues/42", body: "Archived chats show Running after a restart.")
        try? model.sendFollowUp(sessionId, text: "This is the bug from the issue; the screenshot shows it.",
                                attachments: [issue] + (screenshot.map { [$0] } ?? []))
        model.draftAttachments[sessionId] = [
            PromptAttachment(kind: .trackerIssue, title: "Status dot for archived chats", reference: "ENG-318",
                             url: "https://linear.app/acme/issue/ENG-318", details: ["State: In Progress"],
                             tracker: PromptAttachment.linearTrackerId, trackerName: "Linear"),
            PromptAttachment(kind: .pullRequest, title: "Derive status from the process", reference: "#57",
                             url: "https://github.com/acme/app/pull/57"),
            PromptAttachment(kind: .file, title: "SessionRow.swift", path: "/tmp/SessionRow.swift"),
        ]
        // The Linear plugin puts its issue search beside Send (ABS-141).
        if model.plugins.plugin(PromptAttachment.linearTrackerId) == nil,
           let folder = model.plugins.bundledFolders.first(where: { $0.lastPathComponent == "linear.abstractplugin" }) {
            _ = try? model.plugins.install(from: folder, sourceKind: .bundled, enable: true)
        }
        await shot("graphite-03c-attachments", settle: 2.5)
        model.draftAttachments[sessionId] = nil
    }

    /// The first call of a kind in a transcript, and the row it's on.
    static func firstCall(in feed: ChatFeed, kind: ToolKind) -> (row: Int, call: String)? {
        for row in feed.rows {
            if case let .tools(_, calls) = row.block, let call = calls.first(where: { ToolKind($0.name) == kind }) { return (row.id, call.id) }
        }
        return nil
    }

    /// Revund's findings on the chat's changes, under their lines and in the strip.
    private func shootRevund(_ model: AppModel, in sessionId: String) async {
        let blocker = RevundFinding(id: "f1", fingerprint: "a1b2c3d4e5f60718", pass: "correctness", severity: .blocker,
                                    file: "src/sessions/SessionRow.swift", line: 11,
                                    body: "`derivedStatus` reads the process table on every redraw of every row.",
                                    why: "The sidebar redraws on each streamed token; with many chats this blocks the main thread.",
                                    suggest: "let status = session.cachedDerivedStatus")
        let nit = RevundFinding(id: "f2", pass: "style", severity: .nitpick, file: "src/sessions/SessionRow.swift", line: 3,
                                body: "The doc comment no longer says what the row shows.")
        RevundService.shared.seed(sessionId, scope: "uncommitted changes", report: RevundReport(findings: [blocker, nit]))
        model.openDiffTab(in: sessionId)
        await shot("graphite-30-revund-review", settle: 2.0)
        RevundService.shared.clear(sessionId)
        model.open(sessionId)
    }

    /// What the demo agent left in the background: the chip, the list, a
    /// subagent's work and a command's output, then the preview server stopped.
    private func shootBackgroundTasks(_ model: AppModel, in sessionId: String) async {
        model.open(sessionId)
        // The finished tasks' own turns are over; the preview server still runs.
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, model.backgroundTasks(sessionId).count { $0.status == .completed } < 2 || model.session(sessionId)?.status != .idle {
            try? await Task.sleep(for: .milliseconds(200))
        }
        await shot("graphite-31-background-chip", settle: 1.0)
        model.tasksOpen = TasksFocus(sessionId: sessionId)
        await shot("graphite-32-background-tasks", settle: 1.0)
        if let agent = model.backgroundTasks(sessionId).first(where: { $0.kind == .agent }) {
            model.tasksOpen = TasksFocus(sessionId: sessionId, taskId: agent.id)
            await shot("graphite-33-background-subagent", settle: 1.0)
        }
        if let server = model.backgroundTasks(sessionId).first(where: { $0.kind == .shell && $0.status == .running }) {
            model.tasksOpen = TasksFocus(sessionId: sessionId, taskId: server.id)
            await shot("graphite-34-background-command", settle: 2.5)
            model.stopTask(sessionId, taskId: server.id)
            await shot("graphite-35-background-stopped", settle: 1.5)
        }
        log("demo: background tasks " + model.backgroundTasks(sessionId).map { "\($0.description)=\($0.status.rawValue)" }.joined(separator: ", "))
        model.tasksOpen = nil
    }

    /// The app's icon as Finder and the Dock draw it, at Dock and list sizes. macOS
    /// picks its version from the icon style in System Settings › Appearance (lunar
    /// for Default, planetario for Dark), not from the app's appearance, so a run
    /// captures whichever that Mac is set to.
    private func shootAppIcon() {
        let icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        let sizes: [CGFloat] = [256, 64, 32, 16]
        let image = NSImage(size: NSSize(width: sizes.reduce(0, +) + 24 * CGFloat(sizes.count + 1), height: 304), flipped: false) { rect in
            NSColor.windowBackgroundColor.setFill()
            rect.fill()
            var x: CGFloat = 24
            for size in sizes {
                icon.draw(in: NSRect(x: x, y: (rect.height - size) / 2, width: size, height: size))
                x += size + 24
            }
            return true
        }
        guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("00-app-icon.png")
        try? png.write(to: url)
        log("snapshot: \(url.path)")
    }

    /// Other interface and editor fonts, applied to a file tab.
    private func shootFonts(_ model: AppModel, in sessionId: String) async {
        let d = UserDefaults.standard
        model.openFile("src/sessions/SessionRow.swift", in: sessionId)
        await shot("graphite-29a-default-fonts", settle: 1.2)
        let custom: [String: Any] = [
            UIFontChoice.familyKey: UIFontChoice.system, UIFontChoice.sizeKey: 14.0, UIFontChoice.weightKey: "medium",
            EditorFontChoice.familyKey: EditorFontChoice.systemMono, EditorFontChoice.sizeKey: 14.0,
            EditorFontChoice.ligaturesKey: false, EditorFontChoice.lineHeightKey: 1.6,
        ]
        for (key, value) in custom { d.set(value, forKey: key) }
        model.openFile("src/sessions/SessionRow.swift", in: sessionId)
        await shot("graphite-29-custom-fonts", settle: 1.5)
        for key in custom.keys { d.removeObject(forKey: key) }
        model.open(sessionId)
        try? await Task.sleep(for: .milliseconds(500))
    }

    private func shot(_ name: String, settle: Double = 0.7) async {
        try? await Task.sleep(for: .seconds(settle))
        guard let image = WindowCapture.image() else {
            let states = NSApp.windows.map { w in
                "[\(w.className) visible=\(w.isVisible) main=\(w.canBecomeMain) activeSpace=\(w.isOnActiveSpace) occluded=\(!w.occlusionState.contains(.visible)) frame=\(Int(w.frame.width))x\(Int(w.frame.height))]"
            }
            log("snapshot failed: \(name) windows=\(states.joined(separator: " "))")
            return
        }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
        try? image.write(to: url)
        log("snapshot: \(url.path)")
    }
}

/// Renders the app's own main window, attached sheets composited on top.
/// Screen Recording permission is not needed because only our own views are
/// drawn. Drawing happens under the window's effective appearance so dynamic
/// colours resolve the way they do on screen.
@MainActor
enum WindowCapture {
    enum Method { case cacheDisplay, layer, windowServer }

    /// `CGWindowListCreateImage` is hidden from the macOS 15 SDK in favour of
    /// ScreenCaptureKit, but still works for the calling process's own windows
    /// without Screen Recording permission, and is the only path that includes
    /// window-server effects (glass, scroll views, sheets).
    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    private static let createImage: CreateImage? = {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
              let sym = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(sym, to: CreateImage.self)
    }()

    static func windowServerImage() -> Data? {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }), let create = createImage else { return nil }
        // kCGWindowListOptionIncludingWindow = 1 << 3; imageOption: boundsIgnoreFraming (1) | bestResolution (1 << 3)
        guard let cg = create(.null, 1 << 3, UInt32(window.windowNumber), (1 << 0) | (1 << 3))?.takeRetainedValue() else { return nil }
        // Sheets and popovers are separate windows; composite them over the main one.
        let sheets = (window.sheets + (window.childWindows ?? [])).filter(\.isVisible)
        if sheets.isEmpty { return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) }
        let scale = CGFloat(cg.width) / window.frame.width
        guard let ctx = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        for sheet in sheets {
            guard let img = create(.null, 1 << 3, UInt32(sheet.windowNumber), (1 << 0) | (1 << 3))?.takeRetainedValue() else { continue }
            let x = (sheet.frame.minX - window.frame.minX) * scale
            let y = (sheet.frame.minY - window.frame.minY) * scale
            ctx.draw(img, in: CGRect(x: x, y: y, width: CGFloat(img.width), height: CGFloat(img.height)))
        }
        guard let out = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])
    }

    static func image(method: Method = .windowServer) -> Data? {
        if method == .windowServer { return windowServerImage() }
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
              let frameView = window.contentView?.superview else { return nil }
        let size = frameView.bounds.size
        let scale = window.backingScaleFactor
        let width = Int(size.width * scale), height = Int(size.height * scale)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)

        func draw(_ view: NSView, at origin: CGPoint) {
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                ctx.saveGState()
                ctx.translateBy(x: origin.x, y: origin.y)
                switch method {
                case .layer:
                    if let layer = view.layer {
                        // CALayer draws top-down; flip into CG's bottom-up space.
                        ctx.translateBy(x: 0, y: view.bounds.height)
                        ctx.scaleBy(x: 1, y: -1)
                        layer.render(in: ctx)
                    }
                case .cacheDisplay, .windowServer:
                    if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: rep)
                        if let cg = rep.cgImage { ctx.draw(cg, in: CGRect(origin: .zero, size: view.bounds.size)) }
                    }
                }
                ctx.restoreGState()
            }
        }

        draw(frameView, at: .zero)
        for child in window.sheets + (window.childWindows ?? []) where child.isVisible {
            guard let v = child.contentView?.superview else { continue }
            draw(v, at: CGPoint(x: child.frame.minX - window.frame.minX, y: child.frame.minY - window.frame.minY))
        }
        guard let cg = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
