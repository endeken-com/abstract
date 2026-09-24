import Foundation

/// What a tab shows. Add a case here and register a view for it in the app;
/// the layout logic never needs to change.
public enum PaneKind: String, Codable, Sendable, CaseIterable, Hashable {
    case chat
    case changes
    case files
    case terminal
    /// GitHub pull-request review. Reserved for the GitHub integration.
    case review

    /// Kinds that can be open more than once.
    public var allowsMultiple: Bool { self == .terminal }

    /// Where a kind may live. Reviewing changes needs the tall side panel;
    /// the chat is the window's main area, never a tab.
    public func fits(_ slot: PanelSlot) -> Bool {
        switch self {
        case .chat: false
        case .changes, .review: slot == .side
        default: true
        }
    }

    /// Where a kind opens when no tab of it exists yet.
    public var home: PanelSlot { self == .terminal ? .bottom : .side }
}

public struct PaneItem: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: PaneKind
    public init(id: String = UUID().uuidString, kind: PaneKind) { self.id = id; self.kind = kind }
}

/// The two panels around the chat: one to its right (full height) and one
/// under it.
public enum PanelSlot: String, Codable, Sendable, CaseIterable, Hashable {
    case side
    case bottom

    /// The tab an empty panel gets when it is opened.
    public var defaultKind: PaneKind { self == .side ? .changes : .terminal }
    public var other: PanelSlot { self == .side ? .bottom : .side }
    /// Allowed width (side) or height (bottom), in points.
    public var sizes: ClosedRange<Double> { self == .side ? 280...1100 : 120...800 }
}

/// Tabs in one panel; one of them is showing. Hiding the panel keeps them.
public struct Panel: Codable, Hashable, Sendable {
    public var tabs: [PaneItem]
    public var activeId: String?
    public var isOpen: Bool
    /// Width (side) or height (bottom), in points.
    public var size: Double

    public init(tabs: [PaneItem] = [], activeId: String? = nil, isOpen: Bool = false, size: Double) {
        self.tabs = tabs; self.activeId = activeId ?? tabs.first?.id; self.isOpen = isOpen; self.size = size
    }

    public var active: PaneItem? { tabs.first { $0.id == activeId } ?? tabs.first }
}

/// A chat's panels. A pure value, so every operation is easy to test and to
/// persist.
public struct PanelLayout: Codable, Hashable, Sendable {
    public var side: Panel
    public var bottom: Panel

    public init(side: Panel, bottom: Panel) { self.side = side; self.bottom = bottom }

    /// Changes and Files on the right; the bottom panel waits for a terminal.
    public static func standard() -> PanelLayout {
        PanelLayout(side: Panel(tabs: [PaneItem(kind: .changes), PaneItem(kind: .files)], isOpen: true, size: 460),
                    bottom: Panel(size: 240))
    }

    public subscript(slot: PanelSlot) -> Panel {
        get { slot == .side ? side : bottom }
        set { if slot == .side { side = newValue } else { bottom = newValue } }
    }

    public var items: [PaneItem] { side.tabs + bottom.tabs }
    public func items(of kind: PaneKind) -> [PaneItem] { items.filter { $0.kind == kind } }
    public func slot(of id: String) -> PanelSlot? { PanelSlot.allCases.first { self[$0].tabs.contains { $0.id == id } } }

    /// On screen: the active tab of an open panel.
    public func isShowing(_ kind: PaneKind) -> Bool {
        PanelSlot.allCases.contains { self[$0].isOpen && self[$0].active?.kind == kind }
    }

    /// Show or hide a panel. Opening an empty one gives it its default tab.
    public mutating func toggle(_ slot: PanelSlot) {
        setOpen(slot, !self[slot].isOpen)
    }

    public mutating func setOpen(_ slot: PanelSlot, _ open: Bool) {
        if open, self[slot].tabs.isEmpty { add(slot.defaultKind, to: slot) }
        self[slot].isOpen = open
    }

    /// Bring a tab of `kind` forward: the existing one for single kinds,
    /// otherwise a new tab in `slot` (or where the kind belongs).
    @discardableResult
    public mutating func show(_ kind: PaneKind, in slot: PanelSlot? = nil) -> PaneItem? {
        if let existing = items(of: kind).first, !kind.allowsMultiple || slot == nil || self.slot(of: existing.id) == slot {
            activate(existing.id)
            return existing
        }
        return add(kind, to: slot ?? kind.home)
    }

    /// A new tab, shown at once. Single kinds move their one tab instead;
    /// nil when the kind can't live in that panel.
    @discardableResult
    public mutating func add(_ kind: PaneKind, to slot: PanelSlot, id: String = UUID().uuidString) -> PaneItem? {
        guard kind.fits(slot) else { return nil }
        if !kind.allowsMultiple, let existing = items(of: kind).first {
            move(existing.id, to: slot)
            return existing
        }
        let item = PaneItem(id: id, kind: kind)
        self[slot].tabs.append(item)
        self[slot].activeId = item.id
        self[slot].isOpen = true
        return item
    }

    /// Make a tab the one showing, opening its panel.
    public mutating func activate(_ id: String) {
        guard let slot = slot(of: id) else { return }
        self[slot].activeId = id
        self[slot].isOpen = true
    }

    /// Remove a tab. Its neighbour takes over; the last one closes the panel.
    public mutating func close(_ id: String) {
        guard let slot = slot(of: id), let index = self[slot].tabs.firstIndex(where: { $0.id == id }) else { return }
        var panel = self[slot]
        panel.tabs.remove(at: index)
        if panel.activeId == id { panel.activeId = panel.tabs[safe: min(index, panel.tabs.count - 1)]?.id }
        if panel.tabs.isEmpty { panel.isOpen = false }
        self[slot] = panel
    }

    /// Move a tab to the other panel, if its kind may live there.
    @discardableResult
    public mutating func move(_ id: String, to target: PanelSlot) -> Bool {
        guard let from = slot(of: id), let item = self[from].tabs.first(where: { $0.id == id }), item.kind.fits(target) else { return false }
        if from == target { activate(id); return true }
        close(id)
        self[target].tabs.append(item)
        self[target].activeId = id
        self[target].isOpen = true
        return true
    }

    public mutating func resize(_ slot: PanelSlot, to size: Double) {
        self[slot].size = min(max(size, slot.sizes.lowerBound), slot.sizes.upperBound)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
