import Foundation
import AbstractCore

/// Each chat's two panels (side and bottom), persisted in the store as JSON.
extension AppModel {
    private func layoutKey(_ sessionId: String) -> String { "panels.\(sessionId)" }

    /// The chat's panels; new chats start with the standard arrangement.
    func layout(for sessionId: String) -> PanelLayout {
        if let cached = layouts[sessionId] { return cached }
        return store.setting(layoutKey(sessionId), as: PanelLayout.self) ?? .standard()
    }

    /// Change a chat's panels and remember them. A terminal tab that goes
    /// away ends its shell; hiding a panel keeps its tabs, and so its shells.
    func updateLayout(_ sessionId: String, _ change: (inout PanelLayout) -> Void) {
        var layout = layout(for: sessionId)
        let before = Set(layout.items(of: .terminal).map(\.id))
        change(&layout)
        layouts[sessionId] = layout
        try? store.setSetting(layoutKey(sessionId), layout)
        for id in before.subtracting(layout.items(of: .terminal).map(\.id)) { TerminalRegistry.shared.close(paneId: id) }
    }

    /// Bring a tab of `kind` forward, opening its panel.
    func showPane(_ kind: PaneKind, in sessionId: String) {
        updateLayout(sessionId) { $0.show(kind) }
    }

    /// The menu commands (⌘D, ⇧⌘E, ⌃`): show that tab, or hide its panel
    /// when it is already the one showing.
    func togglePane(_ kind: PaneKind, in sessionId: String) {
        updateLayout(sessionId) { layout in
            if layout.isShowing(kind), let item = layout.items(of: kind).first, let slot = layout.slot(of: item.id) {
                layout.setOpen(slot, false)
            } else {
                layout.show(kind)
            }
        }
    }

    /// The two toolbar buttons.
    func togglePanel(_ slot: PanelSlot, in sessionId: String) {
        updateLayout(sessionId) { $0.toggle(slot) }
    }

    /// Another terminal beside the existing ones (the bottom panel by default).
    func newTerminal(in sessionId: String) {
        updateLayout(sessionId) { layout in
            let slot = layout.items(of: .terminal).last.flatMap { layout.slot(of: $0.id) } ?? .bottom
            layout.add(.terminal, to: slot)
        }
    }

    /// The chat's changes in the main pane, scrolled to `path`.
    func showChanges(_ path: String, in sessionId: String) {
        openDiffTab(in: sessionId, focus: path)
    }

    func resetLayout(_ sessionId: String) {
        updateLayout(sessionId) { $0 = .standard() }
    }

    /// Forget a deleted chat's panels and end its terminals.
    func discardLayout(_ sessionId: String) {
        for item in layout(for: sessionId).items(of: .terminal) { TerminalRegistry.shared.close(paneId: item.id) }
        pendingChangeSelection[sessionId] = nil
        FilesPaneState.shared.discard(sessionId)
        layouts[sessionId] = nil
        try? store.setSetting(layoutKey(sessionId), nil as PanelLayout?)
    }
}

/// Tools the developer chose to always let through in a chat, so the same
/// question isn't asked again and again.
extension AppModel {
    func autoContinue(_ toolName: String, in sessionId: String) {
        autoContinueTools[sessionId, default: []].insert(toolName)
    }

    func shouldAutoContinue(_ toolName: String, in sessionId: String) -> Bool {
        autoContinueTools[sessionId]?.contains(toolName) == true
    }
}
