import SwiftUI
import AbstractCore

/// ⌘K: jump to any chat, start anything, act on the current chat.
struct CommandPalette: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    struct Item: Identifiable {
        let id: String
        let section: String
        let title: String
        var subtitle: String? = nil
        var symbol: String? = nil
        var providerId: String? = nil
        var status: SessionStatus? = nil
        var shortcut: [String] = []
        let run: () -> Void
    }

    var body: some View {
        let items = filtered
        ZStack(alignment: .top) {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .onTapGesture { close() }

            VStack(spacing: 0) {
                HStack(spacing: Space.md) {
                    Image(systemName: "magnifyingglass").font(BTFont.ui(15)).foregroundStyle(Color.btTextTertiary)
                    TextField("Search chats, projects, and actions", text: $query)
                        .textFieldStyle(.plain)
                        .font(BTFont.ui(15))
                        .focused($focused)
                        .onSubmit { run(items) }
                    KeyHint("esc")
                }
                .padding(.horizontal, Space.lg)
                .frame(height: 50)

                Divider().overlay(Color.btBorder)

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            if items.isEmpty {
                                Text("No matches").font(.btBody).foregroundStyle(Color.btTextTertiary)
                                    .frame(maxWidth: .infinity).padding(.vertical, Space.xxl)
                            }
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                if index == 0 || items[index - 1].section != item.section {
                                    Text(item.section).font(.btSectionLabel).foregroundStyle(Color.btTextTertiary)
                                        .padding(.horizontal, Space.md).padding(.top, index == 0 ? 4 : Space.md).padding(.bottom, 4)
                                }
                                row(item, highlighted: index == selected)
                                    .id(index)
                                    .onTapGesture { item.run(); close() }
                                    .onHover { if $0 { selected = index } }
                            }
                        }
                        .padding(Space.sm)
                    }
                    .frame(maxHeight: 400)
                    .onChange(of: selected) { _, new in proxy.scrollTo(new) }
                }

                Divider().overlay(Color.btBorder)
                HStack(spacing: Space.lg) {
                    HStack(spacing: 4) { KeyHint("↑"); KeyHint("↓"); Text("navigate") }
                    HStack(spacing: 4) { KeyHint("↩"); Text("open") }
                    Spacer()
                }
                .font(.btCaption)
                .foregroundStyle(Color.btTextTertiary)
                .padding(.horizontal, Space.lg)
                .frame(height: 34)
            }
            .frame(width: 620)
            .btRaised(radius: 16)
            .padding(.top, 90)
        }
        .onAppear { focused = true; selected = 0 }
        .onChange(of: query) { selected = 0 }
        .onKeyPress(.downArrow) { selected = min(selected + 1, max(items.count - 1, 0)); return .handled }
        .onKeyPress(.upArrow) { selected = max(selected - 1, 0); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
    }

    private func row(_ item: Item, highlighted: Bool) -> some View {
        HStack(spacing: Space.md) {
            Group {
                if let status = item.status { StatusDot(status: status) }
                else if let p = item.providerId { ProviderLogo(providerId: p, size: 15) }
                else if let s = item.symbol { Image(systemName: s).font(.system(size: 13, weight: .regular)).foregroundStyle(Color.btTextSecondary) }
            }
            .frame(width: 18)
            Text(item.title).font(.btBody).foregroundStyle(Color.btText).lineLimit(1)
            if let subtitle = item.subtitle {
                Text(subtitle).font(.btCallout).foregroundStyle(Color.btTextTertiary).lineLimit(1)
            }
            Spacer()
            if !item.shortcut.isEmpty { HStack(spacing: 3) { ForEach(item.shortcut, id: \.self) { KeyHint($0) } } }
        }
        .padding(.horizontal, Space.md)
        .frame(height: 36)
        .background(highlighted ? Color.btSelection : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
    }

    private func run(_ items: [Item]) {
        guard items.indices.contains(selected) else { return }
        items[selected].run()
        close()
    }

    private func close() { model.isPaletteOpen = false }

    private var filtered: [Item] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all
            .map { ($0, FuzzyScore.score($0.title.lowercased() + " " + ($0.subtitle ?? "").lowercased(), q)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    private var all: [Item] {
        var items: [Item] = []
        if let s = model.selectedSession {
            items.append(Item(id: "review", section: s.name, title: "Show changes", symbol: "plusminus", shortcut: ["⌘", "D"]) {
                model.openDiffTab(in: s.id)
            })
            items.append(Item(id: "files", section: s.name, title: "Show files", symbol: "doc.text", shortcut: ["⇧", "⌘", "E"]) {
                model.showPane(.files, in: s.id)
            })
            items.append(Item(id: "terminal", section: s.name, title: "Show terminal", symbol: "terminal", shortcut: ["⌃", "`"]) {
                model.showPane(.terminal, in: s.id)
            })
            items.append(Item(id: "reset-layout", section: s.name, title: "Reset layout", symbol: "rectangle.split.2x1") {
                model.resetLayout(s.id)
            })
            if model.isAlive(s.id) {
                items.append(Item(id: "stop", section: s.name, title: "Stop agent", symbol: "stop.fill", shortcut: ["⌘", "."]) { model.stop(s.id) })
            } else {
                items.append(Item(id: "resume", section: s.name, title: s.providerSessionId == nil ? "Restart agent" : "Resume agent", symbol: "arrow.clockwise") { model.resume(s.id) })
            }
            items.append(Item(id: "archive", section: s.name, title: "Archive chat", symbol: "archivebox") { model.setArchived(s.id, true) })
        }
        items.append(Item(id: "settings", section: "App", title: "Settings", symbol: "gearshape", shortcut: ["⌘", ","]) {
            model.isSettingsOpen = true
        })
        items.append(Item(id: "new", section: "Start", title: "New chat", symbol: "square.and.pencil", shortcut: ["⌘", "N"]) {
            model.showNewChatLikeCurrent()
        })
        items.append(Item(id: "new-standalone", section: "Start", title: "New standalone chat", subtitle: "No project, in a folder of its own",
                          symbol: "square.and.pencil") { model.showNewChat(in: nil, standalone: true) })
        for p in model.projects {
            items.append(Item(id: "new-\(p.id)", section: "Start", title: "New chat in \(p.name)", symbol: "square.and.pencil") { model.showNewChat(in: p.id) })
        }
        items.append(Item(id: "add", section: "Start", title: "Add project…", symbol: "folder.badge.plus") { model.isAddingProject = true })
        for s in model.sessions where s.archivedAt == nil {
            items.append(Item(id: "s-\(s.id)", section: "Chats", title: s.name,
                              subtitle: [model.project(s.projectId)?.name, s.status.label].compactMap { $0 }.joined(separator: " · "),
                              status: s.status) { model.open(s.id) })
        }
        items.append(Item(id: "home", section: "Go to", title: "New", symbol: "plus") { model.startNew() })
        items.append(Item(id: "auto", section: "Go to", title: "Automations", symbol: "bolt") { model.destination = .automations })
        items.append(Item(id: "wt", section: "Go to", title: "Worktrees", symbol: "arrow.triangle.branch") { model.destination = .worktrees })
        for theme in ThemeChoice.allCases {
            items.append(Item(id: "theme-\(theme.rawValue)", section: "Appearance", title: "Theme: \(theme.title)", symbol: "circle.lefthalf.filled") {
                UserDefaults.standard.set(theme.rawValue, forKey: "theme")
            })
        }
        return items
    }
}
