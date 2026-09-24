import SwiftUI
import AppKit
import AbstractCore

@main
struct AbstractApp: App {
    init() {
        BTFont.registerBundled()
        ThinScroller.install()
    }

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage("theme") private var theme: ThemeChoice = .graphite

    var body: some Scene {
        Window("Abstract", id: "main") {
            RootView()
                .font(.btBody)
                .environment(delegate.model)
                .environment(delegate.updater)
                .preferredColorScheme(theme.colorScheme)
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1280, height: 820)
        // Always open the main window at launch. Restored "closed" state (or
        // several demo instances sharing it) must never leave Abstract windowless.
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)
        .commands { AbstractCommands(model: delegate.model, updater: delegate.updater) }
    }
}

extension AppModel {
    /// Abstract was called Backtick: bring its data and preferences along the
    /// first time. Waits while the old app still runs, so its open database
    /// is never moved out from under it.
    private static func migrateFromBacktick() {
        let legacyBundle = "sh.backtick.app"
        guard NSRunningApplication.runningApplications(withBundleIdentifier: legacyBundle).isEmpty else { return }
        Store.migrateLegacyData()
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedFromBacktick"), let old = defaults.persistentDomain(forName: legacyBundle) else { return }
        for (key, value) in old where defaults.object(forKey: key) == nil { defaults.set(value, forKey: key) }
        defaults.set(true, forKey: "migratedFromBacktick")
    }

    static func make() -> AppModel {
        if let demo = DemoBootstrap.current { return demo.makeModel() }
        migrateFromBacktick()
        let store: Store
        do {
            store = try Store(path: Store.defaultPath())
        } catch {
            fatalError("Abstract could not open its database: \(error)")
        }
        return AppModel(store: store, engine: SessionEngine(executor: LocalExecutor.shared, logDirectory: SessionEngine.defaultLogDirectory()),
                        executor: LocalExecutor.shared)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Created here, not in a view, and bootstrapped at launch: sessions,
    /// the engine and the automation scheduler must run whether or not a
    /// window ever appears (hidden at login, occluded, on another Space).
    let model = AppModel.make()
    /// Checks for updates from launch, window or not, like the automation scheduler.
    let updater = Updater()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Notifier.shared.onOpenSession { [model] id in model.open(id) }
        Task {
            await model.bootstrap()
            if let demo = DemoBootstrap.current { await demo.run(model) }
        }
    }

    /// Keep running with no window open: automations have to fire.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let working = model.workingSessionIds.count
        guard working > 0, DemoBootstrap.current == nil else { model.engine.stopAll(); return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit while agents are working?"
        alert.informativeText = "\(working) agent\(working == 1 ? " is" : "s are") still running. Quitting stops them; their worktrees stay as they are."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        model.engine.stopAll()
        return .terminateNow
    }

    /// Hang up every terminal's shell, like closing terminal windows.
    func applicationWillTerminate(_ notification: Notification) {
        TerminalRegistry.shared.closeAll()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { for w in sender.windows where w.canBecomeMain { w.makeKeyAndOrderFront(nil) } }
        return true
    }
}

struct AbstractCommands: Commands {
    let model: AppModel
    let updater: Updater

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            CheckForUpdatesButton(updater: updater)
        }
        // Settings open as a panel over the window, not a separate window.
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { model.isPaletteOpen = false; model.isSettingsOpen.toggle() }
                .keyboardShortcut(",")
        }
        CommandGroup(replacing: .newItem) {
            Button("New Chat") { model.showNewChat(in: model.selectedSession?.projectId) }
                .keyboardShortcut("n")
            Button("Add Project…") { model.isAddingProject = true }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        // Tabs of the main pane: ⌘W closes the tab showing, not the window.
        CommandGroup(replacing: .saveItem) {
            Button("Save") { model.saveActiveFile() }
                .keyboardShortcut("s")
                .disabled(model.activeFileDocument == nil)
            Button("Close Tab") {
                if let tab = model.activeTab, case .session = model.destination { model.closeTab(tab.id) }
                else { NSApp.keyWindow?.performClose(nil) }
            }
            .keyboardShortcut("w")
            Divider()
            Button("Show Next Tab") { model.cycleTab(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Show Previous Tab") { model.cycleTab(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
        }
        CommandMenu("Go") {
            Button("Jump To…") { model.isPaletteOpen.toggle() }
                .keyboardShortcut("k")
            Divider()
            Button("New") { model.startNew() }
                .keyboardShortcut("0")
            Button("Automations") { model.destination = .automations }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            Button("Worktrees") { model.destination = .worktrees }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            Divider()
            ForEach(Array(model.sessions.filter { $0.archivedAt == nil }.prefix(9).enumerated()), id: \.element.id) { i, s in
                Button(s.name) { model.open(s.id) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
            }
        }
        CommandMenu("Chat") {
            Button("Side Panel") { if let s = model.selectedSession { model.togglePanel(.side, in: s.id) } }
                .keyboardShortcut("b", modifiers: [.command, .option])
                .disabled(model.selectedSession == nil)
            Button("Bottom Panel") { if let s = model.selectedSession { model.togglePanel(.bottom, in: s.id) } }
                .keyboardShortcut("j")
                .disabled(model.selectedSession == nil)
            Divider()
            Button("Review Changes") { if let s = model.selectedSession { model.togglePane(.changes, in: s.id) } }
                .keyboardShortcut("d")
                .disabled(model.selectedSession == nil)
            Button("Files") { if let s = model.selectedSession { model.togglePane(.files, in: s.id) } }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model.selectedSession == nil)
            Button("Terminal") { if let s = model.selectedSession { model.togglePane(.terminal, in: s.id) } }
                .keyboardShortcut("`", modifiers: .control)
                .disabled(model.selectedSession == nil)
            Button("New Terminal") { if let s = model.selectedSession { model.newTerminal(in: s.id) } }
                .keyboardShortcut("`", modifiers: [.control, .shift])
                .disabled(model.selectedSession == nil)
            Button("Reset Layout") { if let s = model.selectedSession { model.resetLayout(s.id) } }
                .disabled(model.selectedSession == nil)
            Divider()
            Button("Stop Agent") { if let s = model.selectedSession { model.stop(s.id) } }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(model.selectedSession.map { !model.isAlive($0.id) } ?? true)
            Button("Resume Agent") { if let s = model.selectedSession { model.resume(s.id) } }
                .disabled(model.selectedSession.map { model.isAlive($0.id) } ?? true)
            // As Ctrl+B in Claude Code: the command or subagent at work carries on while the chat does.
            Button("Run in Background") { if let s = model.selectedSession { model.moveToBackground(s.id) } }
                .keyboardShortcut("b", modifiers: .control)
                .disabled(model.selectedSession.map { model.foregroundTasks($0.id).isEmpty } ?? true)
            Button("Background Tasks") { if let s = model.selectedSession { model.tasksOpen = TasksFocus(sessionId: s.id) } }
                .disabled(model.selectedSession.map { model.backgroundTasks($0.id).isEmpty } ?? true)
            Divider()
            Button("Archive Chat") { if let s = model.selectedSession { model.requestArchive = s.id } }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
                .disabled(model.selectedSession == nil)
        }
    }
}

/// "Check for Updates…" in the app menu. A view, so the menu item follows the updater's state.
private struct CheckForUpdatesButton: View {
    let updater: Updater

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}
