import SwiftUI
import BacktickCore

/// The reply box. Return sends, Option-Return breaks the line, and the round
/// button turns into Stop while the agent works.
struct ComposerView: View {
    @Environment(AppModel.self) private var model
    let session: Session
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var working: Bool { session.status == .running || session.status == .provisioning }
    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: Space.sm) {
                TextField("Reply to \(ProviderRegistry.name(session.providerId))…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .lineSpacing(2)
                    .lineLimit(1...10)
                    .focused($focused)
                    .onSubmit(send)
                    .padding(.vertical, 7)

                if working {
                    Button { model.stop(session.id) } label: {
                        Image(systemName: "stop.fill").font(.system(size: 10, weight: .bold))
                            .frame(width: 28, height: 28)
                            .background(Color.btText, in: Circle())
                            .foregroundStyle(Color.btCanvas)
                    }
                    .buttonStyle(.plain)
                    .help("Stop the agent")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold))
                            .frame(width: 28, height: 28)
                            .background(canSend ? Color.accentColor : Color.btInset, in: Circle())
                            .foregroundStyle(canSend ? Color.white : Color.btTextTertiary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .help("Send (Return)")
                    .animation(.snappy(duration: 0.15), value: canSend)
                }
            }
            .padding(.leading, Space.lg)
            .padding(.trailing, 7)
            .padding(.vertical, 5)
            .background(Color.btSurfaceRaised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(focused ? Color.accentColor.opacity(0.55) : Color.btBorderStrong, lineWidth: focused ? 1 : 0.5)
            )
            .animation(.snappy(duration: 0.15), value: focused)
            .frame(maxWidth: Space.readingWidth + 40)

            HStack(spacing: Space.md) {
                if let branch = session.branch {
                    Label(branch, systemImage: "arrow.triangle.branch")
                        .font(.btMonoSmall)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(-1)
                }
                Label(model.modelLabel(providerId: session.providerId, model: session.model), systemImage: "cpu")
                Label(session.permissionPolicy.title, systemImage: "checkmark.shield")
                Spacer()
                Text("Return to send · ⌥Return for a new line")
            }
            .font(.btCaption)
            .foregroundStyle(Color.btTextTertiary)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, Space.sm)
            .padding(.top, 7)
            .frame(maxWidth: Space.readingWidth + 40)
        }
        .padding(.horizontal, Space.xl)
        .padding(.top, Space.sm)
        .padding(.bottom, Space.md)
        .frame(maxWidth: .infinity)
        .background(alignment: .top) {
            LinearGradient(colors: [Color.btCanvas.opacity(0), Color.btCanvas], startPoint: .top, endPoint: .bottom)
                .frame(height: 24)
                .offset(y: -24)
                .allowsHitTesting(false)
        }
        .onAppear { focused = true }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        do {
            try model.sendFollowUp(session.id, text: text)
        } catch {
            draft = text
            model.flash(error.localizedDescription, isError: true)
        }
    }
}
