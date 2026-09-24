import SwiftUI
import AbstractCore

/// Past runs of one automation, newest first: one quiet row each, and the
/// row opens the chat the run started.
struct AutomationRunHistory: View {
    @Environment(AppModel.self) private var model
    /// nil while the automation is still being created.
    let automation: Automation?
    let runs: [AutomationRun]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if runs.isEmpty {
                Text(emptyMessage)
                    .font(.btBody)
                    .foregroundStyle(Color.btTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(runs) { RunRow(run: $0) }
            }
            Text("A run counts as created once its workspace exists. How the agent's work went shows on its chat.")
                .font(.btCaption)
                .foregroundStyle(Color.btTextTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Space.lg)
        }
    }

    private var emptyMessage: String {
        guard let automation else { return "Runs show here once the automation is saved." }
        guard automation.enabled else { return "No runs yet. This automation is paused." }
        guard !automation.triggers.isEmpty else { return "No runs yet. With no triggers it runs only when you start it with Run now." }
        guard let next = automation.nextRunAt else { return "No runs yet, and none coming up." }
        return "No runs yet. The first is \(AutomationText.moment(next))."
    }
}

private struct RunRow: View {
    @Environment(AppModel.self) private var model
    let run: AutomationRun

    var body: some View {
        if let session = run.sessionId.flatMap({ model.session($0) }) {
            Button { model.open(session.id) } label: { content(session) }
                .buttonStyle(RowButtonStyle(cornerRadius: Radius.md))
                .padding(.horizontal, -AutoPage.hang)
                .help("Open this run's chat")
        } else {
            content(nil)
                .padding(.horizontal, -AutoPage.hang)
        }
    }

    private func content(_ session: Session?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                glyph.frame(width: AutoPage.gutter, alignment: .leading)
                Text("\(AutomationText.day(run.firedAt)), \(AutomationText.time(run.firedAt))")
                    .font(.btBody)
                    .foregroundStyle(Color.btText)
                    .monospacedDigit()
                    .frame(minWidth: 150, alignment: .leading)
                Text(run.trigger.label)
                    .font(.btBody)
                    .foregroundStyle(Color.btTextSecondary)
                Spacer(minLength: Space.md)
                Text(outcome(session))
                    .font(.btCallout)
                    .foregroundStyle(run.status == .failed ? Color.btRemoved : Color.btTextTertiary)
                    .lineLimit(1)
            }
            .frame(height: 34)
            if run.status == .failed, let error = run.error, !error.isEmpty {
                Text(error)
                    .font(.btMonoSmall)
                    .foregroundStyle(Color.btRemoved)
                    .lineLimit(6)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, AutoPage.gutter)
                    .padding(.bottom, Space.sm)
            }
        }
        .padding(.horizontal, AutoPage.hang)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var glyph: some View {
        if run.status == .creating {
            ProgressView().controlSize(.mini).scaleEffect(0.8).frame(width: 10, height: 10)
        } else {
            Circle().fill(run.status.tint).frame(width: 6, height: 6)
        }
    }

    /// What became of it: the chat's state once there is one.
    private func outcome(_ session: Session?) -> String {
        switch run.status {
        case .creating: "Creating workspace…"
        case .failed: "Failed"
        case .created: session?.status.label ?? "Chat deleted"
        }
    }
}
