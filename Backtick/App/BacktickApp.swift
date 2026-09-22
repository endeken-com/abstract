import SwiftUI
import AppKit
import BacktickCore

@main
struct BacktickApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage("theme") private var theme: ThemeChoice = .graphite

    var body: some Scene {
        Window("Backtick", id: "main") {
            RootView()
                .environment(delegate.model)
                .preferredColorScheme(theme.colorScheme)
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1280, height: 820)
        // Always open the main window at launch. Restored "closed" state (or
        // several demo instances sharing it) must never leave Backtick windowless.
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)
        .commands { BacktickCommands(model: delegate.model) }

        Settings {
            SettingsView()
                .environment(delegate.model)
                .preferredColorScheme(theme.colorScheme)
        }
    }
}

extension AppModel {
    static func make() -> AppModel {
        if let demo = DemoBootstrap.current { return demo.makeModel() }
        let store: Store
        do {
            store = try Store(path: Store.defaultPath())
        } catch {
            fatalError("Backtick could not open its database: \(error)")
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
        guard !model.engine.aliveSessionIds.isEmpty, DemoBootstrap.current == nil else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit while agents are working?"
        alert.informativeText = "\(model.engine.aliveSessionIds.count) agent\(model.engine.aliveSessionIds.count == 1 ? " is" : "s are") still running. Quitting stops them; their worktrees stay as they are."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        model.engine.stopAll()
        return .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { for w in sender.windows where w.canBecomeMain { w.makeKeyAndOrderFront(nil) } }
        return true
    }
}

struct BacktickCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Chat") { model.showNewChat(in: model.selectedSession?.projectId) }
                .keyboardShortcut("n")
            Button("Add Project…") { model.isAddingProject = true }
                .keyboardShortcut("o", modifiers: [.command, .shift])
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
            Button(model.chatTab == .changes ? "Show Conversation" : "Review Changes") {
                model.chatTab = model.chatTab == .changes ? .chat : .changes
            }
            .keyboardShortcut("d")
            .disabled(model.selectedSession == nil)
            Button("Stop Agent") { if let s = model.selectedSession { model.stop(s.id) } }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(model.selectedSession.map { !model.isAlive($0.id) } ?? true)
            Button("Resume Agent") { if let s = model.selectedSession { model.resume(s.id) } }
                .disabled(model.selectedSession.map { model.isAlive($0.id) } ?? true)
            Divider()
            Button("Archive Chat") { if let s = model.selectedSession { model.setArchived(s.id, true) } }
                .disabled(model.selectedSession == nil)
        }
    }
}
