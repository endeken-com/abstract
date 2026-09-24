import Foundation

/// What a tab in the main pane shows. Each belongs to a chat: its
/// transcript, a file in its worktree, or its changes.
public enum MainTabKind: Codable, Hashable, Sendable {
    case chat(sessionId: String)
    case file(sessionId: String, path: String)
    case diff(sessionId: String)

    public var sessionId: String {
        switch self {
        case .chat(let id), .file(let id, _), .diff(let id): id
        }
    }
}

public struct MainTab: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: MainTabKind
    /// A file opened with a single click: the next single click replaces it,
    /// until it's kept (double-click, or opened again).
    public var preview: Bool

    public init(id: String = UUID().uuidString, kind: MainTabKind, preview: Bool = false) {
        self.id = id; self.kind = kind; self.preview = preview
    }
}

/// The main pane's tabs, after Paseo's workspace tabs (Apache-2.0,
/// Copyright (c) 2025-present Mohamed Boudra). A pure value, so every
/// operation is easy to test and to persist.
public struct MainTabs: Codable, Hashable, Sendable {
    public private(set) var tabs: [MainTab] = []
    public private(set) var activeId: String?

    public init(tabs: [MainTab] = [], activeId: String? = nil) {
        self.tabs = tabs
        self.activeId = activeId ?? tabs.first?.id
    }

    public var active: MainTab? { tabs.first { $0.id == activeId } }

    /// A chat, from the sidebar: its tab if it has one; otherwise it takes
    /// the place of the chat showing, or a new tab when asked for one.
    @discardableResult
    public mutating func openChat(_ sessionId: String, newTab: Bool = false) -> MainTab {
        if let existing = tabs.first(where: { $0.kind == .chat(sessionId: sessionId) }) {
            activeId = existing.id
            return existing
        }
        let tab = MainTab(kind: .chat(sessionId: sessionId))
        if !newTab, let i = activeIndex, case .chat = tabs[i].kind {
            tabs[i] = tab
        } else {
            insert(tab)
        }
        activeId = tab.id
        return tab
    }

    /// A file in a chat's worktree. A preview replaces the current preview.
    @discardableResult
    public mutating func openFile(_ path: String, in sessionId: String, preview: Bool = true) -> MainTab {
        let kind = MainTabKind.file(sessionId: sessionId, path: path)
        if let i = tabs.firstIndex(where: { $0.kind == kind }) {
            if !preview { tabs[i].preview = false }
            activeId = tabs[i].id
            return tabs[i]
        }
        let tab = MainTab(kind: kind, preview: preview)
        if preview, let i = tabs.firstIndex(where: \.preview) {
            tabs[i] = tab
        } else {
            insert(tab)
        }
        activeId = tab.id
        return tab
    }

    /// A chat's changes; one tab per chat.
    @discardableResult
    public mutating func openDiff(in sessionId: String) -> MainTab {
        if let existing = tabs.first(where: { $0.kind == .diff(sessionId: sessionId) }) {
            activeId = existing.id
            return existing
        }
        let tab = MainTab(kind: .diff(sessionId: sessionId))
        insert(tab)
        activeId = tab.id
        return tab
    }

    public mutating func activate(_ id: String) {
        if tabs.contains(where: { $0.id == id }) { activeId = id }
    }

    /// Keep a preview tab open.
    public mutating func keep(_ id: String) {
        if let i = tabs.firstIndex(where: { $0.id == id }) { tabs[i].preview = false }
    }

    /// Remove a tab; the one to its right takes over, else the one to its left.
    public mutating func close(_ id: String) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: i)
        if activeId == id { activeId = tabs.isEmpty ? nil : tabs[min(i, tabs.count - 1)].id }
    }

    public mutating func closeOthers(_ id: String) {
        tabs.removeAll { $0.id != id }
        activeId = tabs.first?.id
    }

    /// Every tab of a chat that's gone.
    public mutating func removeSession(_ sessionId: String) {
        for tab in tabs where tab.kind.sessionId == sessionId { close(tab.id) }
    }

    /// Drag-reorder: `id` moves to where `target` is.
    public mutating func move(_ id: String, to target: String) {
        guard id != target, let from = tabs.firstIndex(where: { $0.id == id }),
              let to = tabs.firstIndex(where: { $0.id == target }) else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: to)
    }

    private var activeIndex: Int? { tabs.firstIndex { $0.id == activeId } }

    /// New tabs open right after the one showing.
    private mutating func insert(_ tab: MainTab) {
        tabs.insert(tab, at: activeIndex.map { $0 + 1 } ?? tabs.count)
    }
}
