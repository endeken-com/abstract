import Foundation
import AbstractCore

/// The main pane's tabs. The chat a tab belongs to is the one the window is
/// on: the sidebar marks it, and the side panel shows its files and changes.
extension AppModel {
    var activeTab: MainTab? { mainTabs.active }

    /// A file in a chat's worktree. A single click previews it; opening it
    /// from elsewhere keeps it.
    func openFileTab(_ path: String, in sessionId: String, preview: Bool = false) {
        mainTabs.openFile(path, in: sessionId, preview: preview)
        follow()
    }

    /// The chat's changes, scrolled to `path` if given.
    func openDiffTab(in sessionId: String, focus path: String? = nil) {
        if let path { pendingChangeSelection[sessionId] = path }
        mainTabs.openDiff(in: sessionId)
        follow()
    }

    func activateTab(_ id: String) {
        mainTabs.activate(id)
        follow()
    }

    func keepTab(_ id: String) { mainTabs.keep(id) }

    /// The file showing, when a file tab is.
    var activeFileDocument: EditorDocument? {
        guard case let .file(sessionId, path)? = mainTabs.active?.kind, let root = session(sessionId)?.worktreePath else { return nil }
        return EditorStore.shared.existing(root: root, path: path, in: sessionId)
    }

    func saveActiveFile() {
        guard let document = activeFileDocument else { return }
        Task { await document.save() }
    }

    func closeTab(_ id: String) {
        let leaving = mainTabs.tabs.first { $0.id == id }?.kind.sessionId
        mainTabs.close(id)
        syncDestinationWithTabs(leaving: leaving)
    }

    func closeOtherTabs(_ id: String) {
        mainTabs.closeOthers(id)
        follow()
    }

    func moveTab(_ id: String, to target: String) { mainTabs.move(id, to: target) }

    /// ⌘⇧] and ⌘⇧[: the next or previous tab, wrapping.
    func cycleTab(_ delta: Int) {
        let tabs = mainTabs.tabs
        guard tabs.count > 1, let i = tabs.firstIndex(where: { $0.id == mainTabs.activeId }) else { return }
        activateTab(tabs[(i + delta + tabs.count) % tabs.count].id)
    }

    /// The window goes to the active tab's chat.
    private func follow() {
        guard let tab = mainTabs.active else { return }
        let sessionId = tab.kind.sessionId
        if case .session(let current) = destination, current == sessionId { return }
        destination = .session(sessionId)
        if sessionId.hasPrefix(RemoteService.mirrorPrefix) { remote.subscribe(sessionId) } else { loadTimelineIfNeeded(sessionId) }
    }

    /// After a tab closed or a chat left: follow what's showing now, or go home.
    func syncDestinationWithTabs(leaving sessionId: String?) {
        if mainTabs.active != nil { follow(); return }
        if case .session(let id) = destination, sessionId == nil || id == sessionId { destination = .home }
    }
}
