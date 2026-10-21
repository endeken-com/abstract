import SwiftUI
import AbstractCore

/// Where a chat is in its workflow, under the transcript: the steps in
/// order with the current one marked, and, when a step waits for you,
/// the button that hands the chat on.
struct WorkflowStrip: View {
    @Environment(AppModel.self) private var model
    let sessionId: String
    let progress: WorkflowProgress

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: 6) {
                Image(systemName: Workflow.defaultSymbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.btTextTertiary)
                Text(progress.workflow.name)
                    .font(.btChatToolMedium)
                    .foregroundStyle(Color.btTextSecondary)
                    .lineLimit(1)
                    .layoutPriority(1)
                Text("·  \(status)")
                    .font(.btChatCaption)
                    .foregroundStyle(Color.btTextTertiary)
                    .lineLimit(1)
                Spacer(minLength: Space.md)
                if progress.isActive {
                    Button("Stop Workflow") { model.stopWorkflow(sessionId) }
                        .buttonStyle(.bt(.ghost, size: .small))
                        .help("Keep the chat with its current profile and stop handing it on")
                }
            }
            FlowRow(spacing: 4, lineSpacing: 4) {
                ForEach(Array(progress.workflow.steps.enumerated()), id: \.offset) { index, step in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Color.btTextTertiary)
                            .frame(height: 22)
                    }
                    StepChip(name: step.profileName, state: state(of: index))
                }
            }
            if progress.state == .waiting, let next = progress.next {
                HStack(spacing: Space.sm) {
                    Button("Continue to \(next.profileName)") { model.continueWorkflow(sessionId) }
                        .buttonStyle(.bt(.primary, size: .small))
                        .keyboardShortcut(.return, modifiers: [.command, .shift])
                        .help("Hand the chat to \(next.profileName) (⇧⌘↩)")
                    Text("Reply first if this step needs more; continue when it's right.")
                        .font(.btChatCaption)
                        .foregroundStyle(Color.btTextTertiary)
                }
                .padding(.top, 2)
            }
            if progress.state == .stopped, let note = progress.note {
                Text(note)
                    .font(.btChatCaption)
                    .foregroundStyle(Color.btWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(.snappy(duration: 0.2), value: progress)
    }

    private var status: String {
        switch progress.state {
        case .working: progress.position
        case .waiting: "\(progress.position) done, waiting for you"
        case .finished: "Finished"
        case .stopped: "Stopped at step \(progress.step + 1)"
        }
    }

    private func state(of index: Int) -> StepChip.State {
        if progress.state == .finished || index < progress.step { return .done }
        if index > progress.step { return .upcoming }
        switch progress.state {
        case .working: return .current
        case .waiting: return .done
        case .stopped, .finished: return .stopped
        }
    }
}

private struct StepChip: View {
    enum State { case done, current, upcoming, stopped }
    let name: String
    let state: State

    var body: some View {
        HStack(spacing: 4) {
            switch state {
            case .done:
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.btTextTertiary)
            case .current:
                Circle().fill(Color.btAccent).frame(width: 6, height: 6)
            case .upcoming, .stopped:
                EmptyView()
            }
            Text(name)
                .font(.btChatCaption)
                .foregroundStyle(state == .current ? Color.btText : state == .upcoming ? Color.btTextTertiary : Color.btTextSecondary)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(state == .current ? Color.btSelection : Color.btHover.opacity(0.6), in: Capsule())
    }
}
