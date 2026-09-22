import SwiftUI
import BacktickCore

/// Scheduled agent runs, modelled on superset.sh automations: a list on the
/// left, the selected automation (or the create form) on the right.
struct AutomationsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: AutomationSelection?
    @State private var tab: AutomationTab = .history
    @State private var lastRuns: [String: AutomationRun] = [:]

    var body: some View {
        Group {
            if model.automations.isEmpty && selection != .new {
                EmptyStateView(
                    symbol: "clock.arrow.2.circlepath",
                    title: "No automations yet",
                    message: "Run an agent on a schedule — nightly dependency bumps, issue triage, recurring cleanups. Every run opens its own chat you review like any other.",
                    action: ("New Automation", { selection = .new })
                )
            } else {
                HStack(spacing: 0) {
                    list
                        .frame(width: 300)
                    Rectangle().fill(Color.btBorder).frame(width: 0.5).ignoresSafeArea()
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Color.btCanvas)
        .navigationTitle("Automations")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { selection = .new } label: { Label("New Automation", systemImage: "plus") }
                    .help("Create an automation")
            }
        }
        .onAppear { settleSelection() }
        .onChange(of: model.automations) { _, _ in
            settleSelection()
            refreshLastRuns()
        }
        .onChange(of: model.sessions) { _, _ in refreshLastRuns() }
        .task { refreshLastRuns() }
    }

    // MARK: List

    private var list: some View {
        VStack(spacing: 0) {
            SectionLabel(title: model.automations.count == 1 ? "1 automation" : "\(model.automations.count) automations")
                .padding(.horizontal, Space.lg + Space.xs)
                .padding(.top, Space.lg + Space.xs)
                .padding(.bottom, Space.sm + Space.xxs)

            ScrollView {
                LazyVStack(spacing: 2) {
                    if selection == .new {
                        NewAutomationRow()
                    }
                    ForEach(model.automations) { a in
                        AutomationRow(automation: a, projectName: model.project(a.projectId)?.name,
                                      lastRun: lastRuns[a.id], selected: selection == .existing(a.id)) {
                            selection = .existing(a.id)
                        }
                    }
                }
                .padding(.horizontal, Space.sm)
                .padding(.bottom, Space.lg)
            }
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .new:
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("New Automation").font(.btTitle).foregroundStyle(Color.btText)
                    Text("Describe the job once; Backtick starts a chat for it on every scheduled run.")
                        .font(.btCallout)
                        .foregroundStyle(Color.btTextSecondary)
                }
                .padding(.horizontal, Space.xl)
                .padding(.top, Space.xl)
                .padding(.bottom, Space.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
                AutomationEditor(existing: nil, draft: .new(for: model), onSaved: { saved in
                    tab = .history
                    selection = .existing(saved.id)
                }, onCancel: {
                    selection = model.automations.first.map { .existing($0.id) }
                })
            }
        case .existing(let id):
            if let a = model.automations.first(where: { $0.id == id }) {
                AutomationDetail(automation: a, tab: $tab) {
                    selection = nil
                    settleSelection()
                }
                .id(a.id)
            }
        case nil:
            EmptyStateView(symbol: "clock.arrow.2.circlepath", title: "Select an automation")
        }
    }

    // MARK: State

    private func settleSelection() {
        switch selection {
        case .new:
            return
        case .existing(let id) where model.automations.contains(where: { $0.id == id }):
            return
        default:
            selection = model.automations.first.map { .existing($0.id) }
        }
    }

    private func refreshLastRuns() {
        var runs: [String: AutomationRun] = [:]
        for a in model.automations {
            if let run = model.automationRuns(a.id, limit: 1).first { runs[a.id] = run }
        }
        if runs != lastRuns { lastRuns = runs }
    }
}

enum AutomationSelection: Hashable {
    case new
    case existing(String)
}

enum AutomationTab: String, Hashable {
    case history, settings
}

// MARK: - Rows

private struct AutomationRow: View {
    let automation: Automation
    let projectName: String?
    let lastRun: AutomationRun?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Space.sm) {
                    Circle()
                        .fill(automation.enabled ? Color.btAdded : Color.btTextTertiary)
                        .frame(width: 6, height: 6)
                        .accessibilityLabel(automation.enabled ? "Active" : "Paused")
                    Text(automation.name)
                        .font(.btBodyMedium)
                        .foregroundStyle(Color.btText)
                        .lineLimit(1)
                    Spacer(minLength: Space.xs)
                    Text(AutomationText.next(automation))
                        .font(.btCaption)
                        .foregroundStyle(automation.enabled ? Color.btTextSecondary : Color.btTextTertiary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                Group {
                    Text("\(projectName ?? "No project") · \(AutomationText.schedule(automation))")
                        .foregroundStyle(Color.btTextSecondary)
                    if let lastRun {
                        Text("Last run \(lastRun.firedAt.formatted(.relative(presentation: .named))) · \(lastRun.status.label)")
                            .foregroundStyle(lastRun.status == .failed ? Color.btRemoved : Color.btTextTertiary)
                    }
                }
                .font(.btCaption)
                .lineLimit(1)
                .padding(.leading, 14)
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(RowButtonStyle(selected: selected, cornerRadius: Radius.md))
    }
}

/// The automation being created, shown selected at the top of the list.
private struct NewAutomationRow: View {
    var body: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.btTextSecondary)
                .frame(width: 6)
            Text("New Automation").font(.btBodyMedium).foregroundStyle(Color.btText)
            Spacer()
            Text("Draft").font(.btCaption).foregroundStyle(Color.btTextTertiary)
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.btSelection, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    }
}

// MARK: - Detail

private struct AutomationDetail: View {
    @Environment(AppModel.self) private var model
    let automation: Automation
    @Binding var tab: AutomationTab
    var onDeleted: () -> Void

    @State private var runs: [AutomationRun] = []
    @State private var running = false
    @State private var confirmingDelete = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, Space.xl)
                .padding(.top, Space.xl)
                .padding(.bottom, Space.lg)

            HStack {
                Picker("View", selection: $tab) {
                    Text("Run History").tag(AutomationTab.history)
                    Text("Settings").tag(AutomationTab.settings)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
            }
            .padding(.horizontal, Space.xl)
            .padding(.bottom, Space.md)

            Hairline()

            switch tab {
            case .history:
                AutomationRunHistory(automation: automation, runs: runs, onRunNow: runNow)
            case .settings:
                AutomationEditor(existing: automation, draft: AutomationDraft(automation), onSaved: { _ in reloadRuns() })
            }
        }
        .onAppear(perform: reloadRuns)
        .onChange(of: model.sessions) { _, _ in reloadRuns() }
        .onChange(of: automation) { _, _ in reloadRuns() }
        .confirmationDialog("Delete “\(automation.name)”?", isPresented: $confirmingDelete) {
            Button("Delete Automation", role: .destructive) {
                model.deleteAutomation(automation.id)
                model.flash("“\(automation.name)” deleted")
                onDeleted()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the automation and its run history. Chats and worktrees its runs created stay.")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Space.lg) {
            VStack(alignment: .leading, spacing: 6) {
                Text(automation.name)
                    .font(.btTitle)
                    .foregroundStyle(Color.btText)
                    .lineLimit(2)
                    .textSelection(.enabled)
                HStack(spacing: Space.md) {
                    meta(symbol: "clock", text: AutomationText.schedule(automation))
                    meta(symbol: automation.enabled ? "calendar" : "pause.circle", text: nextLine)
                }
                HStack(spacing: Space.md) {
                    HStack(spacing: 5) {
                        ProviderLogo(providerId: automation.providerId, size: 12)
                        Text(ProviderRegistry.name(automation.providerId)).font(.btCallout).foregroundStyle(Color.btTextSecondary)
                    }
                    meta(symbol: automation.projectId == nil ? "tray" : "folder",
                         text: model.project(automation.projectId)?.name ?? "No project")
                    meta(symbol: automation.workspaceMode == .pinned ? "pin" : "arrow.triangle.branch",
                         text: automation.projectId == nil ? "Scratch directory" : automation.workspaceMode == .pinned ? "Pinned worktree" : "New worktree per run")
                }
            }
            Spacer(minLength: Space.lg)
            HStack(spacing: Space.md) {
                Toggle(isOn: Binding(get: { automation.enabled }, set: { model.setAutomationEnabled(automation.id, $0) })) {
                    Text("Active").font(.btCallout.weight(.medium)).foregroundStyle(Color.btTextSecondary)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .help(automation.enabled ? "Pause: scheduled runs stop until you turn it back on" : "Resume the schedule")

                Button(action: runNow) {
                    HStack(spacing: 6) {
                        if running {
                            ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 12, height: 12).tint(.white)
                        } else {
                            Image(systemName: "play.fill").font(.system(size: 10, weight: .semibold))
                        }
                        Text("Run Now")
                    }
                }
                .buttonStyle(.btPrimary)
                .disabled(running)
                .help("Start a run immediately, outside the schedule")

                Button { confirmingDelete = true } label: { Image(systemName: "trash") }
                    .buttonStyle(.icon)
                    .help("Delete Automation")
            }
        }
    }

    private var nextLine: String {
        guard automation.enabled else { return "Paused" }
        guard let next = automation.nextRunAt else { return "No upcoming runs" }
        let tz = TimeZone(identifier: automation.timezone) ?? .current
        return "Next run \(AutomationText.dayPhrase(next, in: tz)) at \(AutomationText.time(next, in: tz))"
    }

    private func meta(symbol: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.btTextTertiary)
            Text(text).font(.btCallout).foregroundStyle(Color.btTextSecondary).lineLimit(1)
        }
    }

    private func reloadRuns() {
        let fresh = model.automationRuns(automation.id)
        if fresh != runs { runs = fresh }
    }

    private func runNow() {
        guard !running else { return }
        running = true
        let a = automation
        Task {
            _ = await model.runAutomationNow(a)
            running = false
            tab = .history
            reloadRuns()
        }
    }
}
