import SwiftUI
import AppKit
import AbstractCore

/// The reply box. Return sends, Shift-Return breaks the line. While the
/// agent works, Send becomes Queue, beside Steer and Interrupt (or Stop
/// when there's nothing to send).
struct ComposerView: View {
    @Environment(AppModel.self) private var model
    let session: Session
    @State private var draft = ""
    @State private var previewingMarkdown = false
    @State private var markdownHeight: CGFloat = 20
    @State private var sending = false
    @FocusState private var focused: Bool
    /// The `/` menu: the highlighted row, the command whose choices it shows
    /// (nil: the commands), and the draft it was closed on with Esc.
    @State private var slashSelected = 0
    @State private var slashChoosing: AppCommand?
    @State private var slashDismissed: String?

    private var working: Bool { session.status == .running || session.status == .provisioning }
    private var queue: [QueuedMessage] { model.queuedMessages(session.id) }
    /// Mid-turn, a message waits for the turn to end (ABS-103); a chat on a
    /// Mac too old to queue keeps plain Stop.
    private var queueing: Bool { (working || model.turnInProgress(session.id)) && !model.queueUnsupported(session.id) }
    private var hasDraft: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.comments(session.id).isEmpty || !attachments.isEmpty
    }
    /// `abstract` drives the chat: nothing goes to its agent from here.
    private var readOnly: Bool { model.isDrivenFromCLI(session.id) }
    /// Its agent starts once it's set up; its first message is already there.
    private var settingUp: Bool { model.setups[session.id] != nil }
    private var suggestion: String? { working ? nil : model.feed(session.id).suggestion }
    /// The agent's guess at your next message, or what the box is for.
    private var placeholder: String {
        settingUp ? "Setting up the chat…" : readOnly ? "Driven from the command line" : suggestion ?? "Type / for commands"
    }
    /// A review or attachments can go on their own; otherwise there must be something typed.
    private var canSend: Bool {
        !readOnly && !settingUp && !sending && (!remote || model.remote.unreachableMessage(session.id) == nil)
            && (hasDraft || (!queueing && !queue.isEmpty))
    }
    private var attachments: [PromptAttachment] {
        get { model.draftAttachments[session.id] ?? [] }
        nonmutating set { model.draftAttachments[session.id] = newValue.isEmpty ? nil : newValue }
    }
    private var attachmentsBinding: Binding<[PromptAttachment]> {
        Binding(get: { attachments }, set: { attachments = $0 })
    }
    /// Where `gh` finds the repository (on the chat's Mac).
    private var repoRoot: String? { session.worktreePath ?? model.project(session.projectId)?.rootPath }
    /// The paired Mac the chat runs on; nil is this one.
    private var device: String? { RemoteService.split(session.id)?.device }
    private var remote: Bool { session.id.hasPrefix(RemoteService.mirrorPrefix) }
    private var providerCommands: ProviderCommands { ProviderRegistry.provider(session.providerId)?.commands ?? .none }
    /// App commands that make no sense right now.
    private var unavailable: Set<AppCommand> {
        var out = AppCommand.unavailable(working: working, remote: remote)
        if model.efforts(providerId: session.providerId, model: session.model, on: device).levels.isEmpty { out.insert(.effort) }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            if let notice = model.composerNotices[session.id] {
                Text(notice)
                    .font(.btChatCaption)
                    .foregroundStyle(Color.btTextSecondary)
                    .frame(maxWidth: Space.readingWidth, alignment: .leading)
                    .padding(.bottom, Space.sm)
            }
            if let unreachable = model.remote.unreachableMessage(session.id) {
                Text(unreachable)
                    .font(.btChatCaption)
                    .foregroundStyle(Color.btTextSecondary)
                    .frame(maxWidth: Space.readingWidth, alignment: .leading)
                    .padding(.bottom, Space.sm)
            }
            QueuedMessages(session: session, working: queueing, edit: editQueued)
                .padding(.horizontal, Space.lg)
                .padding(.bottom, queue.isEmpty ? 0 : Space.sm)
                .frame(maxWidth: Space.readingWidth + 2 * Space.lg)
            HStack {
                ReviewPill(sessionId: session.id)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.lg)
            .padding(.bottom, model.comments(session.id).isEmpty ? 0 : 6)
            .frame(maxWidth: Space.readingWidth + 2 * Space.lg)
            .animation(.snappy(duration: 0.2), value: model.comments(session.id).count)
            ComposerContext(session: session)
                .padding(.horizontal, Space.lg)
                .padding(.bottom, 6)
                .frame(maxWidth: Space.readingWidth + 2 * Space.lg)
            VStack(alignment: .leading, spacing: 0) {
                if !attachments.isEmpty {
                    AttachmentTray(attachments: attachmentsBinding)
                        .padding(.top, 7)
                        .padding(.trailing, Space.sm)
                }
                VStack(alignment: .leading, spacing: Space.xs) {
                    // The agent's guess at your next message shows as the placeholder;
                    // Tab takes it; Markdown stays literal until Preview is opened.
                    if previewingMarkdown {
                        ScrollView {
                            AgentProse(markdown: draft)
                                .environment(\.proseStyle, ProseStyle(size: .small))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { markdownHeight = $0 }
                        }
                        .frame(height: min(max(markdownHeight, 60), 180))
                        .padding(.top, 10)
                    } else {
                        GrowingTextEditor(text: $draft, placeholder: placeholder, font: BTFont.chat(13.5), lines: 3...10, focused: $focused)
                            .disabled(readOnly || settingUp || sending)
                            .onKeyPress(.tab) {
                                guard draft.isEmpty, let suggestion else { return .ignored }
                                draft = suggestion
                                return .handled
                            }
                            .onKeyPress(.return, phases: [.down, .repeat], action: returnKey)
                            // Last, so it sees these keys before the Tab handler above.
                            // Repeats too: holding ↓ keeps moving down the menu, not the caret.
                            .onKeyPress(keys: [.upArrow, .downArrow, .tab, .escape], phases: [.down, .repeat], action: slashKey)
                            .padding(.top, 10)
                    }

                    HStack(spacing: Space.xs) {
                        AttachmentButtons(repoRoot: repoRoot, sessionId: session.id, attachments: attachmentsBinding)
                            .disabled(readOnly || settingUp)

                        if !draft.isEmpty {
                            Button(previewingMarkdown ? "Edit" : "Preview") {
                                previewingMarkdown.toggle()
                                if !previewingMarkdown { focused = true }
                            }
                            .buttonStyle(.btGhost)
                            .help(previewingMarkdown ? "Edit Markdown" : "Preview Markdown")
                        }
                        Spacer(minLength: Space.sm)

                        // Mid-turn: Queue, and Steer or Interrupt to act on the turn now.
                        if queueing {
                            if hasDraft || !queue.isEmpty {
                                Button("Steer") { act(model.steer) }
                                    .buttonStyle(.btGhost)
                                    .disabled(sending || !model.canSteer(session.id))
                                    .help(model.steerUnavailable(session.id) ?? "Send this into the turn now")
                                Button("Interrupt") { act(model.interrupt) }
                                    .buttonStyle(.btGhost)
                                    .disabled(sending)
                                    .help("Stop this turn and send now")
                            } else {
                                Button("Stop") { model.stop(session.id) }
                                    .buttonStyle(.btGhost)
                                    .disabled(remote && model.remote.unreachableMessage(session.id) != nil)
                                    .help(model.remote.unreachableMessage(session.id) ?? "Stop the agent (⌘.)")
                            }
                            if hasDraft {
                                Button("Queue", action: send)
                                    .buttonStyle(.btPrimary)
                                    .disabled(!canSend)
                                    .help(model.remote.unreachableMessage(session.id) ?? "Send when this turn ends (Return)")
                            }
                        } else if working {
                            Button("Stop") { model.stop(session.id) }
                                .buttonStyle(.btGhost)
                                .disabled(remote && model.remote.unreachableMessage(session.id) != nil)
                                .help(model.remote.unreachableMessage(session.id) ?? "Stop the agent (⌘.)")
                        } else {
                            Button("Send", action: send)
                                .buttonStyle(.btPrimary)
                                .disabled(!canSend)
                                .help(model.remote.unreachableMessage(session.id) ?? "Send (Return)")
                                .animation(.snappy(duration: 0.15), value: canSend)
                        }
                    }
                }
            }
            .padding(.leading, Space.lg)
            .padding(.trailing, 7)
            .padding(.vertical, 5)
            .btFieldChrome(focused: focused)
            .attachmentInput(attachmentsBinding, focused: focused)
            .overlay(alignment: .top) {
                let items = slashItems
                if !items.isEmpty {
                    let title = slashChoosing.map { "/" + $0.name }
                    SlashMenu(title: title, items: items, selected: min(slashSelected, items.count - 1), hover: { slashSelected = $0 })
                        // Just above the box. An alignment guide doesn't move an overlay; an offset does.
                        .offset(y: -(SlashMenu.height(rows: items.count, titled: title != nil) + 6))
                }
            }
            .onChange(of: draft) {
                slashSelected = 0
                slashChoosing = nil
                // Esc closes the menu for that draft only.
                if draft != slashDismissed { slashDismissed = nil }
            }
            .frame(maxWidth: Space.readingWidth + 2 * Space.lg)

            // What the agent runs with, each one a menu to change it.
            Group {
                if readOnly {
                    Label("Its agent is working from the command line. The chat is yours when this turn ends, or Stop it now.",
                          systemImage: "terminal")
                        .font(.btChatCaption)
                        .foregroundStyle(Color.btTextTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                } else {
                    AgentControls(session: session, attachments: attachmentsBinding)
                }
            }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.lg - 6) // the menus' own padding lines their text up
                .padding(.top, 4)
            .frame(maxWidth: Space.readingWidth + 2 * Space.lg)
        }
        // The box hangs one inset past the prose column on each side, so the
        // text inside it starts exactly where the agent's text does.
        .padding(.horizontal, Space.xxl - Space.lg)
        .padding(.top, Space.sm)
        .padding(.bottom, Space.md)
        .frame(maxWidth: .infinity)
        .background(alignment: .top) {
            LinearGradient(colors: [Color.btCanvas.opacity(0), Color.btCanvas], startPoint: .top, endPoint: .bottom)
                .frame(height: 24)
                .offset(y: -24)
                .allowsHitTesting(false)
        }
        .onAppear { focused = true }
        // Lines quoted from Files or Review wait here for your question.
        .onChange(of: model.pendingDrafts[session.id], initial: true) { _, pending in
            guard let pending else { return }
            draft = draft.isEmpty ? pending : pending + draft
            model.pendingDrafts[session.id] = nil
            focused = true
        }
        // Closing ⌘F's bar hands the keyboard back here.
        .onChange(of: model.feed(session.id).find.closings) { focused = true }
    }

    private func send() {
        // A whole app command (`/model`) runs here instead of going to the agent.
        if !readOnly, !settingUp,
           let command = SlashCommands.appCommand(forDraft: draft, provider: providerCommands, excluding: unavailable) {
            run(command)
            return
        }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        let pending = attachments
        let message = model.messageWithReview(session.id, text: text)
        if remote {
            sending = true
            Task {
                do {
                    try await model.sendRemoteFollowUp(session.id, text: message, attachments: pending)
                    sent()
                } catch { model.flash(error.localizedDescription, isError: true) }
                sending = false
            }
            return
        }
        do {
            // The review goes with the message, after it, then the attachments.
            // Leave the draft and attachments in place until delivery succeeds.
            try model.sendFollowUp(session.id, text: message, attachments: pending)
            sent()
        } catch {
            model.flash(error.localizedDescription, isError: true)
        }
    }

    /// Steer or Interrupt, with what's typed.
    private func act(_ action: @escaping (String, String, [PromptAttachment]) async throws -> Void) {
        guard !sending, !readOnly, !settingUp else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = hasDraft ? model.messageWithReview(session.id, text: text) : ""
        let pending = attachments
        sending = true
        Task {
            do {
                try await action(session.id, message, pending)
                if !message.isEmpty || !pending.isEmpty { sent() }
            } catch { model.flash(error.localizedDescription, isError: true) }
            sending = false
        }
    }

    /// A queued message back in the box, ahead of anything typed since.
    private func editQueued(_ message: QueuedMessage) {
        Task {
            guard let message = await model.takeQueued(session.id, id: message.id) else {
                model.flash("That message has already been sent.")
                return
            }
            draft = draft.isEmpty ? message.text : message.text + "\n\n" + draft
            attachments += message.attachments
            previewingMarkdown = false
            focused = true
        }
    }

    private func sent() {
        model.composerNotices[session.id] = nil
        draft = ""
        previewingMarkdown = false
        attachments = []
        RevundService.shared.userWrote(session.id)
        model.keepCommentsAsNotes(session.id)
        model.discardComments(session.id)
    }

    // MARK: - The / menu

    /// The `/` menu's rows: a command's choices, else the commands matching the draft.
    private var slashItems: [SlashItem] {
        if let slashChoosing { return choices(slashChoosing) }
        guard !readOnly, !settingUp, draft != slashDismissed, let query = SlashCommands.query(forDraft: draft) else { return [] }
        return SlashCommands.entries(query: query, agentCommands: model.agentCommands(session),
                                     provider: providerCommands, excluding: unavailable)
            .map(item)
    }

    private func item(_ entry: SlashEntry) -> SlashItem {
        switch entry {
        case .app(let command):
            SlashItem(id: "app:" + command.name, title: "/" + command.name, detail: command.detail) { run(command) }
        case .agent(let command):
            // It goes to the agent as typed; what follows is up to you.
            SlashItem(id: "agent:" + command.name, title: "/" + command.name, hint: command.argumentHint,
                      detail: command.detail, tag: command.kind == .skill ? "Skill" : "Command") { draft = "/" + command.name + " " }
        }
    }

    /// A command that needs a choice lists it in the menu; the rest run now.
    private func run(_ command: AppCommand) {
        switch command {
        case .agent, .model, .effort, .mode:
            slashSelected = choices(command).firstIndex { $0.checked == true } ?? 0
            slashChoosing = command
            return
        case .stop: model.stop(session.id)
        case .diff: model.openDiffTab(in: session.id)
        case .rename: model.renamingSessionId = session.id
        case .attach: AttachmentActions.chooseFiles { attachments += $0 }
        case .tasks:
            if model.backgroundTasks(session.id).isEmpty { model.flash("No background tasks") }
            else { model.tasksOpen = TasksFocus(sessionId: session.id) }
        }
        draft = ""
    }

    /// The same choices as the menus under the box.
    private func choices(_ command: AppCommand) -> [SlashItem] {
        func choice(_ id: String, _ title: String, detail: String? = nil, checked: Bool, _ apply: @escaping () -> Void) -> SlashItem {
            SlashItem(id: id, title: title, detail: detail, checked: checked) {
                apply()
                slashChoosing = nil
                draft = ""
            }
        }
        switch command {
        case .agent:
            return model.pickableAgents(on: device, keeping: session.providerId).map { p in
                choice(p.id, p.name, checked: p.id == session.providerId) {
                    model.setAgent(session.id, providerId: p.id, model: nil, effort: nil)
                }
            }
        case .model:
            let catalog = model.models(for: session.providerId, on: device)
            let setModel = { (new: String?) in
                let levels = model.efforts(providerId: session.providerId, model: new, on: device).levels
                model.setAgent(session.id, providerId: session.providerId, model: new,
                               effort: session.effort.flatMap { levels.contains($0) ? $0 : nil })
            }
            var items = [choice("default", model.defaultModelName(for: session.providerId, on: device).map { "Default (\($0))" } ?? "Default",
                                checked: session.model == nil) { setModel(nil) }]
            items += (catalog.models + catalog.versions).map { option in
                choice(option.id, option.label, detail: option.detail, checked: session.model == option.id) { setModel(option.id) }
            }
            if let custom = session.model, catalog.option(custom) == nil {
                items.append(choice(custom, custom, checked: true) {})
            }
            return items
        case .effort:
            let efforts = model.efforts(providerId: session.providerId, model: session.model, on: device)
            let setEffort = { (new: String?) in
                model.setAgent(session.id, providerId: session.providerId, model: session.model, effort: new)
            }
            return [choice("default", efforts.defaultLevel.map { "Default (\(ModelOption.effortTitle($0)))" } ?? "Default",
                           checked: session.effort == nil) { setEffort(nil) }]
                + efforts.levels.map { level in
                    choice(level, ModelOption.effortTitle(level), checked: session.effort == level) { setEffort(level) }
                }
        case .mode:
            return PermissionPolicy.allCases.map { policy in
                choice(policy.rawValue, policy.title,
                       detail: ProviderRegistry.provider(session.providerId)?.permissionDetail(policy) ?? policy.detail,
                       checked: session.permissionPolicy == policy) { model.setPolicy(session.id, policy) }
            }
        case .stop, .diff, .rename, .attach, .tasks:
            return []
        }
    }

    /// ↑ ↓ move through the `/` menu, Tab picks, Esc steps back.
    /// Everything else, and every key while it's closed, goes on to the box.
    private func slashKey(_ press: KeyPress) -> KeyPress.Result {
        let items = slashItems
        guard !items.isEmpty, !press.modifiers.contains(.command) else { return .ignored }
        // An input method uses these keys for the text it is composing.
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.hasMarkedText() { return .ignored }
        let current = min(slashSelected, items.count - 1)
        switch press.key {
        case .upArrow: slashSelected = (current - 1 + items.count) % items.count
        case .downArrow: slashSelected = (current + 1) % items.count
        case .tab: items[current].run()
        case .escape:
            if slashChoosing != nil { slashChoosing = nil; slashSelected = 0 } else { slashDismissed = draft }
        default: return .ignored
        }
        return .handled
    }

    private func returnKey(_ press: KeyPress) -> KeyPress.Result {
        let editor = NSApp.keyWindow?.firstResponder as? NSTextView
        let items = slashItems
        switch ChatComposerReturnAction.resolve(
            isComposing: editor?.hasMarkedText() == true, slashMenuOpen: !items.isEmpty,
            shift: press.modifiers.contains(.shift), command: press.modifiers.contains(.command),
            option: press.modifiers.contains(.option), control: press.modifiers.contains(.control),
            repeated: press.phase == .repeat
        ) {
        case .system:
            return .ignored
        case .consume:
            return .handled
        case .newline:
            let edit = ChatComposerDraftEdit.insertingNewline(into: draft, selectedRange: editor?.selectedRange())
            draft = edit.text
            if let editor {
                DispatchQueue.main.async { [weak editor] in editor?.setSelectedRange(edit.selection) }
            }
        case .selectSlashItem:
            items[min(slashSelected, items.count - 1)].run()
        case .send:
            send()
        }
        return .handled
    }
}

/// Above the reply box: the branch the agent works on and how much it has
/// changed so far. The counts open Review.
private struct ComposerContext: View {
    @Environment(AppModel.self) private var model
    let session: Session
    @State private var totals: (additions: Int, deletions: Int)?

    var body: some View {
        HStack(spacing: Space.sm) {
            if let line = BranchLine(session: session) {
                Label {
                    Text(line.branch)
                } icon: {
                    Image(nsImage: Octicon.gitBranch).renderingMode(.template).resizable().frame(width: 11, height: 11)
                }
                .labelStyle(.titleAndIcon)
                .font(.btChatCaption)
                .foregroundStyle(Color.btTextTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(line.help)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(line.accessibilityLabel)
                .contextMenu {
                    Button("Copy Branch Name") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(line.branch, forType: .string)
                        model.flash("Copied")
                    }
                }
            }
            Spacer(minLength: Space.md)
            BackgroundTasksChip(sessionId: session.id)
            RevundComposerStatus(sessionId: session.id)
            if let totals, totals.additions + totals.deletions > 0 {
                Button { model.openDiffTab(in: session.id) } label: {
                    DiffCounts(additions: totals.additions, deletions: totals.deletions, hideZeros: true)
                }
                .buttonStyle(.plain)
                .help("Review changes")
            }
        }
        .frame(height: 18)
        // Re-read after each tool result and at each status change; a short
        // pause lets bursts of edits settle into one read.
        .task(id: "\(session.status.rawValue)-\(resultCount)") {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, case .ready(let context) = model.diffAvailability(session.id) else { totals = nil; return }
            let files = (try? await Diff.collectUncommitted(context.reader, worktree: context.worktree, exclude: context.exclude)) ?? []
            totals = (files.reduce(0) { $0 + $1.additions }, files.reduce(0) { $0 + $1.deletions })
        }
    }

    private var resultCount: Int { model.feed(session.id).toolResults }
}

/// The chat's agent, model and effort as quiet menus, plus how much it may do.
/// Changing one applies from the next message.
private struct AgentControls: View {
    @Environment(AppModel.self) private var model
    let session: Session
    @Binding var attachments: [PromptAttachment]

    var body: some View {
        HStack(spacing: 2) {
            AttachUploadButton(attachments: $attachments)
            let device = RemoteService.split(session.id)?.device
            CompactMenu(title: ProviderRegistry.name(session.providerId), logo: session.providerId) {
                Picker("Agent", selection: Binding(get: { session.providerId }, set: { new in
                    model.setAgent(session.id, providerId: new, model: nil, effort: nil)
                })) {
                    ForEach(model.pickableAgents(on: device, keeping: session.providerId), id: \.id) { p in Text(p.name).tag(p.id) }
                }
                .pickerStyle(.inline)
                Divider()
                Text("Another agent gets a summary of this chat with your next message.")
            }
            ModelMenu(providerId: session.providerId, modelId: Binding(get: { session.model }, set: { new in
                let levels = model.efforts(providerId: session.providerId, model: new, on: device).levels
                model.setAgent(session.id, providerId: session.providerId, model: new,
                               effort: session.effort.flatMap { levels.contains($0) ? $0 : nil })
            }), device: device)
            EffortMenu(providerId: session.providerId, modelId: session.model, effort: Binding(get: { session.effort }, set: { new in
                model.setAgent(session.id, providerId: session.providerId, model: session.model, effort: new)
            }), device: device)
            CompactMenu(title: session.permissionPolicy.title) {
                Picker("Mode", selection: Binding(get: { session.permissionPolicy }, set: { model.setPolicy(session.id, $0) })) {
                    ForEach(PermissionPolicy.allCases, id: \.self) { p in Text(p.title).tag(p) }
                }
                .pickerStyle(.inline)
                Divider()
                Text(ProviderRegistry.provider(session.providerId)?.permissionDetail(session.permissionPolicy)
                     ?? session.permissionPolicy.detail)
            }
            .help("How much the agent may do without asking")
            if model.needsRelaunch.contains(session.id) {
                // Restarting would end them, so the change waits for them.
                Text(model.runningBackgroundTasks(session.id) > 0 ? "· applies once background tasks end" : "· applies to your next message")
                    .font(.btChatCaption)
                    .foregroundStyle(Color.btTextTertiary)
            }
        }
        .lineLimit(1)
    }
}
