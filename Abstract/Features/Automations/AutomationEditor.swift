import SwiftUI
import AbstractCore

// MARK: - Draft

/// One trigger as the page edits it: the schedule held as preset parts, so
/// switching presets keeps the chosen time.
struct TriggerDraft: Identifiable, Equatable {
    let id: String
    var preset: SchedulePreset = .daily
    var hour = 9
    var minute = 0
    /// 1 = Sunday … 7 = Saturday.
    var weekday = 2
    var customRule = ""
    var timezone: String
    /// The saved trigger this edits. Its DTSTART is kept while the rule and
    /// zone are unchanged.
    let base: AutomationTrigger?

    init(timezone: String) {
        id = UUID().uuidString
        self.timezone = timezone
        base = nil
    }

    init(_ t: AutomationTrigger) {
        let parts = Schedule.preset(of: t.rrule)
        id = t.id
        preset = parts.preset
        hour = parts.hour
        minute = parts.minute
        weekday = parts.weekday
        customRule = t.rrule
        timezone = t.timezone
        base = t
    }

    var rrule: String {
        guard preset == .custom else { return Schedule.rule(for: preset, hour: hour, minute: minute, weekday: weekday) ?? "" }
        var rule = customRule.trimmingCharacters(in: .whitespacesAndNewlines)
        if rule.uppercased().hasPrefix("RRULE:") { rule = String(rule.dropFirst(6)) }
        return rule
    }

    func dtstart(now: Date = Date()) -> Date {
        if let base, base.rrule == rrule, base.timezone == timezone { return base.dtstart }
        return Date(timeIntervalSinceReferenceDate: (now.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)
    }

    func trigger(now: Date = Date()) -> AutomationTrigger {
        AutomationTrigger(id: id, rrule: rrule, timezone: timezone, dtstart: dtstart(now: now))
    }

    /// The same schedule as `t`, however the page happens to hold it.
    func matches(_ t: AutomationTrigger) -> Bool {
        t.id == id && t.rrule == rrule && t.timezone == timezone
    }

    /// Carries the current rule into Custom so it can be tweaked, and the
    /// time back out of it.
    mutating func setPreset(_ new: SchedulePreset) {
        if new == .custom, preset != .custom { customRule = rrule }
        if new != .custom, preset == .custom {
            let parts = Schedule.preset(of: rrule)
            hour = parts.hour
            minute = parts.minute
            weekday = parts.weekday
        }
        preset = new
    }
}

/// Whether a trigger can run, and when it next does.
enum TriggerCheck: Equatable {
    case upcoming(Date)
    /// Valid, with no occurrences left (COUNT or UNTIL reached).
    case finished
    case invalid(String)

    init(_ t: TriggerDraft, now: Date = Date()) {
        let rule = t.rrule
        guard !rule.isEmpty else {
            self = .invalid(t.preset == .custom ? "Enter a rule, e.g. FREQ=WEEKLY;BYDAY=MO;BYHOUR=9;BYMINUTE=0" : "Choose a valid time.")
            return
        }
        do {
            try Schedule.validate(rrule: rule, timezone: t.timezone)
            let next = try Schedule.nextOccurrence(rrule: rule, timezone: t.timezone, dtstart: t.dtstart(now: now), after: now)
            self = next.map(TriggerCheck.upcoming) ?? .finished
        } catch {
            self = .invalid(error.localizedDescription)
        }
    }

    var isValid: Bool { if case .invalid = self { false } else { true } }
}

/// The editable shape of an automation. Save turns it back into one.
struct AutomationDraft: Equatable {
    static let untitled = "Untitled automation"

    var name = ""
    var prompt = ""
    var projectId: String?
    var triggers: [TriggerDraft]
    var providerId: String
    var modelId: String?
    var effort: String?
    var policy: PermissionPolicy = .autoEdits
    var workspaceMode: WorkspaceMode = .newWorktree
    var pinnedSessionId: String?
    var continueAgentSession = false
    var catchUp = false
    /// Only read for a new automation: an existing one's switch saves at once.
    var enabled = true

    static func new(for model: AppModel) -> AutomationDraft {
        let project = model.projects.first
        let installed = ProviderRegistry.all.first { model.providerStatus[$0.id]?.available == true }?.id
        return AutomationDraft(projectId: project?.id, triggers: [TriggerDraft(timezone: model.defaultTimezone)],
                               providerId: project?.defaultProviderId ?? installed ?? ProviderRegistry.all.first?.id ?? "claude")
    }

    init(projectId: String?, triggers: [TriggerDraft], providerId: String) {
        self.projectId = projectId
        self.triggers = triggers
        self.providerId = providerId
    }

    init(_ a: Automation) {
        name = a.name
        prompt = a.prompt
        projectId = a.projectId
        triggers = a.triggers.map(TriggerDraft.init)
        providerId = a.providerId
        modelId = a.model
        effort = a.effort
        policy = a.permissionPolicy
        workspaceMode = a.workspaceMode
        pinnedSessionId = a.pinnedSessionId
        continueAgentSession = a.continueAgentSession
        catchUp = a.catchUp
        enabled = a.enabled
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.untitled : trimmed
    }

    var isPinned: Bool { projectId != nil && workspaceMode == .pinned }
    var canContinueSession: Bool { isPinned && pinnedSessionId != nil }

    func automation(base: Automation?, now: Date = Date()) -> Automation {
        var a = base ?? Automation(name: "", prompt: "", providerId: providerId, projectId: nil, triggers: [], enabled: enabled)
        a.name = displayName
        a.prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        a.projectId = projectId
        a.triggers = triggers.map { $0.trigger(now: now) }
        a.providerId = providerId
        a.model = modelId
        a.effort = effort
        a.permissionPolicy = policy
        a.workspaceMode = isPinned ? .pinned : .newWorktree
        a.pinnedSessionId = isPinned ? pinnedSessionId : nil
        a.continueAgentSession = canContinueSession && continueAgentSession
        a.catchUp = catchUp
        return a
    }

    /// Whether saving would change `a`. Compares what would be stored, not
    /// how the page holds it, so switching a preset away and back is no change.
    func differs(from a: Automation) -> Bool {
        let saved = automation(base: a)
        return saved.name != a.name || saved.prompt != a.prompt || saved.projectId != a.projectId
            || saved.providerId != a.providerId || saved.model != a.model || saved.effort != a.effort
            || saved.permissionPolicy != a.permissionPolicy || saved.workspaceMode != a.workspaceMode
            || saved.pinnedSessionId != a.pinnedSessionId || saved.continueAgentSession != a.continueAgentSession
            || saved.catchUp != a.catchUp
            || triggers.count != a.triggers.count || zip(triggers, a.triggers).contains { !$0.matches($1) }
    }

    /// Why Save is off, in a few words.
    var blocker: String? {
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Instructions are empty" }
        if triggers.contains(where: { !TriggerCheck($0).isValid }) { return "A trigger needs fixing" }
        if isPinned, pinnedSessionId == nil { return "Choose the chat to run in" }
        return nil
    }
}

// MARK: - Settings tab

/// Triggers, where runs happen, and the instructions: one quiet column.
struct AutomationSettings: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: AutomationDraft
    /// Whether runs are on. Trigger rows say "Paused" instead of a next run otherwise.
    let active: Bool
    @Binding var editingInstructions: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AutoSectionLabel(title: "Triggers")
            TriggerList(triggers: $draft.triggers, catchUp: $draft.catchUp, active: active,
                        defaultTimezone: model.defaultTimezone)
                .padding(.top, Space.xxs)

            ScopeSentence(draft: $draft)
                .padding(.top, Space.xl)

            AutoSectionLabel(title: "Instructions") {
                Button(editingInstructions ? "Done" : "Edit") {
                    withAnimation(.snappy(duration: 0.18)) { editingInstructions.toggle() }
                }
                .buttonStyle(.bt(.ghost, size: .small))
                .padding(.trailing, -9)
                .help(editingInstructions ? "Show the instructions as they read" : "Edit the instructions as Markdown")
            }
            .padding(.top, Space.xxl)
            InstructionsView(prompt: $draft.prompt, editing: $editingInstructions)
                .padding(.top, Space.sm)
        }
    }
}

// MARK: Triggers

private struct TriggerList: View {
    @Binding var triggers: [TriggerDraft]
    @Binding var catchUp: Bool
    let active: Bool
    let defaultTimezone: String

    var body: some View {
        // Once a minute, so "today" turns into "tomorrow" on its own.
        TimelineView(.everyMinute) { context in
            VStack(alignment: .leading, spacing: 0) {
                ForEach($triggers) { $trigger in
                    TriggerRow(trigger: $trigger, active: active, now: context.date) {
                        let id = trigger.id
                        withAnimation(.snappy(duration: 0.18)) { triggers.removeAll { $0.id == id } }
                    }
                }
                AddTriggerRow {
                    withAnimation(.snappy(duration: 0.18)) {
                        triggers.append(TriggerDraft(timezone: triggers.last?.timezone ?? defaultTimezone))
                    }
                }
                if triggers.isEmpty {
                    Text("With no triggers it runs only when you start it with Run now.")
                        .font(.btCallout)
                        .foregroundStyle(Color.btTextTertiary)
                        .padding(.top, Space.xxs)
                } else {
                    HStack(spacing: 1) {
                        Text("If Abstract is closed when a run is due,")
                            .font(.btBody)
                            .foregroundStyle(Color.btTextTertiary)
                        SentenceMenu(title: catchUp ? "run it once when it opens" : "skip that run", quiet: true) {
                            Picker("Missed runs", selection: $catchUp) {
                                Text("Skip That Run").tag(false)
                                Text("Run It Once When Abstract Opens").tag(true)
                            }
                            .pickerStyle(.inline)
                            .labelsHidden()
                        }
                    }
                    .padding(.top, Space.xs)
                }
            }
        }
    }
}

private struct TriggerRow: View {
    @Binding var trigger: TriggerDraft
    let active: Bool
    let now: Date
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        let check = TriggerCheck(trigger, now: now)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Image(systemName: "clock")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Color.btTextTertiary)
                    .frame(width: AutoPage.gutter, alignment: .leading)
                HStack(spacing: 1) {
                    presetMenu.padding(.leading, -Chip.inset)
                    schedule
                    TimeZoneField(identifier: $trigger.timezone, compact: true)
                    status(check)
                }
                Spacer(minLength: Space.md)
                Button(action: onRemove) {
                    Image(systemName: "xmark").font(.system(size: 9.5, weight: .semibold))
                }
                .buttonStyle(.icon(size: 22))
                .help("Remove trigger")
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
            }
            .frame(minHeight: 32)

            if let note = note(check) {
                Text(note.text)
                    .font(.btCaption)
                    .foregroundStyle(note.isError ? Color.btRemoved : Color.btTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.leading, AutoPage.gutter)
                    .padding(.bottom, Space.sm)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Remove trigger", onRemove)
    }

    private var presetMenu: some View {
        SentenceMenu(title: trigger.preset.phrase) {
            Picker("Repeats", selection: Binding(get: { trigger.preset }, set: { trigger.setPreset($0) })) {
                ForEach(SchedulePreset.allCases, id: \.self) { Text($0.phrase).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }

    /// Mon … Sun, in Calendar weekday numbers.
    private static let weekdayOrder = [2, 3, 4, 5, 6, 7, 1]

    @ViewBuilder
    private var schedule: some View {
        switch trigger.preset {
        case .hourly:
            SentenceWord("at")
            TimeChip(hour: $trigger.hour, minute: $trigger.minute, minuteOnly: true)
        case .daily, .weekdays:
            SentenceWord("at")
            TimeChip(hour: $trigger.hour, minute: $trigger.minute)
        case .weekly:
            SentenceWord("on")
            SentenceMenu(title: Calendar.current.weekdaySymbols[trigger.weekday - 1]) {
                Picker("Day", selection: $trigger.weekday) {
                    ForEach(Self.weekdayOrder, id: \.self) { d in Text(Calendar.current.weekdaySymbols[d - 1]).tag(d) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            SentenceWord("at")
            TimeChip(hour: $trigger.hour, minute: $trigger.minute)
        case .custom:
            TextField("Rule", text: $trigger.customRule, prompt: Text("FREQ=DAILY;BYHOUR=9;BYMINUTE=0"))
                .labelsHidden()
                .font(.btMono)
                .btField(compact: true)
                .frame(minWidth: 180, idealWidth: 300, maxWidth: 340)
                .padding(.horizontal, 3)
                .help("An RFC 5545 RRULE: FREQ, INTERVAL, BYDAY, BYMONTHDAY, BYHOUR, BYMINUTE, COUNT and UNTIL.")
        }
    }

    @ViewBuilder
    private func status(_ check: TriggerCheck) -> some View {
        let text: String? = switch check {
        case .upcoming(let date): active ? "Next run \(AutomationText.moment(date, in: zone))" : "Paused"
        case .finished: "No more runs"
        case .invalid: nil
        }
        if let text {
            Text("·  \(text)")
                .font(.btBody)
                .foregroundStyle(Color.btTextTertiary)
                .monospacedDigit()
                .lineLimit(1)
                .padding(.leading, 3)
                .help(hereHelp(check))
        }
    }

    private var zone: TimeZone { TimeZone(identifier: trigger.timezone) ?? .current }

    /// For a zone that isn't this Mac's: what the next run is here.
    private func hereHelp(_ check: TriggerCheck) -> String {
        guard case .upcoming(let date) = check, zone.identifier != TimeZone.current.identifier else { return "" }
        return "\(AutomationText.moment(date, in: zone)) in \(TimeZoneField.city(zone.identifier)) is \(AutomationText.moment(date)) here"
    }

    /// Under a custom rule, the rule in words; under a broken one, why.
    private func note(_ check: TriggerCheck) -> (text: String, isError: Bool)? {
        if case .invalid(let message) = check { return (message, true) }
        if trigger.preset == .custom { return (Schedule.describe(rrule: trigger.rrule), false) }
        return nil
    }
}

private struct AddTriggerRow: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: AutoPage.gutter, alignment: .leading)
                Text("Add trigger").font(.btBody)
            }
            .foregroundStyle(hovering ? Color.btText : Color.btTextSecondary)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.12), value: hovering)
    }
}

// MARK: Scope

/// Where and how each run happens, as one sentence of choices:
/// "In abstract on This Mac using Claude · Opus running in a new worktree
/// with edits accepted".
private struct ScopeSentence: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: AutomationDraft

    private enum Workspace: Hashable {
        case newWorktree
        case pinned(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            FlowRow(spacing: 1, lineSpacing: 2) {
                SentenceWord("In")
                projectMenu
                SentenceWord("on")
                SentenceMenu(title: "This Mac") {
                    Picker("Device", selection: .constant("local")) {
                        Label("This Mac", systemImage: "laptopcomputer").tag("local")
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                SentenceWord("using")
                AgentChip(providerId: $draft.providerId, modelId: $draft.modelId, effort: $draft.effort)
                if draft.projectId != nil {
                    SentenceWord("running")
                    workspaceMenu
                }
                SentenceWord("with")
                policyMenu
            }
            notes
        }
    }

    private var projectMenu: some View {
        SentenceMenu(title: model.project(draft.projectId)?.name ?? "a scratch folder") {
            Picker("Project", selection: Binding(get: { draft.projectId }, set: { new in
                draft.projectId = new
                if let pinned = draft.pinnedSessionId, model.session(pinned)?.projectId != new { draft.pinnedSessionId = nil }
            })) {
                ForEach(model.projects) { p in Text(p.name).tag(Optional(p.id)) }
                Divider()
                Text("No Project: a Scratch Folder per Run").tag(String?.none)
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Button("Add Project…") { model.isAddingProject = true }
        }
    }

    private var chats: [Session] {
        model.sessions.filter { $0.projectId == draft.projectId && $0.worktreePath != nil && $0.archivedAt == nil }
    }

    private var workspace: Workspace? {
        guard draft.workspaceMode == .pinned else { return .newWorktree }
        return draft.pinnedSessionId.map(Workspace.pinned)
    }

    private var workspaceMenu: some View {
        SentenceMenu(title: workspaceTitle) {
            item("In a New Worktree", detail: "Every run gets its own branch, so runs never collide.", .newWorktree)
            Section("In a Chat's Worktree") {
                if chats.isEmpty {
                    Text("This project has no chats with a worktree yet")
                }
                ForEach(chats) { s in item(s.name, detail: s.branch, .pinned(s.id)) }
            }
            Divider()
            Toggle(isOn: Binding(get: { draft.canContinueSession && draft.continueAgentSession },
                                 set: { draft.continueAgentSession = $0 })) {
                Text("Continue the Agent's Previous Session")
                Text("Each run picks up the conversation the last one left.")
            }
            .disabled(!draft.canContinueSession)
        }
    }

    /// A checkmark item with a second line (the NSMenu subtitle).
    private func item(_ title: String, detail: String?, _ choice: Workspace) -> some View {
        Toggle(isOn: Binding(get: { workspace == choice }, set: { _ in
            switch choice {
            case .newWorktree:
                draft.workspaceMode = .newWorktree
            case .pinned(let id):
                draft.workspaceMode = .pinned
                draft.pinnedSessionId = id
            }
        })) {
            Text(title)
            if let detail { Text(detail) }
        }
    }

    private var workspaceTitle: String {
        guard draft.isPinned else { return "in a new worktree" }
        guard let chat = model.session(draft.pinnedSessionId) else { return "in a chat's worktree" }
        return "in “\(chat.name)”" + (draft.canContinueSession && draft.continueAgentSession ? " · same session" : "")
    }

    private var policyMenu: some View {
        SentenceMenu(title: draft.policy.phrase) {
            ForEach(PermissionPolicy.allCases, id: \.self) { p in
                Toggle(isOn: Binding(get: { draft.policy == p }, set: { _ in draft.policy = p })) {
                    Text(p.title)
                    Text(p.detail)
                }
            }
        }
    }

    @ViewBuilder
    private var notes: some View {
        if model.providerStatus[draft.providerId]?.available == false {
            Label("\(ProviderRegistry.name(draft.providerId)) wasn't found on this Mac. Set its path in Settings › Agents.",
                  systemImage: "exclamationmark.triangle")
                .font(.btCallout)
                .foregroundStyle(Color.btWarning)
        }
        if draft.isPinned, chats.isEmpty {
            Text("This project has no chats with a worktree yet, so there's nothing to run in.")
                .font(.btCallout)
                .foregroundStyle(Color.btWarning)
        }
        if draft.policy == .ask {
            Text("Nobody is there to answer while it runs: a run stops at its first tool call until you answer in its chat.")
                .font(.btCallout)
                .foregroundStyle(Color.btTextTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Agent, model and effort as one chip ("Claude · Opus 5.5 · High"); one menu
/// holds all three.
private struct AgentChip: View {
    @Environment(AppModel.self) private var model
    @Binding var providerId: String
    @Binding var modelId: String?
    @Binding var effort: String?
    @State private var typing = false
    @State private var typed = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        Group {
            if typing { field } else { menu }
        }
        .onChange(of: modelId) { _, new in effort = model.supportedEffort(effort, providerId: providerId, model: new) }
    }

    private var menu: some View {
        let catalog = model.models(for: providerId)
        let efforts = model.efforts(providerId: providerId, model: modelId)
        return SentenceMenu(title: title(catalog, efforts), logo: providerId) {
            Section("Agent") {
                Picker("Agent", selection: Binding(get: { providerId }, set: { select($0) })) {
                    ForEach(model.pickableAgents(keeping: providerId), id: \.id) { p in
                        Label {
                            Text(p.name)
                        } icon: {
                            if let icon = ProviderRegistry.menuImage(p.id) { Image(nsImage: icon) }
                        }
                        .tag(p.id)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Section("Model") {
                row(model.defaultModelName(for: providerId).map { "Default (\($0))" } ?? "Default", detail: nil, id: nil)
                ForEach(catalog.models) { row($0) }
                if let custom = modelId, catalog.option(custom) == nil { row(custom, detail: nil, id: custom) }
            }
            if !catalog.versions.isEmpty {
                Section("Specific Versions") {
                    ForEach(catalog.versions) { row($0) }
                }
            }
            Button("Other Model…") { typed = modelId ?? ""; typing = true }
            if !efforts.levels.isEmpty {
                Section("Effort") {
                    Picker("Effort", selection: $effort) {
                        Text(efforts.defaultLevel.map { "Default (\(ModelOption.effortTitle($0)))" } ?? "Default").tag(String?.none)
                        ForEach(efforts.levels, id: \.self) { Text(ModelOption.effortTitle($0)).tag(Optional($0)) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
        }
    }

    private var field: some View {
        HStack(spacing: 5) {
            ProviderLogo(providerId: providerId, size: 13)
            TextField("model name", text: $typed)
                .textFieldStyle(.plain)
                .font(.btMono)
                .frame(width: 160)
                .focused($fieldFocused)
                .onSubmit(commit)
                .onExitCommand { typing = false }
        }
        .padding(.horizontal, Chip.inset)
        .frame(height: Field.compactHeight)
        .btFieldChrome(focused: fieldFocused)
        .onAppear { fieldFocused = true }
        .onChange(of: fieldFocused) { _, focused in if !focused { commit() } }
    }

    private func title(_ catalog: ModelCatalog, _ efforts: (levels: [String], defaultLevel: String?)) -> String {
        var parts = [ProviderRegistry.name(providerId)]
        parts.append(modelId.map { catalog.option($0)?.label ?? $0 } ?? model.defaultModelName(for: providerId) ?? "Default model")
        if !efforts.levels.isEmpty, let level = effort ?? efforts.defaultLevel { parts.append(ModelOption.effortTitle(level)) }
        return parts.joined(separator: " · ")
    }

    private func select(_ id: String) {
        if id != providerId { modelId = nil; effort = nil }
        providerId = id
    }

    private func row(_ option: ModelOption) -> some View {
        let detail = [option.note, option.detail].compactMap { $0 }.joined(separator: " · ")
        return row(option.label, detail: detail.isEmpty ? nil : detail, id: option.id)
    }

    /// A Toggle rather than a Picker option: only a Toggle or Button label
    /// with two Texts becomes a menu item with a subtitle.
    private func row(_ title: String, detail: String?, id: String?) -> some View {
        Toggle(isOn: Binding(get: { modelId == id }, set: { _ in modelId = id })) {
            Text(title)
            if let detail { Text(detail) }
        }
    }

    private func commit() {
        guard typing else { return }
        let name = typed.trimmingCharacters(in: .whitespaces)
        modelId = name.isEmpty ? nil : name
        typing = false
    }
}

// MARK: Instructions

/// The prompt as it reads, rendered Markdown; Edit swaps in its source.
private struct InstructionsView: View {
    @Environment(\.proseStyle) private var prose
    @Binding var prompt: String
    @Binding var editing: Bool
    @FocusState private var focused: Bool

    /// How far the editing fill reaches past the text, so the words keep
    /// the page's left edge in both modes.
    private static let bleed: CGFloat = 12

    var body: some View {
        if editing {
            MarkdownEditor(text: $prompt, font: prose.font(size: prose.points), lineSpacing: prose.lineSpacing,
                           placeholder: "What should the agent do on every run? Markdown works: headings, lists, code blocks.")
                .focused($focused)
                .padding(.horizontal, Self.bleed)
                .padding(.vertical, 10)
                .background(Color.btSurface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                .padding(.horizontal, -Self.bleed)
                .onAppear { focused = true }
        } else if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text("No instructions yet.")
                .font(.btBody)
                .foregroundStyle(Color.btTextTertiary)
        } else {
            AgentProse(markdown: prompt)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A text editor as tall as its text: the page scrolls, never the editor.
private struct MarkdownEditor: View {
    @Binding var text: String
    let font: Font
    let lineSpacing: CGFloat
    let placeholder: String
    @FocusState private var focused: Bool

    /// NSTextView's line fragment padding, taken back so the text meets the edge.
    private static let inset: CGFloat = 5

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Sizes the editor: the same text laid out the same way, plus a line.
            Text(text + "\n ")
                .font(font)
                .lineSpacing(lineSpacing)
                .padding(.horizontal, Self.inset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .hidden()
            TextEditor(text: $text)
                .focused($focused)
                .font(font)
                .fontWeight(Field.weight)
                .lineSpacing(lineSpacing)
                .foregroundStyle(Color.btProse)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
            if text.isEmpty {
                Text(placeholder)
                    .font(font)
                    .foregroundStyle(Color.btTextTertiary)
                    .padding(.horizontal, Self.inset)
                    .allowsHitTesting(false)
            }
        }
        // A text area like every other: steady fill, border answers focus.
        .padding(.horizontal, Field.inset - Self.inset)
        .padding(.vertical, 8)
        .frame(minHeight: 120, alignment: .topLeading)
        .btFieldChrome(focused: focused)
    }
}
