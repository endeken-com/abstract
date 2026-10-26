import SwiftUI
import AbstractCore

/// A plan written in Plan mode, waiting for your decision (ABS-104):
/// the plan itself as Markdown, what to do with it, and the earlier
/// revisions under it.
struct PlanCard: View {
    @Environment(AppModel.self) private var model
    let sessionId: String
    let plan: PlanState
    @State private var showsHistory = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.clipboard")
                    .font(.btChatTool)
                    .foregroundStyle(Color.btTextSecondary)
                Text(plan.revisions.count > 1 ? "Plan · revision \(plan.revisions.count)" : "Plan")
                    .font(.btChatToolMedium)
                    .foregroundStyle(Color.btTextSecondary)
                if plan.status == .changesRequested {
                    Text("· changes requested")
                        .font(.btChatTool)
                        .foregroundStyle(Color.btTextTertiary)
                }
            }
            if let current = plan.current {
                AgentProse(markdown: current)
            }
            if !plan.history.isEmpty {
                Button(showsHistory ? "Hide earlier revisions" : "Show \(plan.history.count) earlier \(plan.history.count == 1 ? "revision" : "revisions")") {
                    showsHistory.toggle()
                }
                .buttonStyle(.bt(.ghost, size: .small))
                if showsHistory {
                    ForEach(Array(plan.history.enumerated()), id: \.offset) { index, revision in
                        VStack(alignment: .leading, spacing: Space.xs) {
                            Text("Revision \(index + 1)")
                                .font(.btChatCaption)
                                .foregroundStyle(Color.btTextTertiary)
                            AgentProse(markdown: revision)
                        }
                        .opacity(0.7)
                    }
                }
            }
            HStack(spacing: Space.sm) {
                Button("Approve and start") { model.approvePlan(sessionId) }
                    .buttonStyle(.bt(.primary, size: .small))
                    .help("Switch back to your usual permissions and start on this plan")
                Button("Request changes") { model.requestPlanChanges(sessionId) }
                    .buttonStyle(.bt(.secondary, size: .small))
                    .help("Quote the plan in the reply box so you can say what to change")
                Button("Discard") { model.discardPlan(sessionId) }
                    .buttonStyle(.bt(.ghost, size: .small))
            }
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.btInset.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
    }
}
