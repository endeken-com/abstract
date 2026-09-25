import SwiftUI
import AbstractCore

/// The reply box. Return breaks the line, Command-Return sends, and the send
/// button turns into Stop while the agent works.
struct ComposerView: View {
    @Environment(AppModel.self) private var model
    let session: Session
    @State private var draft = ""
    @State private var previewingMarkdown = false
    @State private var markdownHeight: CGFloat = 20
    @FocusState private var focused: Bool

    private var working: Bool { session.status == .running || session.status == .provisioning }
    /// `abstract` drives the chat: nothing goes to its agent from here.
    private var readOnly: Bool { model.isDrivenFromCLI(session.id) }
    /// Its agent starts once it's set up; its first message is already there.
    private var settingUp: Bool { model.setups[session.id] != nil }
    private var suggestion: String? { working ? nil : model.feed(session.id).suggestion }
    /// A review or attachments can go on their own; otherwise there must be something typed.
    private var canSend: Bool {
        !readOnly && !settingUp && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.comments(session.id).isEmpty || !attachments.isEmpty)
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
                    // Tab takes it; Markdown stays literal until Preview is opened.
                    if previewingMarkdown {
                        ScrollView {
                            AgentProse(markdown: draft)
                                .environment(\.proseStyle, ProseStyle(size: .small))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { markdownHeight = $0 }
                        }
                        .frame(height: min(max(markdownHeight, 20), 180))
                        .padding(.vertical, 7)
                    } else {
                        TextField(text: $draft, prompt: Text(settingUp ? "Setting up the chat…" : readOnly ? "Driven from the command line" : suggestion ?? "Reply to \(ProviderRegistry.name(session.providerId))…"), axis: .vertical) {
                            Text("Reply")
                        }
                            .disabled(readOnly || settingUp)
                            .textFieldStyle(.plain)
                            .font(BTFont.chat(13.5))
                            .onKeyPress(.tab) {
                                guard draft.isEmpty, let suggestion else { return .ignored }
                                draft = suggestion
                                return .handled
                            }
                            .returnBreaksLine(commandReturn: send)
                            .lineSpacing(2)
                            .lineLimit(1...10)
                            .focused($focused)
                            .padding(.vertical, 7)
                    }

                    AttachmentButtons(repoRoot: repoRoot, sessionId: session.id, attachments: attachmentsBinding)
                        .disabled(readOnly || settingUp)

                    if !draft.isEmpty {
                        Button(previewingMarkdown ? "Edit" : "Preview") {
                            previewingMarkdown.toggle()
                            if !previewingMarkdown { focused = true }
                        }
                        .buttonStyle(.plain)
                        .font(.btChatCaption)
                        .foregroundStyle(Color.btTextSecondary)
                        .frame(height: 26)
                        .help(previewingMarkdown ? "Edit Markdown" : "Preview Markdown")
                    }

                    // The send button becomes Stop while the agent works.
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
                            // The shortcut that sends, as the button's face: ⌘↩.
                            HStack(spacing: 1) {
                                Image(systemName: "command")
                                Image(systemName: "return")
                            }
                                .font(.system(size: 11, weight: .regular))
                                .foregroundStyle(canSend ? Color.btText : Color.btTextTertiary)
                                .padding(.horizontal, 4)
                                .frame(minWidth: 26, minHeight: 26)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSend)
                        .help("Send (⌘↩)")
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
            Group {
                if readOnly {
                    Label("Its agent is working from the command line. The chat is yours when this turn ends, or Stop it now.",
                          systemImage: "terminal")
                        .font(.btChatCaption)
                        .foregroundStyle(Color.btTextTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                } else {
                    AgentControls(session: session, attachments: attachmentsBinding)
                }
            }
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
        previewingMarkdown = false
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
            BackgroundTasksChip(sessionId: session.id)
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
            let device = RemoteService.split(session.id)?.device
            CompactMenu(title: ProviderRegistry.name(session.providerId), logo: session.providerId) {
                Picker("Agent", selection: Binding(get: { session.providerId }, set: { new in
                    model.setAgent(session.id, providerId: new, model: nil, effort: nil)
                })) {
                    ForEach(model.pickableAgents(on: device, keeping: session.providerId), id: \.id) { p in Text(p.name).tag(p.id) }
                }
                .pickerStyle(.inline)
                Divider()
                Text("Another agent gets a summary of this chat with your next message.")
            }
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
                Text(ProviderRegistry.provider(session.providerId)?.permissionDetail(session.permissionPolicy)
                     ?? session.permissionPolicy.detail)
            }
            .help("How much the agent may do without asking")
            if model.needsRelaunch.contains(session.id) {
                // Restarting would end them, so the change waits for them.
                Text(model.runningBackgroundTasks(session.id) > 0 ? "· applies once background tasks end" : "· applies to your next message")
                    .font(.btChatCaption)
                    .foregroundStyle(Color.btTextTertiary)
            }
        }
        .lineLimit(1)
    }
}
