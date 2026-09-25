import SwiftUI
import AppKit

/// One line of a `secondaryClickMenu`.
enum MenuEntry {
    case action(String, enabled: Bool = true, () -> Void)
    case divider
}

extension View {
    /// A right-click (or Control-click) menu that also works in the window's
    /// title band: there `.contextMenu` never fires, and the toolbar shows its
    /// own Icon and Text / Icon Only menu instead.
    func secondaryClickMenu(_ entries: [MenuEntry]) -> some View {
        overlay(SecondaryClickMenu(entries: entries))
    }
}

private struct SecondaryClickMenu: NSViewRepresentable {
    let entries: [MenuEntry]

    func makeNSView(context: Context) -> MenuView { MenuView() }
    func updateNSView(_ view: MenuView, context: Context) { view.entries = entries }

    final class MenuView: NSView {
        var entries: [MenuEntry] = []
        /// The open menu's actions, by item tag.
        private var actions: [() -> Void] = []

        /// Only secondary clicks land here; hover, clicks and drags go on to SwiftUI.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent, Self.isSecondary(event) else { return nil }
            return super.hitTest(point)
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            let menu = NSMenu()
            menu.autoenablesItems = false
            actions = []
            for entry in entries {
                switch entry {
                case .divider: menu.addItem(.separator())
                case let .action(title, enabled, action):
                    let item = NSMenuItem(title: title, action: #selector(fire(_:)), keyEquivalent: "")
                    item.target = self
                    item.tag = actions.count
                    item.isEnabled = enabled
                    actions.append(action)
                    menu.addItem(item)
                }
            }
            return menu.items.isEmpty ? nil : menu
        }

        /// A Control-click arrives as a left click.
        override func mouseDown(with event: NSEvent) {
            guard let menu = menu(for: event) else { return }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }

        @objc private func fire(_ item: NSMenuItem) { actions[item.tag]() }

        private static func isSecondary(_ event: NSEvent) -> Bool {
            switch event.type {
            case .rightMouseDown, .rightMouseUp: true
            case .leftMouseDown: event.modifierFlags.contains(.control)
            default: false
            }
        }
    }
}
