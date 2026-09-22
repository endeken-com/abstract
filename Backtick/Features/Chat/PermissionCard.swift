import SwiftUI
import BacktickCore

/// The agent is blocked on you. Set apart by an attention-coloured leading
/// rule and its wording, not by a box or a glow.
struct PermissionCard: View {
    @Environment(AppModel.self) private var model
    let sessionId: String
    let providerId: String
    let request: PendingPermission
    @State private var answered = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                Image(systemName: "hand.raised.fill").font(.system(size: 13)).foregroundStyle(Color.btAttention)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(ProviderRegistry.name(providerId)) wants to use \(request.toolName)")
                        .font(.btBodyMedium).foregroundStyle(Color.btText)
                    if let target = ToolPresentation.target(ToolCall(id: request.requestId, name: request.toolName, input: request.input)) {
                        Text(target).font(.btMono).foregroundStyle(Color.btTextSecondary).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            CodeText(ToolPresentation.inputText(request.input), ruled: false)
                .frame(maxHeight: 180)
            HStack(spacing: Space.sm) {
                Button("Allow") { answer(true) }
                    .buttonStyle(.btPrimary)
                    .keyboardShortcut(.defaultAction)
                Button("Deny") { answer(false) }
                    .buttonStyle(.btSecondary)
                Text("The agent waits until you answer.").font(.btCaption).foregroundStyle(Color.btTextTertiary)
                    .padding(.leading, Space.xs)
            }
            .disabled(answered)
        }
        .padding(.vertical, Space.xs)
        .btLeadingRule(Color.btAttention, width: 2.5)
    }

    private func answer(_ allow: Bool) {
        answered = true
        model.answerPermission(sessionId, requestId: request.requestId, allow: allow)
    }
}
