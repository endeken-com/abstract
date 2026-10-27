import SwiftUI
import AbstractCore

/// Past runs of one automation, newest first: one outcome word each, and
/// the row (or its Open chat button) opens the chat the run happened in.
struct AutomationRunHistory: View {
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
                if runs.count >= 50 {
                    Text("Showing the latest 50 runs.")
                        .font(.btCaption)
                        .foregroundStyle(Color.btTextTertiary)
                        .padding(.top, Space.lg)
                }
            }
        }
    }

    private var emptyMessage: String {
        guard let automation else { return "Runs show here once the automation is saved." }
        guard automation.enabled else { return "No runs yet. This automation is paused." }
        guard !automation.triggers.isEmpty else {
            if let events = AutomationEvents.summary(automation.events) { return "No runs yet. \(events), it runs." }
            return "No runs yet. With no schedules it runs only when you start it with Run now."
        }
        guard let next = automation.nextRunAt else { return "No runs yet, and none coming up." }
        return "No runs yet. The first is \(AutomationText.moment(next))."
    }
}

private struct RunRow: View {
    @Environment(AppModel.self) private var model
    let run: AutomationRun
    @State private var hovering = false

    var body: some View {
        let session = run.sessionId.flatMap { model.session($0) }
        let outcome = model.outcome(of: run)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    Circle().fill(outcome.tint).frame(width: 6, height: 6)
                    Text(outcome.word)
                }
                .font(.btBodyMedium)
                .foregroundStyle(outcome.needsAttention ? outcome.tint : Color.btText)
                .lineLimit(1)
                .frame(minWidth: 120, alignment: .leading)
                Text(triggerLabel)
                    .font(.btBody)
                    .foregroundStyle(Color.btTextSecondary)
                    .lineLimit(1)
                Spacer(minLength: Space.md)
                if let session {
                    Button("Open chat") { model.open(session.id) }
                        .buttonStyle(.bt(.ghost, size: .small))
                        .help("Open this run's chat")
                }
            }
            .frame(height: 32)
            Text(detail(session))
                .font(.btCallout)
                .foregroundStyle(Color.btTextTertiary)
                .monospacedDigit()
                .lineLimit(1)
                .padding(.leading, AutoPage.gutter)
                .padding(.bottom, Space.sm)
            if run.status == .failed, let error = run.error, !error.isEmpty {
                Text(error)
                    .font(.btBody)
                    .foregroundStyle(Color.btRemoved)
                    .lineLimit(6)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, AutoPage.gutter)
                    .padding(.bottom, Space.sm)
            }
            if run.status == .skipped, let reason = run.reason, !reason.isEmpty {
                Text(reason.prefix(1).uppercased() + reason.dropFirst() + ".")
                    .font(.btCaption)
                    .foregroundStyle(Color.btTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, AutoPage.gutter)
                    .padding(.bottom, Space.sm)
            }
        }
        .padding(.horizontal, AutoPage.hang)
        .contentShape(Rectangle())
        .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            .fill(hovering && session != nil ? Color.btHover : .clear))
        .padding(.horizontal, -AutoPage.hang)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.12), value: hovering)
        .onTapGesture { if let session { model.open(session.id) } }
        .help(session == nil ? "" : "Open this run's chat")
    }

    /// "Today, 09:00", with the chat's name when the run has one.
    private func detail(_ session: Session?) -> String {
        let when = "\(AutomationText.day(run.firedAt)), \(AutomationText.time(run.firedAt))"
        return session.map { "\(when) · “\($0.name)”" } ?? when
    }

    /// "On schedule", "Run by hand", or for an event "“Fix login” is archived".
    private var triggerLabel: String {
        guard let event = run.event else { return run.trigger.label }
        let chat = run.sourceSessionId.flatMap { model.chatName($0) }.map { "“\($0)”" } ?? "A chat"
        return "\(chat) \(event.phrase)"
    }
}
