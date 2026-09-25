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
                    message: "Run an agent on a schedule — nightly dependency bumps, issue triage, recurring cleanups. Each run starts a chat you review like any other, or continues one, whose agent can start chats of its own.",
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

private struct AutomationList: View {
    @Environment(AppModel.self) private var model
    let open: (String) -> Void

    var body: some View {
        ScrollView {
            TimelineView(.everyMinute) { context in
                VStack(alignment: .leading, spacing: 0) {
                    AutoSectionLabel(title: model.automations.count == 1 ? "1 automation" : "\(model.automations.count) automations")
                        .padding(.bottom, Space.xs)
                    ForEach(model.automations) { a in
                        AutomationListRow(automation: a, place: place(of: a), now: context.date) {
                            open(a.id)
                        }
                    }
                }
            }
            .automationColumn()
            .padding(.top, Space.xl)
            .padding(.bottom, Space.xxl)
        }
    }

    /// The chat it continues, or where its new chats start.
    private func place(of a: Automation) -> String {
        if a.workspaceMode == .pinned, let chat = model.session(a.pinnedSessionId) { return "in “\(chat.name)”" }
        return model.project(a.projectId)?.name ?? "No project"
    }
}

private struct AutomationListRow: View {
    let automation: Automation
    let place: String
    let now: Date
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                // Active: a solid diamond like a chat's; paused: an outline.
                Group {
                    if automation.enabled { RoundedDiamond().fill(Color.btTextSecondary) }
                    else { RoundedDiamond().stroke(Color.btTextTertiary, lineWidth: 1.2) }
                }
                .frame(width: 9, height: 9)
                    .frame(width: AutoPage.gutter, alignment: .leading)
                    .accessibilityLabel(automation.enabled ? "Active" : "Paused")
                Text(automation.name)
                    .font(.btBodyMedium)
                    .foregroundStyle(Color.btText)
                    .lineLimit(1)
                    .layoutPriority(1)
                Text([AutomationText.schedule(automation), place].joined(separator: " · "))
                    .font(.btCallout)
                    .foregroundStyle(Color.btTextTertiary)
                    .lineLimit(1)
                    .padding(.leading, Space.md)
                Spacer(minLength: Space.lg)
                Text(AutomationText.next(automation, now: now))
                    .font(.btCallout)
                    .foregroundStyle(automation.enabled ? Color.btTextSecondary : Color.btTextTertiary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .frame(height: 38)
            .padding(.horizontal, AutoPage.hang)
        }
        .buttonStyle(RowButtonStyle(cornerRadius: Radius.md))
        .padding(.horizontal, -AutoPage.hang)
    }
}

// MARK: - Page

/// One automation as a document: breadcrumb and run controls, the title,
/// then Settings or Run History. The page edits a draft; Save stores it,
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
        _editingInstructions = State(initialValue: draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var dirty: Bool { existing.map { draft.differs(from: $0) } ?? true }
    private var isActive: Bool { existing?.enabled ?? draft.enabled }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if existing == nil {
                    DescribeAutomation(draft: $draft, focused: $describeFocused) { editingInstructions = false }
                        .padding(.top, Space.lg)
                }
                PageTabs(selection: $tab, items: [
                    .init(value: .settings, title: "Settings"),
                    .init(value: .history, title: "Run history"),
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
            if let old, let new, !draft.differs(from: old) { draft = AutomationDraft(new) }
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
                .help(dirty ? "Start a run of the saved version now; unsaved edits aren't included" : "Start a run now, outside the schedule")
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
                Text("Active").font(.btCallout).foregroundStyle(Color.btTextSecondary)
            }
            .toggleStyle(QuietSwitchStyle())
            .help(isActive ? "Pause: scheduled runs stop until you turn it back on" : "Resume the schedule")
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
            Button("Save", action: save)
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

    private func save() {
        guard dirty, draft.blocker == nil else { return }
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
        } catch {
            saveError = error.localizedDescription
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
    }

    private func runNow() {
        guard let a = existing, !running else { return }
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
    let onDrafted: () -> Void
    @State private var text = ""
    @State private var drafting = false
    @State private var error: String?
    @State private var drafted = false

    private var canDraft: Bool { !drafting && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .bottom, spacing: Space.sm) {
                TextField("Describe it and AI drafts the rest, e.g. “Every weekday at 9, triage new issues in payments-api”",
                          text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.btInput)
                    .lineLimit(1...6)
                    .focused(focused)
                    .returnBreaksLine(commandReturn: run)
                    .padding(.vertical, 5)
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
            .padding(.leading, Field.inset)
            .padding(.trailing, 5)
            .padding(.vertical, 3)
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
