import SwiftUI
import AbstractCore

/// Messages sent while the agent works, dimmed above the reply box until
/// they go. Edit takes one back into the box; the cross removes it.
struct QueuedMessages: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let working: Bool
    let edit: (QueuedMessage) -> Void

    var body: some View {
        let queue = model.queuedMessages(session.id)
        if !queue.isEmpty {
            VStack(alignment: .trailing, spacing: 6) {
                ForEach(queue) { message in
                    QueuedBubble(message: message, edit: { edit(message) }, remove: { remove(message) })
                }
                Text(working ? "Sent together when this turn ends." : "Not sent yet. Send them now with your next message, or remove them.")
                    .font(.btChatCaption)
                    .foregroundStyle(Color.btTextTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .animation(.snappy(duration: 0.2), value: queue.map(\.id))
        }
    }

    private func remove(_ message: QueuedMessage) {
        Task { if await model.takeQueued(session.id, id: message.id) == nil { model.flash("That message has already been sent.") } }
    }
}

private struct QueuedBubble: View {
    let message: QueuedMessage
    let edit: () -> Void
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            if hovering {
                Button("Edit", action: edit)
                    .buttonStyle(.btGhost)
                    .help("Move it back to the reply box to change it")
                Button(action: remove) { Image(systemName: "xmark") }
                    .buttonStyle(.btGhost)
                    .help("Remove it; it won't be sent")
                    .accessibilityLabel("Remove queued message")
            }
            VStack(alignment: .leading, spacing: 4) {
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(BTFont.chat(13))
                        .lineLimit(4)
                        .foregroundStyle(Color.btTextSecondary)
                }
                if !message.attachments.isEmpty {
                    Text(message.attachments.map(\.label).joined(separator: ", "))
                        .font(.btChatCaption)
                        .foregroundStyle(Color.btTextTertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.btSurface.opacity(0.6), in: UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 14,
                                                                                 bottomTrailingRadius: 14, topTrailingRadius: 4,
                                                                                 style: .continuous))
            .opacity(0.75)
        }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Queued: \(message.text)")
        .accessibilityAction(named: "Edit", edit)
        .accessibilityAction(named: "Remove", remove)
    }
}
