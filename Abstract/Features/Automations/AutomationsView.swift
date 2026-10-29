import SwiftUI
import AbstractCore

/// Scheduled agent runs, modelled on superset.sh automations: a list of
/// them, and a page per automation that reads like a document.
struct AutomationsView: View {
    @Environment(AppModel.self) private var model
    /// The automation whose page is open; empty for the list. Kept across
    /// launches, like the rest of where you were.
    @AppStorage("automations.open") private var openId = ""
    @State private var creating = false

    var body: some View {
        Group {
            if creating {
                AutomationPage(existing: nil, draft: .new(for: model),
                               onClose: { creating = false },
                               onOpen: { id in creating = false; openId = id })
                    .id("new")
            } else if let a = model.automations.first(where: { $0.id == openId }) {
                AutomationPage(existing: a, draft: AutomationDraft(a),
                               onClose: { openId = "" },
                               onOpen: { openId = $0 })
                    .id(a.id)
            } else if model.automations.isEmpty {
                EmptyStateView(
                    symbol: "clock.arrow.2.circlepath",
                    title: "No automations yet",
                    message: "Run an agent on a schedule, or when something happens in a chat. Each run is a chat you can read and reply to.",
                    action: ("New Automation", { creating = true })
                )
            } else {
                AutomationList { openId = $0 }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.btCanvas)
        // The + lives in the window's one toolbar (RootView), which asks here.
        .onChange(of: model.newAutomationRequest) { creating = true }
    }
}

enum AutomationTab: Hashable {
    case settings, history
}

private extension View {
    /// The page's one column: a readable width, centred, one left edge.
    func automationColumn() -> some View {
        frame(maxWidth: AutoPage.width, alignment: .leading)
            .padding(.horizontal, Space.xxl)
            .frame(maxWidth: .infinity)
    }
}

// MARK: - List

/// Every automation, grouped by project in the sidebar's order, under a
/// filter bar whose choices are kept across launches. The bar stays out
/// of the way until a filter is on, the list outgrows a glance, or it is
/// asked for.
private struct AutomationList: View {
    @Environment(AppModel.self) private var model
    let open: (String) -> Void
    @AppStorage("automations.filter.project") private var projectChoice = ""
    @AppStorage("automations.filter.agent") private var agentChoice = ""
    @AppStorage("automations.filter.state") private var stateChoice: AutomationFilter.State = .all
    @State private var filtersShown = false

    /// The stored choices; a project or agent that's gone counts as all.
    private var filter: AutomationFilter {
        var project = AutomationFilter.ProjectChoice(stored: projectChoice)
        if case .only(let id) = project, !model.projects.contains(where: { $0.id == id }) { project = .all }
        let agent = ProviderRegistry.provider(agentChoice)?.id
        return AutomationFilter(project: project, providerId: agent, state: stateChoice)
    }

    var body: some View {
        let filter = filter
        let sections = AutomationListing.sections(model.automations, projects: model.projects,
                                                  sessions: model.sessions, filter: filter)
        ScrollView {
            TimelineView(.everyMinute) { context in
                VStack(alignment: .leading, spacing: 0) {
                    AutoSectionLabel(title: heading(shown: sections.reduce(0) { $0 + $1.automations.count }, filter: filter)) {
                        if filter.isOn || model.automations.count > 8 || filtersShown {
                            filterBar(filter)
                        } else {
                            Button("Filter") { filtersShown = true }
                                .buttonStyle(.bt(.ghost, size: .small))
                                .padding(.trailing, -9)
                        }
                    }
                    if let attention = AutomationSummary.attentionLine(
                        outcomes: model.automations.compactMap { model.summary(of: $0, now: context.date).outcome }) {
                        Text(attention)
                            .font(.btCallout)
                            .foregroundStyle(Color.btAttention)
                            .padding(.top, Space.xxs)
                    }
                    if sections.isEmpty {
                        VStack(alignment: .leading, spacing: Space.md) {
                            Text("No automations match these filters.")
                                .font(.btBody)
                                .foregroundStyle(Color.btTextSecondary)
                            Button("Clear Filters", action: clearFilters)
                                .buttonStyle(.bt(.secondary, size: .small))
                        }
                        .padding(.top, Space.xl)
                    }
                    ForEach(sections) { section in
                        AutoSectionLabel(title: section.project?.name ?? "No project") {
                            Text("\(section.automations.count)")
                                .font(.btCallout)
                                .foregroundStyle(Color.btTextTertiary)
                                .monospacedDigit()
                        }
                        .padding(.top, Space.lg)
                        .padding(.bottom, Space.xs)
                        ForEach(section.automations) { a in
                            AutomationListRow(automation: a, chat: chat(of: a), device: device(of: a), now: context.date,
                                              action: { open(a.id) }, openPage: open)
                        }
                    }
                }
            }
            .automationColumn()
            .padding(.top, Space.xl)
            .padding(.bottom, Space.xxl)
        }
    }

    /// "12 automations", or "3 of 12 automations" while a filter is on.
    private func heading(shown: Int, filter: AutomationFilter) -> String {
        let total = model.automations.count
        let noun = total == 1 ? "automation" : "automations"
        return filter.isOn ? "\(shown) of \(total) \(noun)" : "\(total) \(noun)"
    }

    private func filterBar(_ filter: AutomationFilter) -> some View {
        HStack(spacing: Space.xs) {
            SentenceMenu(title: projectTitle(filter.project), quiet: filter.project == .all) {
                Picker("Project", selection: Binding(get: { filter.project.stored }, set: { projectChoice = $0 })) {
                    Text("All Projects").tag("")
                    ForEach(model.projects) { Text($0.name).tag($0.id) }
                    Text("No Project").tag(AutomationFilter.ProjectChoice.noProject.stored)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            SentenceMenu(title: filter.providerId.map(ProviderRegistry.name) ?? "All agents",
                         logo: filter.providerId, quiet: filter.providerId == nil) {
                Picker("Agent", selection: Binding(get: { filter.providerId ?? "" }, set: { agentChoice = $0 })) {
                    Text("All Agents").tag("")
                    ForEach(ProviderRegistry.all, id: \.id) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            SentenceMenu(title: Self.stateTitle(filter.state), quiet: filter.state == .all) {
                Picker("State", selection: $stateChoice) {
                    ForEach(AutomationFilter.State.allCases, id: \.self) { Text(Self.stateTitle($0)).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
        .padding(.trailing, -Chip.inset)
    }

    private func projectTitle(_ choice: AutomationFilter.ProjectChoice) -> String {
        switch choice {
        case .all: "All projects"
        case .noProject: "No project"
        case .only(let id): model.project(id)?.name ?? "All projects"
        }
    }

    private static func stateTitle(_ state: AutomationFilter.State) -> String {
        switch state {
        case .all: "Any state"
        case .active: "Active"
        case .paused: "Paused"
        case .manual: "Runs by hand only"
        }
    }

    private func clearFilters() {
        projectChoice = ""
        agentChoice = ""
        stateChoice = .all
    }

    /// The chat a pinned automation continues; the section already says the project.
    private func chat(of a: Automation) -> String? {
        guard a.workspaceMode == .pinned, let chat = model.session(a.pinnedSessionId) else { return nil }
        return "in “\(chat.name)”"
    }

    private func device(of a: Automation) -> String? {
        guard let id = a.deviceId else { return nil }
        return "on \(model.remote.paired.first { $0.id == id }?.peer.name ?? "a paired Mac")"
    }
}

private struct AutomationListRow: View {
    @Environment(AppModel.self) private var model
    let automation: Automation
    let chat: String?
    let device: String?
    let now: Date
    let action: () -> Void
    /// Opens another automation's page (a duplicate made here).
    let openPage: (String) -> Void
    @State private var hovering = false
    @State private var running = false
    @FocusState private var focused: Bool

    private var summary: AutomationSummary { model.summary(of: automation, now: now) }
    private var lastChatId: String? {
        model.latestAutomationRuns[automation.id]?.sessionId.flatMap { model.session($0)?.id }
    }
    private var showsActions: Bool { hovering || focused }
    /// Starting a run, or its chat is at work.
    private var working: Bool {
        guard !running else { return true }
        let status = model.session(lastChatId)?.status
        return status == .running || status == .provisioning
    }

    var body: some View {
        let summary = summary
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 0) {
                // Running: the working mark; active: a solid hexagon like a chat's; paused: an outline.
                Group {
                    if working { WorkingMark() }
                    else if automation.enabled { RoundedHexagon().fill(Color.btTextSecondary) }
                    else { RoundedHexagon().stroke(Color.btTextTertiary, lineWidth: 1.2) }
                }
                .frame(width: 9, height: 9)
                .frame(width: AutoPage.gutter, alignment: .leading)
                .accessibilityLabel(working ? "Running" : automation.enabled ? "Active" : "Paused")
                Text(automation.name)
                    .font(.btBodyMedium)
                    .foregroundStyle(automation.enabled ? Color.btText : Color.btTextTertiary)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: Space.lg)
                if showsActions {
                    HStack(spacing: Space.xs) {
                        Button("Run now", action: runNow)
                            .buttonStyle(.bt(.secondary, size: .small))
                            .disabled(running)
                        Button(automation.enabled ? "Pause" : "Resume") {
                            model.setAutomationEnabled(automation.id, !automation.enabled)
                        }
                        .buttonStyle(.bt(.ghost, size: .small))
                    }
                    .padding(.trailing, Space.sm)
                }
                Text(summary.next)
                    .font(.btCallout)
                    .foregroundStyle(automation.enabled ? Color.btTextSecondary : Color.btTextTertiary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            HStack(spacing: 0) {
                Text([summary.schedule, chat, device, ProviderRegistry.name(automation.providerId)]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.btCallout)
                    .foregroundStyle(Color.btTextTertiary)
                    .lineLimit(1)
                    .padding(.leading, AutoPage.gutter)
                Spacer(minLength: Space.lg)
                HStack(spacing: 6) {
                    Circle().fill(summary.outcome?.tint ?? Color.btTextTertiary).frame(width: 6, height: 6)
                    Text(summary.lastRun)
                }
                .font(.btCallout)
                .foregroundStyle(summary.outcome.flatMap { $0.needsAttention ? $0.tint : nil } ?? Color.btTextTertiary)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, AutoPage.hang)
        .contentShape(Rectangle())
        .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            .fill(hovering ? Color.btHover : .clear))
        .padding(.horizontal, -AutoPage.hang)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.12), value: hovering)
        .onTapGesture(perform: action)
        .focusable()
        .focused($focused)
        .onKeyPress(.return) { action(); return .handled }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Open", action)
        .contextMenu {
            Button("Run now", action: runNow).disabled(running)
            Button(automation.enabled ? "Pause" : "Resume") {
                model.setAutomationEnabled(automation.id, !automation.enabled)
            }
            if let lastChatId {
                Button("Open last chat") { model.open(lastChatId) }
            }
            Button("Duplicate") {
                if let copy = model.duplicateAutomation(automation) { openPage(copy.id) }
            }
        }
    }

    private func runNow() {
        guard !running else { return }
        running = true
        Task {
            _ = await model.runAutomationNow(automation)
            running = false
        }
    }
}

// MARK: - Page

/// One automation as a document: breadcrumb and run controls, the title,
/// then Setup or Runs. The page edits a draft; Save stores it,
/// Discard puts it back. Creating one opens the same page, empty.
private struct AutomationPage: View {
    @Environment(AppModel.self) private var model
    /// nil while creating.
    let existing: Automation?
    let onClose: () -> Void
    let onOpen: (String) -> Void

    @State private var draft: AutomationDraft
    @State private var tab: AutomationTab = .settings
    @State private var editingInstructions: Bool
    @State private var runs: [AutomationRun] = []
    @State private var running = false
    @State private var confirmingRun = false
    @State private var describeHidden = false
    @State private var confirmingDelete = false
    @State private var confirmingLeave = false
    @State private var saveError: String?
    @FocusState private var titleFocused: Bool
    @FocusState private var describeFocused: Bool

    init(existing: Automation?, draft: AutomationDraft, onClose: @escaping () -> Void, onOpen: @escaping (String) -> Void) {
        self.existing = existing
        self.onClose = onClose
        self.onOpen = onOpen
        _draft = State(initialValue: draft)
        // Demo snapshots open the Runs tab by setting this before navigating.
        _tab = State(initialValue: UserDefaults.standard.string(forKey: "automations.tab") == "history" ? .history : .settings)
        _editingInstructions = State(initialValue: draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var dirty: Bool { existing.map { draft.differs(from: $0) } ?? true }
    private var isActive: Bool { existing?.enabled ?? draft.enabled }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if existing == nil, !describeHidden {
                    DescribeAutomation(draft: $draft, focused: $describeFocused,
                                       onStartBlank: { describeHidden = true; titleFocused = true }) { editingInstructions = false }
                        .padding(.top, Space.lg)
                }
                PageTabs(selection: $tab, items: [
                    .init(value: .settings, title: "Setup"),
                    .init(value: .history, title: "Runs"),
                ])
                .padding(.top, Space.xl)

                switch tab {
                case .settings:
                    AutomationSettings(draft: $draft, active: isActive, editingInstructions: $editingInstructions)
                        .padding(.top, Space.xl)
                case .history:
                    AutomationRunHistory(automation: existing, runs: runs)
                        .padding(.top, Space.lg)
                }
            }
            .automationColumn()
            .padding(.top, Space.xl)
            .padding(.bottom, 56)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            topBar
                .automationColumn()
                .padding(.top, Space.md)
                .padding(.bottom, Space.xs)
                .background(Color.btCanvas)
        }
        .onAppear {
            reloadRuns()
            // Describing it is the quickest start; the title is a click away.
            if existing == nil { describeFocused = true }
        }
        .onChange(of: model.sessions) { _, _ in reloadRuns() }
        .onChange(of: existing) { old, new in
            reloadRuns()
            // Changed elsewhere (the scheduler, a duplicate, the switch):
            // follow it unless there are edits here to keep.
            if let old, let new {
                if !draft.differs(from: old) {
                    draft = AutomationDraft(new)
                } else if draft.pinnedSessionId == old.pinnedSessionId {
                    // Its first run made it a chat of its own: saving the edits keeps that chat.
                    draft.pinnedSessionId = new.pinnedSessionId
                }
            }
        }
        .onChange(of: draft) { _, _ in saveError = nil }
        .confirmationDialog("Delete “\(existing?.name ?? "")”?", isPresented: $confirmingDelete) {
            Button("Delete Automation", role: .destructive) {
                guard let existing else { return }
                model.deleteAutomation(existing.id)
                model.flash("“\(existing.name)” deleted")
                onClose()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the automation and its run history. The chats its runs used stay.")
        }
        .confirmationDialog("Run with unsaved changes?", isPresented: $confirmingRun) {
            Button("Save and Run") {
                if let saved = save() { startRun(saved) }
            }
            .disabled(draft.blocker != nil)
            Button("Run Saved Version") {
                if let existing { startRun(existing) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your edits haven't been saved. Save them first, or run the version that's saved now.")
        }
        .confirmationDialog("Discard your changes?", isPresented: $confirmingLeave) {
            Button("Discard Changes", role: .destructive, action: onClose)
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text(existing == nil ? "This automation hasn't been saved." : "Edits to “\(existing?.name ?? "")” haven't been saved.")
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: Space.xs) {
            HStack(spacing: 6) {
                BreadcrumbLink(title: "Automations", action: leave)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(Color.btTextTertiary)
                Text(draft.displayName)
                    .font(.btCallout.weight(.medium))
                    .foregroundStyle(Color.btText)
                    .lineLimit(1)
            }
            Spacer(minLength: Space.lg)
            if let existing {
                Button {
                    if let copy = model.duplicateAutomation(existing) { onOpen(copy.id) }
                } label: { Image(systemName: "plus.square.on.square") }
                    .buttonStyle(.icon(size: 26))
                    .help("Duplicate")
                Button { confirmingDelete = true } label: { Image(systemName: "trash") }
                    .buttonStyle(.icon(size: 26))
                    .help("Delete…")
                Button(action: runNow) {
                    HStack(spacing: 6) {
                        if running {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "play.fill").font(.system(size: 8.5, weight: .semibold))
                        }
                        Text("Run now")
                    }
                }
                .buttonStyle(.bt(.secondary, size: .small))
                .disabled(running)
                .padding(.leading, Space.xs)
                .help("Start a run now, outside the schedule")
            }
        }
        .frame(height: 28)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.lg) {
                TextField(AutomationDraft.untitled, text: $draft.name)
                    .textFieldStyle(.plain)
                    .font(BTFont.ui(24, .semibold))
                    .foregroundStyle(Color.btText)
                    .focused($titleFocused)
                    .onSubmit { titleFocused = false }
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Title")
                saveControls
            }
            Toggle(isOn: Binding(get: { isActive }, set: { setActive($0) })) {
                Text(isActive ? "Active" : "Paused").font(.btCallout).foregroundStyle(Color.btTextSecondary)
            }
            .toggleStyle(QuietSwitchStyle())
            .help(isActive ? "Pause: scheduled runs stop until you turn it back on" : "Resume the schedule")
            if existing != nil {
                Text("Takes effect now, even before you save other changes.")
                    .font(.btCaption)
                    .foregroundStyle(Color.btTextTertiary)
            }
            if let existing {
                readBack(existing)
            }
        }
    }

    /// The saved automation in one breath, with a way into its chat.
    private func readBack(_ a: Automation) -> some View {
        let summary = model.summary(of: a)
        let chatId = model.latestAutomationRuns[a.id]?.sessionId.flatMap { model.session($0)?.id }
            ?? a.pinnedSessionId.flatMap { model.session($0)?.id }
        return HStack(spacing: Space.sm) {
            Text(summary.header)
                .font(.btCallout)
                .foregroundStyle(Color.btTextSecondary)
                .lineLimit(1)
            if let chatId {
                Button("Open chat") { model.open(chatId) }
                    .buttonStyle(.bt(.ghost, size: .small))
            }
        }
    }

    private var saveControls: some View {
        let issue: (text: String, isError: Bool)? = saveError.map { ($0, true) } ?? (dirty ? draft.blocker.map { ($0, false) } : nil)
        return HStack(spacing: Space.sm) {
            if let issue {
                Text(issue.text)
                    .font(.btCallout)
                    .foregroundStyle(issue.isError ? Color.btRemoved : Color.btTextTertiary)
                    .lineLimit(2)
                    .frame(maxWidth: 260, alignment: .trailing)
                    .textSelection(.enabled)
            }
            Button("Discard", action: discard)
                .buttonStyle(.bt(.ghost, size: .small))
                .disabled(existing != nil && !dirty)
            Button("Save") { _ = save() }
                .buttonStyle(.bt(.primary, size: .small))
                .disabled(!dirty || draft.blocker != nil)
                .keyboardShortcut("s", modifiers: .command)
        }
        .fixedSize()
    }

    // MARK: Actions

    private func setActive(_ on: Bool) {
        if let existing { model.setAutomationEnabled(existing.id, on) } else { draft.enabled = on }
    }

    @discardableResult
    private func save() -> Automation? {
        guard dirty, draft.blocker == nil else { return nil }
        do {
            let saved = try model.saveAutomation(draft.automation(base: existing))
            saveError = nil
            if existing == nil {
                model.flash("“\(saved.name)” created")
                onOpen(saved.id)
            } else {
                draft = AutomationDraft(saved)
                model.flash("Changes saved")
            }
            return saved
        } catch {
            saveError = error.localizedDescription
            return nil
        }
    }

    private func discard() {
        guard let existing else { onClose(); return }
        draft = AutomationDraft(existing)
        saveError = nil
    }

    /// Back to the list, asking first when there are edits to lose.
    private func leave() {
        let untouched = existing == nil
            && draft.name.trimmingCharacters(in: .whitespaces).isEmpty
            && draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if existing != nil ? dirty : !untouched { confirmingLeave = true } else { onClose() }
    }

    private func reloadRuns() {
        guard let existing else { return }
        let fresh = model.automationRuns(existing.id)
        if fresh != runs { runs = fresh }
        model.refreshLatestAutomationRuns()
    }

    private func runNow() {
        guard let a = existing, !running else { return }
        if dirty { confirmingRun = true } else { startRun(a) }
    }

    private func startRun(_ a: Automation) {
        guard !running else { return }
        running = true
        Task {
            _ = await model.runAutomationNow(a)
            running = false
            tab = .history
            reloadRuns()
        }
    }
}

/// A new automation from a description in plain words: the agent drafts its
/// name, schedule, where it runs and its instructions, for you to review.
private struct DescribeAutomation: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: AutomationDraft
    var focused: FocusState<Bool>.Binding
    let onStartBlank: () -> Void
    let onDrafted: () -> Void
    @State private var text = ""
    @State private var drafting = false
    @State private var error: String?
    @State private var drafted = false
    @State private var collapsed = false

    private var canDraft: Bool { !drafting && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Examples that fill the box: a shape to copy, not stored templates.
    private static let examples = [
        "Every weekday at 9, triage new issues and tell me what needs me",
        "Nightly, update dependencies and fix what breaks",
        "Every Monday, summarise last week's merged work",
    ]

    var body: some View {
        if collapsed {
            HStack(spacing: Space.sm) {
                Text("Drafted — check the setup below")
                    .font(.btCallout)
                    .foregroundStyle(Color.btTextSecondary)
                Button("Draft again") { collapsed = false }
                    .buttonStyle(.bt(.ghost, size: .small))
            }
        } else {
            box
        }
    }

    private var box: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            // A text area like the chat composer: a description is several
            // sentences, so it opens three lines tall, with its button inside.
            VStack(alignment: .leading, spacing: Space.xs) {
                GrowingTextEditor(text: $text, placeholder: "Describe it and AI drafts the rest: what to run, where, how often, and what to report. For example, “Every weekday at 9, triage new issues in payments-api and summarise what needs me.”",
                                  font: .btInput, lineSpacing: 2, lines: 3...12, focused: focused)
                    .returnBreaksLine(commandReturn: run)
                    .padding(.trailing, Field.inset - 5)
                HStack(spacing: Space.sm) {
                    Spacer(minLength: 0)
                    Text("⌘↩ to draft")
                        .font(.btCallout)
                        .foregroundStyle(Color.btTextTertiary)
                    Button(action: run) {
                        HStack(spacing: 5) {
                            if drafting { ProgressView().controlSize(.mini) } else { Image(systemName: "sparkles") }
                            Text(drafting ? "Drafting" : drafted ? "Draft Again" : "Draft with AI")
                        }
                    }
                    .buttonStyle(.bt(.secondary, size: .small))
                    .disabled(!canDraft)
                    .help("Draft the automation from your description (⌘↩)")
                }
            }
            .padding(.leading, Field.inset)
            .padding(.trailing, 5)
            .padding(.top, 8)
            .padding(.bottom, 5)
            .btFieldChrome(focused: focused.wrappedValue)
            if let error {
                Text(error)
                    .font(.btCallout)
                    .foregroundStyle(Color.btRemoved)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else if drafted {
                Text("Drafted from your description. Look it over below, then save.")
                    .font(.btCallout)
                    .foregroundStyle(Color.btTextTertiary)
            }
            FlowRow(spacing: Space.xs, lineSpacing: Space.xs) {
                ForEach(Self.examples, id: \.self) { example in
                    Button(example) { text = example; focused.wrappedValue = true }
                        .buttonStyle(.bt(.secondary, size: .small))
                        .help("Use this example")
                }
            }
            .padding(.top, Space.xxs)
            Button("Start blank instead", action: onStartBlank)
                .buttonStyle(.bt(.ghost, size: .small))
                .padding(.leading, -9)
        }
    }

    private func run() {
        guard canDraft else { return }
        drafting = true
        error = nil
        Task {
            do {
                let proposal = try await model.draftAutomation(text, preferring: draft.providerId)
                let projectId = proposal.project.flatMap { name in model.projects.first { $0.name == name }?.id }
                withAnimation(.snappy(duration: 0.2)) {
                    draft.apply(proposal, projectId: projectId, timezone: model.defaultTimezone)
                }
                drafted = true
                collapsed = true
                onDrafted()
            } catch {
                self.error = error.localizedDescription
            }
            drafting = false
        }
    }
}

/// "Automations" in the breadcrumb: text that brightens on hover.
private struct BreadcrumbLink: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.btCallout)
                .foregroundStyle(hovering ? Color.btText : Color.btTextSecondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Back to all automations")
    }
}
