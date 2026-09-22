import SwiftUI
import BacktickCore

/// The editable shape of an automation. The schedule is held as preset
/// parts so switching presets keeps the chosen time.
struct AutomationDraft: Equatable {
    var name = ""
    var prompt = ""
    var projectId: String?
    var preset: SchedulePreset = .daily
    var hour = 9
    var minute = 0
    /// 1 = Sunday … 7 = Saturday.
    var weekday = 2
    var customRule = ""
    var timezone: String
    var providerId: String
    var modelId: String?
    var policy: PermissionPolicy = .autoEdits
    var workspaceMode: WorkspaceMode = .newWorktree
    var pinnedSessionId: String?
    var continueAgentSession = false
    var catchUp = false

    static func new(for model: AppModel) -> AutomationDraft {
        let project = model.projects.first
        let installed = ProviderRegistry.all.first { model.providerStatus[$0.id]?.available == true }?.id
        return AutomationDraft(projectId: project?.id, timezone: model.defaultTimezone,
                               providerId: project?.defaultProviderId ?? installed ?? ProviderRegistry.all.first?.id ?? "claude")
    }

    init(projectId: String?, timezone: String, providerId: String) {
        self.projectId = projectId
        self.timezone = timezone
        self.providerId = providerId
    }

    init(_ a: Automation) {
        let parts = Schedule.preset(of: a.rrule)
        name = a.name
        prompt = a.prompt
        projectId = a.projectId
        preset = parts.preset
        hour = parts.hour
        minute = parts.minute
        weekday = parts.weekday
        customRule = a.rrule
        timezone = a.timezone
        providerId = a.providerId
        modelId = a.model
        policy = a.permissionPolicy
        workspaceMode = a.workspaceMode
        pinnedSessionId = a.pinnedSessionId
        continueAgentSession = a.continueAgentSession
        catchUp = a.catchUp
    }

    var rrule: String {
        guard preset == .custom else { return Schedule.rule(for: preset, hour: hour, minute: minute, weekday: weekday) ?? "" }
        var rule = customRule.trimmingCharacters(in: .whitespacesAndNewlines)
        if rule.uppercased().hasPrefix("RRULE:") { rule = String(rule.dropFirst(6)) }
        return rule
    }

    var isPinned: Bool { projectId != nil && workspaceMode == .pinned }
    var canContinueSession: Bool { isPinned && pinnedSessionId != nil }

    /// DTSTART the saved automation will have: kept while the schedule is
    /// unchanged, otherwise the current minute.
    func dtstart(base: Automation?) -> Date {
        if let base, base.rrule == rrule, base.timezone == timezone { return base.dtstart }
        let now = Date()
        return Date(timeIntervalSinceReferenceDate: (now.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)
    }

    func automation(base: Automation?) -> Automation {
        var a = base ?? Automation(name: "", prompt: "", providerId: providerId, projectId: nil, rrule: rrule, timezone: timezone)
        a.dtstart = dtstart(base: base)
        a.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        a.prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        a.projectId = projectId
        a.rrule = rrule
        a.timezone = timezone
        a.providerId = providerId
        a.model = modelId
        a.permissionPolicy = policy
        a.workspaceMode = isPinned ? .pinned : .newWorktree
        a.pinnedSessionId = isPinned ? pinnedSessionId : nil
        a.continueAgentSession = canContinueSession && continueAgentSession
        a.catchUp = catchUp
        return a
    }
}

/// What the schedule section shows under the controls.
private enum ScheduleCheck {
    case valid(summary: String, upcoming: [Date])
    case invalid(String)

    init(_ draft: AutomationDraft, dtstart: Date) {
        let rule = draft.rrule
        guard !rule.isEmpty else {
            self = .invalid(draft.preset == .custom ? "Enter a rule, e.g. FREQ=WEEKLY;BYDAY=MO;BYHOUR=9;BYMINUTE=0" : "Choose a valid time.")
            return
        }
        do {
            try Schedule.validate(rrule: rule, timezone: draft.timezone)
            let upcoming = try Schedule.preview(rrule: rule, timezone: draft.timezone, dtstart: dtstart, count: 3)
            self = upcoming.isEmpty ? .invalid("This schedule has no upcoming runs.") : .valid(summary: Schedule.describe(rrule: rule), upcoming: upcoming)
        } catch {
            self = .invalid(error.localizedDescription)
        }
    }

    var isValid: Bool { if case .valid = self { true } else { false } }
}

/// Create and edit form, fields in superset's order: labels on the left,
/// native controls on the right, sections set apart by headings and hairlines.
struct AutomationEditor: View {
    @Environment(AppModel.self) private var model
    let existing: Automation?
    var onSaved: (Automation) -> Void
    var onCancel: (() -> Void)? = nil

    @State private var draft: AutomationDraft
    @State private var original: AutomationDraft
    @State private var saveError: String?
    @FocusState private var focus: Field?

    private enum Field: Hashable { case title, prompt }

    init(existing: Automation?, draft: AutomationDraft, onSaved: @escaping (Automation) -> Void, onCancel: (() -> Void)? = nil) {
        self.existing = existing
        self.onSaved = onSaved
        self.onCancel = onCancel
        _draft = State(initialValue: draft)
        _original = State(initialValue: draft)
    }

    var body: some View {
        let check = ScheduleCheck(draft, dtstart: draft.dtstart(base: existing))
        ScrollView {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Space.lg, verticalSpacing: Space.md) {
                AutoFormSection(title: "Task", first: true)
                AutoFormRow(label: "Title") {
                    TextField("Title", text: $draft.name, prompt: Text("e.g. Nightly dependency bump"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .focused($focus, equals: .title)
                        .frame(maxWidth: 420)
                }
                AutoFormRow(label: "Prompt", caption: "Sent to the agent as the first message of every run.") {
                    promptEditor
                }

                AutoFormSection(title: "Where")
                AutoFormRow(label: "Device", caption: "Other devices arrive with LAN pairing.") {
                    Picker("Device", selection: .constant("local")) {
                        Text("This Mac").tag("local")
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(true)
                }
                AutoFormRow(label: "Project", caption: draft.projectId == nil
                            ? "No project: each run gets an empty scratch directory. No worktree, no diff."
                            : "Runs work in worktrees of this repository.") {
                    Picker("Project", selection: $draft.projectId) {
                        ForEach(model.projects) { p in Text(p.name).tag(Optional(p.id)) }
                        Divider()
                        Text("No project").tag(String?.none)
                    }
                    .labelsHidden()
                    .fixedSize()
                }

                AutoFormSection(title: "When")
                scheduleRows(check)

                AutoFormSection(title: "Agent")
                AutoFormRow(label: "Agent", caption: agentMissing
                            ? "\(ProviderRegistry.name(draft.providerId)) wasn't found on this Mac. Set its path in Settings › Agents."
                            : nil,
                            captionTint: .btWarning) {
                    HStack(spacing: Space.sm) {
                        ProviderLogo(providerId: draft.providerId, size: 16)
                        Picker("Agent", selection: $draft.providerId) {
                            ForEach(ProviderRegistry.all, id: \.id) { p in
                                Text(p.name + (model.providerStatus[p.id]?.available == false ? " (not installed)" : "")).tag(p.id)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                AutoFormRow(label: "Model", caption: "Default uses the model set in the agent's own configuration.") {
                    ModelMenu(providerId: draft.providerId, modelId: $draft.modelId)
                        // A model name belongs to one agent; switching agents resets it.
                        .onChange(of: draft.providerId) { _, _ in draft.modelId = nil }
                }
                AutoFormRow(label: "Permissions",
                            caption: draft.policy == .ask
                                ? "Unattended runs can't answer prompts, so “Ask” pauses a run at its first tool call until you answer in its chat."
                                : "\(draft.policy.detail) Unattended runs can't answer prompts: anything that asks pauses the run until you answer in its chat.",
                            captionTint: draft.policy == .ask ? .btWarning : .btTextTertiary) {
                    Picker("Permissions", selection: $draft.policy) {
                        ForEach(PermissionPolicy.allCases, id: \.self) { p in Text(p.title).tag(p) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }

                AutoFormSection(title: "Workspace")
                workspaceRows
            }
            .padding(.horizontal, Space.xl)
            .padding(.top, Space.xl)
            .padding(.bottom, Space.xxl)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) { footer(check) }
        .onChange(of: draft.projectId) { _, _ in
            if let pinned = draft.pinnedSessionId, model.session(pinned)?.projectId != draft.projectId {
                draft.pinnedSessionId = nil
            }
        }
        .onChange(of: draft) { _, _ in saveError = nil }
        .onAppear { if existing == nil { focus = .title } }
    }

    // MARK: Fields

    private var promptEditor: some View {
        TextEditor(text: $draft.prompt)
            .font(.btMono)
            .lineSpacing(3)
            .scrollContentBackground(.hidden)
            .focused($focus, equals: .prompt)
            .padding(.horizontal, 5)
            .padding(.vertical, 8)
            .frame(height: 184)
            .overlay(alignment: .topLeading) {
                if draft.prompt.isEmpty {
                    Text("Update dependencies, run the test suite, and summarise anything that broke.")
                        .font(.btMono)
                        .foregroundStyle(Color.btTextTertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .strokeBorder(focus == .prompt ? Color.accentColor : Color.btBorderStrong, lineWidth: focus == .prompt ? 1 : 0.5)
            )
            .animation(.snappy(duration: 0.14), value: focus)
    }

    private var agentMissing: Bool { model.providerStatus[draft.providerId]?.available == false }

    // MARK: Schedule

    @ViewBuilder
    private func scheduleRows(_ check: ScheduleCheck) -> some View {
        AutoFormRow(label: "Repeats") {
            Picker("Repeats", selection: presetBinding) {
                ForEach(SchedulePreset.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        if draft.preset == .weekly {
            AutoFormRow(label: "On") {
                Picker("Day", selection: $draft.weekday) {
                    ForEach(Self.weekdayOrder, id: \.self) { d in Text(Calendar.current.weekdaySymbols[d - 1]).tag(d) }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
        switch draft.preset {
        case .hourly:
            AutoFormRow(label: "At") {
                HStack(spacing: 6) {
                    TextField("Minute", value: $draft.minute, format: .number)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 44)
                        .onChange(of: draft.minute) { _, m in draft.minute = min(max(m, 0), 59) }
                    Stepper("Minute", value: $draft.minute, in: 0...59).labelsHidden()
                    Text("minutes past every hour").font(.btBody).foregroundStyle(Color.btTextSecondary)
                }
            }
        case .daily, .weekdays, .weekly:
            AutoFormRow(label: "At") {
                DatePicker("Time", selection: timeBinding, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.stepperField)
                    .labelsHidden()
                    .fixedSize()
            }
        case .custom:
            AutoFormRow(label: "Rule", caption: "An RFC 5545 RRULE: FREQ, INTERVAL, BYDAY, BYMONTHDAY, BYHOUR, BYMINUTE, COUNT and UNTIL.") {
                TextField("Rule", text: $draft.customRule, prompt: Text("FREQ=DAILY;BYHOUR=9;BYMINUTE=0"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.btMono)
                    .frame(maxWidth: 420)
            }
        }
        AutoFormRow(label: "Time zone") {
            TimeZoneField(identifier: $draft.timezone)
        }
        GridRow {
            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
            schedulePreview(check)
                .padding(.top, Space.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func schedulePreview(_ check: ScheduleCheck) -> some View {
        switch check {
        case let .valid(summary, upcoming):
            let tz = TimeZone(identifier: draft.timezone) ?? .current
            let elsewhere = tz.identifier != TimeZone.current.identifier
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: "clock").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.accentColor)
                    Text(summary).font(.btBodyMedium).foregroundStyle(Color.btText)
                }
                Text("Next: " + upcoming.map { date in
                    "\(AutomationText.day(date, in: tz)) \(AutomationText.time(date, in: tz))"
                        + (elsewhere ? " (\(AutomationText.time(date)) here)" : "")
                }.joined(separator: "  ·  "))
                    .font(.btCallout)
                    .foregroundStyle(Color.btTextSecondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
        case let .invalid(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.btCallout)
                .foregroundStyle(Color.btRemoved)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    /// Mon … Sun, in Calendar weekday numbers.
    private static let weekdayOrder = [2, 3, 4, 5, 6, 7, 1]

    private var presetBinding: Binding<SchedulePreset> {
        Binding(get: { draft.preset }, set: { new in
            // Carry the current rule into Custom so it can be tweaked.
            if new == .custom, draft.preset != .custom { draft.customRule = draft.rrule }
            if new != .custom, draft.preset == .custom {
                let parts = Schedule.preset(of: draft.rrule)
                draft.hour = parts.hour
                draft.minute = parts.minute
                draft.weekday = parts.weekday
            }
            draft.preset = new
        })
    }

    private var timeBinding: Binding<Date> {
        Binding(get: {
            Calendar.current.date(bySettingHour: draft.hour, minute: draft.minute, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            draft.hour = c.hour ?? draft.hour
            draft.minute = c.minute ?? draft.minute
        })
    }

    // MARK: Workspace

    private var projectSessions: [Session] {
        model.sessions.filter { $0.projectId == draft.projectId && $0.worktreePath != nil && $0.archivedAt == nil }
    }

    @ViewBuilder
    private var workspaceRows: some View {
        GridRow {
            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
            Text(scopeSentence)
                .font(.btBody)
                .foregroundStyle(Color.btTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, Space.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        AutoFormRow(label: "Worktree", caption: draft.projectId == nil ? "Choose a project to give runs a worktree." : nil) {
            Picker("Worktree", selection: $draft.workspaceMode) {
                if draft.projectId == nil {
                    Text("Scratch directory").tag(draft.workspaceMode)
                } else {
                    Text("New worktree per run").tag(WorkspaceMode.newWorktree)
                    Text("Pinned worktree").tag(WorkspaceMode.pinned)
                }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(draft.projectId == nil)
        }
        if draft.isPinned {
            AutoFormRow(label: "Pinned chat", caption: projectSessions.isEmpty ? "This project has no chats with a worktree yet." : nil,
                        captionTint: .btWarning) {
                Picker("Pinned chat", selection: $draft.pinnedSessionId) {
                    Text("Choose a chat…").tag(String?.none)
                    ForEach(projectSessions) { s in Text(s.name).tag(Optional(s.id)) }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(projectSessions.isEmpty)
            }
        }
        AutoFormRow(label: "Agent session", caption: draft.canContinueSession ? nil
                    : draft.isPinned ? "Choose a chat to pin before continuing its session." : "Continuing a session needs a pinned worktree.") {
            Picker("Agent session", selection: continueBinding) {
                Text("Fresh agent each run").tag(false)
                Text("Continue previous session").tag(true)
            }
            .labelsHidden()
            .fixedSize()
            .disabled(!draft.canContinueSession)
        }
        AutoFormRow(label: "Missed runs",
                    caption: "A run missed while Backtick was closed is skipped unless this is on. With it on, the missed run fires once when Backtick opens.") {
            Toggle("Catch up on launch", isOn: $draft.catchUp)
                .toggleStyle(.checkbox)
        }
    }

    private var continueBinding: Binding<Bool> {
        Binding(get: { draft.canContinueSession && draft.continueAgentSession }, set: { draft.continueAgentSession = $0 })
    }

    /// The whole scope in one plain sentence.
    private var scopeSentence: String {
        guard let project = model.project(draft.projectId) else {
            return "Each run starts a fresh agent in an empty scratch directory."
        }
        if draft.isPinned {
            let chat = model.session(draft.pinnedSessionId).map { "“\($0.name)”" } ?? "the pinned chat"
            return draft.canContinueSession && draft.continueAgentSession
                ? "Each run continues the previous agent session in \(chat)'s worktree."
                : "Each run starts a fresh agent in \(chat)'s worktree, with its files as the last run left them."
        }
        return "Each run starts a fresh agent in a new worktree of \(project.name), so runs never collide."
    }

    // MARK: Footer

    /// Why Save is disabled, if it is.
    private func problem(_ check: ScheduleCheck) -> (text: String, isError: Bool)? {
        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return ("Give the automation a title.", false) }
        if draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return ("Write the prompt each run starts with.", false) }
        if !check.isValid { return ("Fix the schedule to save.", true) }
        if draft.isPinned, draft.pinnedSessionId == nil { return ("Choose the chat whose worktree runs pin to.", false) }
        return nil
    }

    private func footer(_ check: ScheduleCheck) -> some View {
        let blocker = problem(check)
        let issue = saveError.map { (text: $0, isError: true) } ?? blocker
        let dirty = existing == nil || draft != original
        return HStack(spacing: Space.sm) {
            if let issue {
                Label(issue.text, systemImage: issue.isError ? "exclamationmark.triangle.fill" : "info.circle")
                    .font(.btCallout)
                    .foregroundStyle(issue.isError ? Color.btRemoved : Color.btTextTertiary)
                    .lineLimit(2)
            } else if existing != nil, !dirty {
                Label("All changes saved", systemImage: "checkmark")
                    .font(.btCallout)
                    .foregroundStyle(Color.btTextTertiary)
            }
            Spacer(minLength: Space.md)
            if existing == nil {
                if let onCancel { Button("Cancel", action: onCancel).buttonStyle(.btGhost).keyboardShortcut(.cancelAction) }
            } else {
                Button("Revert") { draft = original; saveError = nil }
                    .buttonStyle(.btGhost)
                    .disabled(!dirty)
            }
            Button(existing == nil ? "Create Automation" : "Save Changes") { save(check) }
                .buttonStyle(.btPrimary)
                .disabled(blocker != nil || !dirty)
                .keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.md)
        .background(Color.btCanvas)
        .overlay(alignment: .top) { Hairline() }
    }

    private func save(_ check: ScheduleCheck) {
        guard check.isValid else { return }
        do {
            let saved = try model.saveAutomation(draft.automation(base: existing))
            let fresh = AutomationDraft(saved)
            original = fresh
            draft = fresh
            model.flash(existing == nil ? "“\(saved.name)” created" : "Changes saved")
            onSaved(saved)
        } catch {
            saveError = error.localizedDescription
        }
    }
}
