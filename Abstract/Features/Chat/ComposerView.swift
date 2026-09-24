import SwiftUI
import AbstractCore

/// The reply box. Return sends, Option-Return breaks the line, and the round
/// button turns into Stop while the agent works.
struct ComposerView: View {
    @Environment(AppModel.self) private var model
    let session: Session
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var working: Bool { session.status == .running || session.status == .provisioning }
    private var suggestion: String? { working ? nil : model.feed(session.id).suggestion }
    /// A review or attachments can go on their own; otherwise there must be something typed.
    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.comments(session.id).isEmpty || !attachments.isEmpty
    }
    private var attachments: [PromptAttachment] {
        get { model.draftAttachments[session.id] ?? [] }
        nonmutating set { model.draftAttachments[session.id] = newValue.isEmpty ? nil : newValue }
    }
    private var attachmentsBinding: Binding<[PromptAttachment]> {
        Binding(get: { attachments }, set: { attachments = $0 })
    }
    /// Where `gh` finds the repository (on the chat's Mac).
    private var repoRoot: String? { session.worktreePath ?? model.project(session.projectId)?.rootPath }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ReviewPill(sessionId: session.id)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.lg)
            .padding(.bottom, model.comments(session.id).isEmpty ? 0 : 6)
            .frame(maxWidth: Space.readingWidth + 2 * Space.lg)
            .animation(.snappy(duration: 0.2), value: model.comments(session.id).count)
            ComposerContext(session: session)
                .padding(.horizontal, Space.lg)
                .padding(.bottom, 6)
                .frame(maxWidth: Space.readingWidth + 2 * Space.lg)
            VStack(alignment: .leading, spacing: 0) {
                if !attachments.isEmpty {
                    AttachmentTray(attachments: attachmentsBinding)
                        .padding(.top, 7)
                        .padding(.trailing, Space.sm)
                }
                HStack(alignment: .bottom, spacing: Space.sm) {
                    // The agent's guess at your next message shows as the placeholder;
                    // Tab takes it, then Return sends it as usual.
                    TextField(text: $draft, prompt: Text(suggestion ?? "Reply to \(ProviderRegistry.name(session.providerId))…"), axis: .vertical) {
                        Text("Reply")
                    }
                        .textFieldStyle(.plain)
                        .font(BTFont.chat(13.5))
                        .onKeyPress(.tab) {
                            guard draft.isEmpty, let suggestion else { return .ignored }
                            draft = suggestion
                            return .handled
                        }
                        .lineSpacing(2)
                        .lineLimit(1...10)
                        .focused($focused)
                        .onSubmit(send)
                        .padding(.vertical, 7)

                    AttachmentButtons(repoRoot: repoRoot, sessionId: session.id, attachments: attachmentsBinding)

                    // No round send button: a return glyph says what Return does,
                    // and becomes Stop while the agent works.
                    if working {
                        Button { model.stop(session.id) } label: {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.btText)
                                .frame(width: 26, height: 26)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Stop the agent (⌘.)")
                    } else {
                        Button(action: send) {
                            Image(systemName: "return")
                                .font(.system(size: 12, weight: .regular))
                                .foregroundStyle(canSend ? Color.btText : Color.btTextTertiary)
                                .frame(width: 26, height: 26)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSend)
                        .help("Send (Return)")
                        .animation(.snappy(duration: 0.15), value: canSend)
                    }
                }
            }
            .padding(.leading, Space.lg)
            .padding(.trailing, 7)
            .padding(.vertical, 5)
            .btFieldChrome(focused: focused)
            .attachmentInput(attachmentsBinding, focused: focused)
            .frame(maxWidth: Space.readingWidth + 2 * Space.lg)

            // What the agent runs with, each one a menu to change it.
            AgentControls(session: session, attachments: attachmentsBinding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.lg - 6) // the menus' own padding lines their text up
                .padding(.top, 4)
            .frame(maxWidth: Space.readingWidth + 2 * Space.lg)
        }
        // The box hangs one inset past the prose column on each side, so the
        // text inside it starts exactly where the agent's text does.
        .padding(.horizontal, Space.xxl - Space.lg)
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
        guard canSend else { return }
        let pending = attachments
        draft = ""
        attachments = []
        RevundService.shared.userWrote(session.id)
        do {
            // The review goes with the message, after it, then the attachments.
            try model.sendFollowUp(session.id, text: model.messageWithReview(session.id, text: text), attachments: pending)
            model.discardComments(session.id)
        } catch {
            draft = text
            attachments = pending
            model.flash(error.localizedDescription, isError: true)
        }
    }
}

/// Above the reply box: the branch the agent works on and how much it has
/// changed so far. The counts open Review.
private struct ComposerContext: View {
    @Environment(AppModel.self) private var model
    let session: Session
    @State private var totals: (additions: Int, deletions: Int)?

    var body: some View {
        HStack(spacing: Space.sm) {
            if let branch = session.branch {
                Label(branch, systemImage: "arrow.triangle.branch")
                    .labelStyle(.titleAndIcon)
                    .font(.btChatCaption)
                    .foregroundStyle(Color.btTextTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(branch)
            }
            Spacer(minLength: Space.md)
            RevundComposerStatus(sessionId: session.id)
            if let totals, totals.additions + totals.deletions > 0 {
                Button { model.openDiffTab(in: session.id) } label: {
                    DiffCounts(additions: totals.additions, deletions: totals.deletions, hideZeros: true)
                }
                .buttonStyle(.plain)
                .help("Review changes")
            }
        }
        .frame(height: 18)
        // Re-read after each tool result and at each status change; a short
        // pause lets bursts of edits settle into one read.
        .task(id: "\(session.status.rawValue)-\(resultCount)") {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, case .ready(let context) = model.diffAvailability(session.id) else { totals = nil; return }
            let files = (try? await Diff.collect(context.executor, worktree: context.worktree, exclude: context.exclude)) ?? []
            totals = (files.reduce(0) { $0 + $1.additions }, files.reduce(0) { $0 + $1.deletions })
        }
    }

    private var resultCount: Int { model.feed(session.id).toolResults }
}

/// The chat's agent, model and effort as quiet menus, plus how much it may do.
/// Changing one applies from the next message.
private struct AgentControls: View {
    @Environment(AppModel.self) private var model
    let session: Session
    @Binding var attachments: [PromptAttachment]

    var body: some View {
        HStack(spacing: 2) {
            AttachUploadButton(attachments: $attachments)
            CompactMenu(title: ProviderRegistry.name(session.providerId), logo: session.providerId) {
                Picker("Agent", selection: Binding(get: { session.providerId }, set: { new in
                    model.setAgent(session.id, providerId: new, model: nil, effort: nil)
                })) {
                    ForEach(ProviderRegistry.all, id: \.id) { p in Text(p.name).tag(p.id) }
                }
                .pickerStyle(.inline)
                Divider()
                Text("Another agent starts fresh in this worktree.")
            }
            let device = RemoteService.split(session.id)?.device
            ModelMenu(providerId: session.providerId, modelId: Binding(get: { session.model }, set: { new in
                let levels = model.efforts(providerId: session.providerId, model: new, on: device).levels
                model.setAgent(session.id, providerId: session.providerId, model: new,
                               effort: session.effort.flatMap { levels.contains($0) ? $0 : nil })
            }), device: device)
            EffortMenu(providerId: session.providerId, modelId: session.model, effort: Binding(get: { session.effort }, set: { new in
                model.setAgent(session.id, providerId: session.providerId, model: session.model, effort: new)
            }), device: device)
            CompactMenu(title: session.permissionPolicy.title) {
                Picker("Mode", selection: Binding(get: { session.permissionPolicy }, set: { model.setPolicy(session.id, $0) })) {
                    ForEach(PermissionPolicy.allCases, id: \.self) { p in Text(p.title).tag(p) }
                }
                .pickerStyle(.inline)
                Divider()
                Text(session.permissionPolicy.detail)
            }
            .help("How much the agent may do without asking")
            if model.needsRelaunch.contains(session.id) {
                Text("· applies to your next message")
                    .font(.btChatCaption)
                    .foregroundStyle(Color.btTextTertiary)
            }
        }
        .lineLimit(1)
    }
}
