import SwiftUI
import AbstractCore

/// A new chat getting ready, under its prompt where the agent's work will
/// appear: its base fetched, its worktree made, the setup script's output as
/// it runs. A step that fails says why and waits: try again, skip the script,
/// or look around in a terminal. Rows read like tool rows.
struct ChatSetupCard: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let setup: ChatSetup

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(visibleSteps, id: \.self) { step in
                SetupStepRow(session: session, setup: setup, step: step)
            }
            if let failure = setup.failure {
                FailureActions(session: session, setup: setup, message: failure.message, step: failure.step)
                    .padding(.top, Space.sm)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.snappy(duration: 0.2), value: setup.phases)
    }

    /// The script's row only when there is a script, or was; the agent's once
    /// it's starting.
    private var visibleSteps: [ChatSetup.Step] {
        ChatSetup.Step.allCases.filter { step in
            switch step {
            case .script: setup.phase(.script) != .skipped || setup.startedAt[.script] != nil
            case .agent: setup.phase(.agent) != .pending
            default: true
            }
        }
    }
}

private struct SetupStepRow: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let setup: ChatSetup
    let step: ChatSetup.Step
    @State private var showsAll = false

    private var phase: ChatSetup.Phase { setup.phase(step) }
    private var running: Bool { phase == .running }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                glyph
                HStack(spacing: 6) {
                    Text(title).font(.btChatToolMedium).foregroundStyle(phase == .pending ? Color.btTextTertiary : Color.btTextSecondary)
                    if let detail {
                        Text(detail.text)
                            .font(.btChatTool)
                            .foregroundStyle(detail.warning ? Color.btWarning : Color.btTextTertiary)
                            .lineLimit(1)
                            .help(detail.help ?? "")
                    }
                }
                .modifier(Shimmer(active: running, length: title.count + 10))
                if let started = setup.startedAt[step], step == .script || running {
                    Elapsed(from: started, to: setup.endedAt[step])
                }
                Spacer(minLength: Space.sm)
                if step == .script, running {
                    Button("Start Agent Now") { model.skipSetupScript(session.id) }
                        .buttonStyle(.bt(.ghost, size: .small))
                        .help("Stop the setup script and start the agent")
                }
            }
            .frame(minHeight: 26)

            if step == .script, !setup.log.isEmpty, phase != .done || showsAll {
                output
            } else if step == .script, phase == .done, !setup.log.isEmpty {
                Button("Show output") { withAnimation(.snappy(duration: 0.2)) { showsAll = true } }
                    .buttonStyle(.plain)
                    .font(.btChatCaption)
                    .foregroundStyle(Color.btTextTertiary)
                    .padding(.leading, 22)
            }
        }
    }

    /// The last lines while it runs (more on request); everything once it has
    /// failed or when asked.
    private var output: some View {
        let failed = if case .failed = phase { true } else { false }
        let lines = setup.log
        let limit = showsAll || failed ? ChatSetup.logLimit : 12
        return VStack(alignment: .leading, spacing: 4) {
            TextLines(text: lines.suffix(limit).joined(separator: "\n"), font: .btChatMonoSmall,
                      color: failed ? Color.btRemoved.opacity(0.9) : Color.btTextSecondary, spacing: 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .btLeadingRule(failed ? Color.btRemoved : Color.btBorderStrong)
            if lines.count > limit {
                Button(showsAll ? "Show less" : "Show all \(lines.count) lines") { showsAll.toggle() }
                    .buttonStyle(.plain)
                    .font(.btChatCaption)
                    .foregroundStyle(Color.btTextTertiary)
            }
        }
        .padding(.leading, 22)
        .padding(.top, 2)
        .padding(.bottom, Space.sm)
    }

    @ViewBuilder
    private var glyph: some View {
        Group {
            switch phase {
            case .running: ProgressView().controlSize(.mini)
            case .done: Image(systemName: "checkmark")
            case .failed: Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.btRemoved)
            case .skipped: Image(systemName: "arrow.uturn.right")
            case .pending: Image(systemName: "circle.dotted")
            }
        }
        .font(.system(size: 11, weight: .regular))
        .foregroundStyle(Color.btTextTertiary)
        .frame(width: 16, height: 16)
    }

    private var title: String {
        let agent = ProviderRegistry.name(session.providerId)
        switch (step, phase) {
        case (.fetch, .running): return "Fetching"
        case (.fetch, .done): return fetchedFromOrigin ? "Fetched" : "Starting from"
        case (.fetch, _): return "Fetch"
        case (.worktree, .running): return "Creating the worktree"
        case (.worktree, .done): return "Created the worktree"
        case (.worktree, _): return "Create the worktree"
        case (.script, .running): return "Running the setup script"
        case (.script, .done): return "Ran the setup script"
        case (.script, .skipped): return "Skipped the setup script"
        case (.script, _): return "Run the setup script"
        case (.agent, .running): return "Starting \(agent)"
        case (.agent, _): return "Start \(agent)"
        }
    }

    /// Whether the worktree starts from a copy just fetched from origin.
    private var fetchedFromOrigin: Bool {
        guard let base = setup.base else { return false }
        return base.fetchError == nil && base.ref.hasPrefix("origin/")
    }

    private var detail: (text: String, warning: Bool, help: String?)? {
        switch step {
        case .fetch:
            guard let base = setup.base else {
                let asked = setup.baseRef.flatMap { $0.isEmpty ? nil : $0 } ?? model.project(setup.projectId)?.defaultBaseRef ?? "HEAD"
                return (asked.hasPrefix("origin/") || asked == "HEAD" ? asked : "\(asked) from origin", false, nil)
            }
            if let error = base.fetchError { return ("\(base.ref) · couldn't reach origin, so as last fetched", true, error) }
            if base.ref.hasPrefix("origin/") { return (base.ref, false, nil) }
            return (base.ref, false, "Not from origin: it has no copy of this branch, it isn't a branch, "
                        + "or your local branch has commits origin doesn't.")
        case .worktree:
            return session.branch.map { ($0, false, session.worktreePath) }
        case .script, .agent:
            return nil
        }
    }
}

/// Seconds a step has run, or took.
private struct Elapsed: View {
    let from: Date
    let to: Date?

    var body: some View {
        if let to {
            label(to)
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in label(context.date) }
        }
    }

    private func label(_ now: Date) -> some View {
        Text(RelativeTime.duration(Int(max(0, now.timeIntervalSince(from)) * 1000)))
            .font(.btChatCaption)
            .foregroundStyle(Color.btTextTertiary)
            .monospacedDigit()
    }
}

private struct FailureActions: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let setup: ChatSetup
    let message: String
    let step: ChatSetup.Step

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(message)
                .font(.btChatCallout)
                .foregroundStyle(Color.btRemoved)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: Space.sm) {
                Button("Try Again") { model.runSetup(session.id) }
                    .buttonStyle(.bt(.secondary, size: .small))
                    .help("Run the steps that haven't finished again")
                if session.worktreePath != nil, step == .script {
                    Button("Start Without It") { model.skipSetupScript(session.id) }
                        .buttonStyle(.bt(.ghost, size: .small))
                        .help("Start the agent in the worktree as it is")
                }
                if session.worktreePath != nil {
                    Button("Open Terminal") { model.newTerminal(in: session.id) }
                        .buttonStyle(.bt(.ghost, size: .small))
                        .help("A terminal in the chat's worktree")
                }
            }
        }
        .padding(.leading, 22)
    }
}
