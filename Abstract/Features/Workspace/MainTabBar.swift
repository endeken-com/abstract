import SwiftUI
import UniformTypeIdentifiers
import AbstractCore

/// The main pane's tabs, and to their right the chat's editor and git
/// actions. After Paseo's workspace tabs row (Apache-2.0, Copyright (c)
/// 2025-present Mohamed Boudra).
struct MainTabBar: View {
    @Environment(AppModel.self) private var model
    /// The chat the actions act on: the active tab's.
    let session: Session
    /// In the window's title band: no background or rule of its own.
    var inTitleBand = false

    var body: some View {
        HStack(spacing: Space.sm) {
            // The + follows the last tab; when the tabs outgrow the row they
            // scroll, with the + at their end.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 2) {
                    tabs
                    Spacer(minLength: 0)
                }
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        tabs
                    }
                    // The tab showing is always in view.
                    .onChange(of: model.mainTabs.activeId, initial: true) { _, id in
                        guard let id else { return }
                        withAnimation(.snappy(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
                .mask {
                    HStack(spacing: 0) {
                        Rectangle()
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 20)
                    }
                }
            }
            if session.worktreePath != nil {
                HStack(spacing: Space.sm) {
                    // Its files are on the other Mac: no editor here opens them.
                    if !session.id.hasPrefix(RemoteService.mirrorPrefix) { OpenInEditorButton(session: session) }
                    // A standalone chat's folder isn't a repository.
                    if session.projectId != nil { GitActionsButton(session: session) }
                }
                .padding(.trailing, inTitleBand ? 0 : Space.sm)
            }
        }
        .frame(height: inTitleBand ? nil : 36)
        .background(inTitleBand ? Color.clear : Color.btCanvas)
        .overlay(alignment: .bottom) { if !inTitleBand { Hairline() } }
    }

    private var tabs: some View {
        HStack(spacing: 2) {
            ForEach(model.mainTabs.tabs) { tab in
                MainTabChip(tab: tab, active: tab.id == model.mainTabs.activeId).id(tab.id)
            }
            NewTabMenu(session: session)
        }
        .padding(.horizontal, inTitleBand ? 0 : 4)
        .fixedSize()
    }
}

/// One tab: its icon and name, a dot while a file has unsaved edits, and a ×
/// under the pointer. A file opened with a single click is a preview, in
/// italics, until you edit or open it again.
private struct MainTabChip: View {
    @Environment(AppModel.self) private var model
    let tab: MainTab
    let active: Bool
    @State private var hovering = false
    @State private var hoveringClose = false
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 6) {
            icon.frame(width: 14, height: 14)
            Text(title)
                .font(BTFont.ui(12.5, active ? .medium : .regular))
                .italic(tab.preview)
                .foregroundStyle(active ? Color.btText : hovering ? Color.btTextSecondary : Color.btTextTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
            if dirty {
                Circle().fill(Color.btTextTertiary).frame(width: 7, height: 7).help("Unsaved changes")
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 24)
        .frame(minWidth: 96, maxWidth: 180, alignment: .leading)
        .frame(height: 28)
        .overlay(alignment: .trailing) {
            Button { model.closeTab(tab.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(hoveringClose ? Color.btText : Color.btTextTertiary)
                    .frame(width: 18, height: 18)
                    .background(hoveringClose ? Color.btSelection : .clear, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoveringClose = $0 }
            .padding(.trailing, 4)
            .opacity(hovering || active ? 1 : 0)
            .help("Close tab (⌘W)")
        }
        .background(active ? Color.btSelection : hovering ? Color.btHover : .clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(alignment: .leading) {
            if targeted { Capsule().fill(Color.btTextSecondary).frame(width: 2, height: 18).offset(x: -2) }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.keepTab(tab.id) }
        .onTapGesture { model.activateTab(tab.id) }
        .onHover { hovering = $0 }
        .help(help)
        .draggable(tab.id)
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first else { return false }
            model.moveTab(id, to: tab.id)
            return true
        } isTargeted: { targeted = $0 }
        .contextMenu {
            if tab.preview { Button("Keep Open") { model.keepTab(tab.id) } }
            if case let .file(sessionId, path) = tab.kind {
                Button("Copy Path") { copy(model.chatSummary(sessionId)?.worktreePath.map { FileIndex.join($0, path) } ?? path) }
                Button("Copy Relative Path") { copy(path) }
                Button("Show Changes") { model.showChanges(path, in: sessionId) }
            }
            Divider()
            Button("Close") { model.closeTab(tab.id) }
            Button("Close Other Tabs") { model.closeOtherTabs(tab.id) }
                .disabled(model.mainTabs.tabs.count < 2)
        }
    }

    private var session: ChatSummary? { model.chatSummary(tab.kind.sessionId) }

    private var title: String {
        switch tab.kind {
        case .chat: session?.name ?? "Chat"
        case .file(_, let path): (path as NSString).lastPathComponent
        case .diff: "Changes"
        }
    }

    private var help: String {
        let chat = session?.name ?? ""
        return switch tab.kind {
        case .chat: chat
        case .file(_, let path): "\(path) · \(chat)"
        case .diff: "Changes in \(chat)"
        }
    }

    private var dirty: Bool {
        guard case let .file(sessionId, path) = tab.kind, let root = model.chatSummary(sessionId)?.worktreePath else { return false }
        return EditorStore.shared.existing(root: root, path: path, in: sessionId)?.isDirty ?? false
    }

    @ViewBuilder
    private var icon: some View {
        switch tab.kind {
        case .chat:
            if let session { ProviderLogo(providerId: session.providerId, size: 13, monochrome: !active) }
        case .file(_, let path):
            FileIcon(path: path)
        case .diff:
            PaneGlyph(kind: .changes).foregroundStyle(active ? Color.btTextSecondary : Color.btTextTertiary)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// The + at the end of the tabs: a new chat, the changes, or a chat to open beside.
private struct NewTabMenu: View {
    @Environment(AppModel.self) private var model
    let session: Session

    var body: some View {
        let open = Set(model.mainTabs.tabs.compactMap { if case .chat(let id) = $0.kind { id } else { nil } })
        let recent = model.recentChats.filter { !open.contains($0) }.prefix(8)
        ChromeIconMenu(symbol: "plus", help: "New tab", size: 24) {
            Button("New Chat") { model.showNewChat(in: session.projectId, standalone: session.projectId == nil) }
            Button("Changes") { model.openDiffTab(in: session.id) }
                .disabled(session.worktreePath == nil)
            if !recent.isEmpty {
                Section("Open Chat") {
                    ForEach(Array(recent), id: \.self) { id in
                        Button(model.chatNames[id] ?? "Chat") { model.open(id, newTab: true) }
                    }
                }
            }
        }
    }
}

/// What the active tab shows.
struct MainTabContent: View {
    @Environment(AppModel.self) private var model
    let session: Session

    var body: some View {
        switch model.activeTab?.kind {
        case let .file(sessionId, path)? where sessionId == session.id:
            CodeEditorView(sessionId: sessionId, path: path, tabId: model.activeTab!.id).id(path)
        case let .diff(sessionId)? where sessionId == session.id:
            DiffView(sessionId: sessionId)
        default:
            VStack(spacing: 0) {
                ConversationView(session: session)
                // The agent's questions take the reply box's place until answered.
                if let question = model.pendingPermissions(session.id).first(where: { AgentQuestion.isQuestion($0.toolName) }) {
                    QuestionPrompt(sessionId: session.id, request: question).id(question.requestId)
                } else {
                    ComposerView(session: session)
                }
            }
        }
    }
}
