import SwiftUI
import BacktickCore

/// Past runs of one automation, newest first, in plain language.
struct AutomationRunHistory: View {
    @Environment(AppModel.self) private var model
    let automation: Automation
    let runs: [AutomationRun]
    var onRunNow: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if runs.isEmpty {
                    empty
                } else {
                    ForEach(Array(runs.enumerated()), id: \.element.id) { index, run in
                        if index > 0 { Hairline().padding(.leading, 30) }
                        RunRow(run: run)
                    }
                    Hairline()
                }
                Text("A run counts as created once its workspace exists. Whether the agent's work succeeded shows on the chat itself.")
                    .font(.btCaption)
                    .foregroundStyle(Color.btTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Space.lg)
            }
            .padding(.horizontal, Space.xl)
            .padding(.vertical, Space.md)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No runs yet").font(.btBodyMedium).foregroundStyle(Color.btText)
            Text(emptyMessage)
                .font(.btBody)
                .foregroundStyle(Color.btTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Run Now", action: onRunNow)
                .buttonStyle(.bt(.secondary, size: .small))
                .padding(.top, Space.sm)
        }
        .padding(.vertical, Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyMessage: String {
        guard automation.enabled else { return "This automation is paused. Turn it back on, or run it now to try it." }
        guard let next = automation.nextRunAt else { return "The schedule has no upcoming runs. Run it now to try the prompt." }
        let tz = TimeZone(identifier: automation.timezone) ?? .current
        return "The next run is \(AutomationText.dayPhrase(next, in: tz)) at \(AutomationText.time(next, in: tz)). Or run it now to try the prompt."
    }
}

private struct RunRow: View {
    @Environment(AppModel.self) private var model
    let run: AutomationRun

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.md) {
            Group {
                if run.status == .creating {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                } else {
                    Image(systemName: run.status.symbol)
                        .font(.system(size: 13))
                        .foregroundStyle(run.status.tint)
                }
            }
            .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text("Ran \(AutomationText.time(run.firedAt))").font(.btBodyMedium).foregroundStyle(Color.btText)
                    Text("·").foregroundStyle(Color.btTextTertiary)
                    Text(run.trigger.label).font(.btBody).foregroundStyle(Color.btTextSecondary)
                }
                .monospacedDigit()
                Text(detail)
                    .font(.btCaption)
                    .foregroundStyle(Color.btTextTertiary)
                    .lineLimit(1)
                if run.status == .failed, let error = run.error, !error.isEmpty {
                    Text(error)
                        .font(.btMonoSmall)
                        .foregroundStyle(Color.btRemoved)
                        .lineLimit(6)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: Space.md)
            RunStatusLabel(status: run.status)
            if let id = run.sessionId, model.session(id) != nil {
                Button("Open chat") { model.open(id) }
                    .buttonStyle(.bt(.secondary, size: .small))
            }
        }
        .padding(.vertical, Space.md)
    }

    private var detail: String {
        // "10 minutes ago" today, "Yesterday", or "Mon, Sep 21 · 3 days ago".
        var parts: [String]
        switch AutomationText.day(run.firedAt) {
        case "Today": parts = [run.firedAt.formatted(.relative(presentation: .named))]
        case "Yesterday": parts = ["Yesterday"]
        case let day: parts = [day, run.firedAt.formatted(.relative(presentation: .named))]
        }
        if let id = run.sessionId {
            parts.append(model.session(id).map { "Chat: \($0.status.label)" } ?? "Chat deleted")
        }
        return parts.joined(separator: " · ")
    }
}
