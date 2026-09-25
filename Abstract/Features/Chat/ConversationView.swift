import SwiftUI
import Textual
import AbstractCore

/// Agent output as a readable document. Prose is rendered Markdown at a
/// reading size, tool activity folds into compact cards, edits carry an
/// inline diff, and only a permission request raises its voice.
struct ConversationView: View {
    @Environment(AppModel.self) private var model
    let session: Session
    @State private var atBottom = true
    /// Bumped to send the transcript to its end and follow it again.
    @State private var jump = 0
    @AppStorage("chat.font") private var chatFont: ChatFont = .inter
    @AppStorage("chat.textSize") private var chatSize: ChatTextSize = .medium
    @AppStorage("chat.transcript") private var transcript: TranscriptMode = .normal

    var body: some View {
        // Reads only what changes when a call starts or ends; the rows
        // themselves are observed by the list, a row at a time.
        let feed = model.feed(session.id)
        let permissions = model.pendingPermissions(session.id)
        let approvals = ToolSegment.approvals(for: feed.calls, pending: permissions)
        let matched = Set(approvals.values.map(\.requestId))
        let working = session.status == .running || session.status == .provisioning
        let context = TranscriptContext(sessionId: session.id, working: working, approvals: approvals,
                                        latestTodoCallId: feed.calls.last { ToolKind($0.name) == .todo }?.id,
                                        prose: ProseStyle(font: chatFont, size: chatSize), transcript: transcript)
        TranscriptList(feed: feed, context: context, jump: jump, atBottom: $atBottom) {
            VStack(alignment: .leading, spacing: 20) {
                // Approvals Claude asked for without sending the call first.
                ForEach(permissions.filter { !matched.contains($0.requestId) }) { p in
                    PermissionCard(sessionId: session.id, request: p)
                        .transition(.opacity)
                }
                if let setup = model.setups[session.id] {
                    ChatSetupCard(session: session, setup: setup)
                } else if working, permissions.isEmpty {
                    WorkingIndicator(session: session, feed: feed)
                }
                if !working, feed.turns > 0, model.setups[session.id] == nil {
                    ChatChangesSummary(session: session, turnKey: feed.turns)
                }
            }
            .padding(.top, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.snappy(duration: 0.25), value: permissions)
        }
        .overlay(alignment: .bottom) {
            if !atBottom {
                Button {
                    jump += 1
                } label: {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.btTextSecondary)
                        .frame(width: 26, height: 26)
                        .background(Color.btSurfaceRaised, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Jump to the latest")
                .padding(.bottom, Space.md)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.2), value: atBottom)
    }
}

// MARK: - Rows

/// Which rows a transcript shows, and the room between them: tight within a
/// run of tool activity and within one reply, wider where the speaker
/// changes. After Paseo's stream spacing (Apache-2.0, Copyright (c)
/// 2025-present Mohamed Boudra).
enum TranscriptRows {
    static func shows(_ row: ChatRow, _ mode: TranscriptMode) -> Bool {
        switch row.block {
        case .system: false
        case .thinking: mode.showsThinking
        case .raw: UserDefaults.standard.bool(forKey: "showRawAgentOutput")
        default: true
        }
    }

    /// A row's words, for copying a selection that runs through it.
    static func plainText(_ block: TimelineBlock) -> String {
        switch block {
        case let .user(_, text): return PromptAttachments.split(text).text
        case let .assistant(_, text, _, _): return text
        case let .thinking(_, text): return text
        case let .tools(_, calls):
            return calls.map { call in
                let target = ToolPresentation.command(call).map { TextClip.line($0) } ?? ToolPresentation.path(call) ?? ""
                return [ToolPresentation.verb(call.name), target].filter { !$0.isEmpty }.joined(separator: " ")
            }.joined(separator: "\n")
        case let .turn(_, summary, _, _, _): return summary ?? ""
        case let .error(_, message): return message
        case let .handoff(_, from, to, summary, _):
            return (["Handed over from \(ProviderRegistry.name(from)) to \(ProviderRegistry.name(to))"] + [summary].compactMap { $0 })
                .joined(separator: "\n")
        default: return ""
        }
    }

    static func gap(_ above: ChatRow, _ below: ChatRow) -> CGFloat {
        switch (above.block, below.block) {
        case (.user, .user): return 6
        case (_, .user): return 28
        case (.user, _): return 20
        case let (.assistant, .assistant(_, text, _, _)) where below.continues:
            // The next block of the same reply: a paragraph's space, a heading a little more.
            return text.hasPrefix("#") ? 22 : 14
        // Tool activity reads as one tight stack, a run of calls as lines.
        case (.tools, .tools) where below.continues: return 2
        case (.tools, .tools), (.thinking, .thinking), (.tools, .thinking), (.thinking, .tools): return 6
        case (.turn, _), (_, .turn): return 16
        default: return 14
        }
    }
}

// MARK: - Blocks

/// One transcript row's content. Equatable, so an unchanged row never redraws.
struct BlockView: View, Equatable {
    let block: TimelineBlock
    let sessionId: String
    /// The newest block of a working chat, which may still grow.
    let live: Bool

    var body: some View {
        switch block {
        case let .user(_, text):
            UserBubble(text: text)
        case let .assistant(_, text, streaming, _):
            // One agent per chat, so its name on every turn is noise.
            // The fade only for text still arriving: finished text draws the
            // fast way (a custom text renderer draws through Core Graphics,
            // which stalls a scroll that brings many rows in at once).
            AgentProse(markdown: text, streaming: streaming || live ? streaming : nil)
        case let .thinking(_, text):
            ThinkingView(text: text, streaming: live)
        case let .tools(_, calls):
            ToolGroupView(sessionId: sessionId, calls: calls)
        case .system:
            // The model and mode are in the composer footer already.
            EmptyView()
        case let .turn(_, summary, duration, usage, cost):
            TurnSummary(summary: summary, durationMs: duration, usage: usage, cost: cost)
        case let .error(_, message):
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.btRemoved).font(.system(size: 12, weight: .light))
                    SelectableText(TextClip.block(message)).font(.btChatBody).foregroundStyle(Color.btText).lineSpacing(2)
                    Spacer(minLength: 0)
                }
                // Claude's sign-in ran out: sign in again, or carry on with another account.
                if ClaudeAccounts.isSignInFailure(message) { SignInActions(sessionId: sessionId) }
                // Out of room: another agent picks the chat up.
                if LimitDetector.classify(message) != nil { ContinueWithActions(sessionId: sessionId) }
            }
            .btLeadingRule(Color.btRemoved)
        case let .raw(_, lines):
            // Frames no parser understood are debugging material, not
            // conversation. Settings › General can bring them back.
            if UserDefaults.standard.bool(forKey: "showRawAgentOutput") { RawLinesView(lines: lines) }
        case let .handoff(_, from, to, summary, source):
            HandoffRow(from: from, to: to, summary: summary, source: source)
        }
    }
}

private struct SignInActions: View {
    @Environment(AppModel.self) private var model
    let sessionId: String

    var body: some View {
        HStack(spacing: Space.sm) {
            Button("Sign In…") { model.signInToClaude(for: sessionId) }
                .buttonStyle(.bt(.secondary, size: .small))
                .help("Open a terminal that signs this chat's Claude account in again")
            Button("Switch Account…") {
                UserDefaults.standard.set("usage", forKey: "settingsTab")
                model.isSettingsOpen = true
            }
            .buttonStyle(.bt(.ghost, size: .small))
            .help("Pick another Claude account; the chat carries on there")
        }
    }
}

/// A limit stopped the agent: carry on with another one.
private struct ContinueWithActions: View {
    @Environment(AppModel.self) private var model
    let sessionId: String

    var body: some View {
        let current = model.session(sessionId)?.providerId
        Menu("Continue with…") {
            ForEach(model.pickableAgents(on: RemoteService.split(sessionId)?.device).filter { $0.id != current }, id: \.id) { p in
                Button(p.name) { model.continueWith(sessionId, providerId: p.id) }
            }
        }
        .menuStyle(.button)
        .buttonStyle(.bt(.secondary, size: .small))
        .fixedSize()
        .help("Hand this chat to another agent, with a summary and the transcript")
    }
}

/// Where the chat passed to another agent, with the note it was given.
private struct HandoffRow: View {
    @Environment(\.transcriptExpansion) private var expansion
    @Environment(\.transcriptRow) private var row
    let from: String
    let to: String
    let summary: String?
    let source: HandoffSource?
    @State private var local = false

    var body: some View {
        let open = ExpansionSwitch(key: "handoff:\(row?.id ?? 0)", expansion: expansion, row: row)
        let isOpen = open.value(local: local) ?? false
        VStack(alignment: .leading, spacing: Space.sm) {
            Button {
                if !open.set(!isOpen) { local.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.left.arrow.right").font(.system(size: 10, weight: .medium))
                    Text("Handed over from \(ProviderRegistry.name(from)) to \(ProviderRegistry.name(to))")
                    if summary != nil {
                        Image(systemName: isOpen ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.btChatCaption)
            .foregroundStyle(Color.btTextTertiary)
            .disabled(summary == nil)
            if isOpen, let summary {
                VStack(alignment: .leading, spacing: 4) {
                    SelectableText(TextClip.block(summary)).font(.btChatBody).foregroundStyle(Color.btTextSecondary).lineSpacing(2)
                    if source == .app {
                        Text("Summary by Backtick; \(ProviderRegistry.name(from)) couldn't write one.")
                            .font(.btChatCaption).foregroundStyle(Color.btTextTertiary)
                    }
                }
                .btLeadingRule(Color.btTextTertiary.opacity(0.4))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct UserBubble: View {
    @Environment(\.proseStyle) private var prose
    @Environment(\.transcriptExpansion) private var expansion
    @Environment(\.transcriptRow) private var row
    let text: String
    @State private var local = false

    /// Past this a message folds, with Show more.
    private static let foldLines = 18
    private static let foldCharacters = 1_600

    var body: some View {
        // Attachments show as chips under what was typed.
        let (typed, chips) = PromptAttachments.split(text)
        VStack(alignment: .trailing, spacing: 6) {
            if !typed.isEmpty { bubble(typed) }
            if !chips.isEmpty {
                HStack {
                    Spacer(minLength: 80)
                    AttachmentChips(chips: chips)
                }
            }
        }
    }

    private var openSwitch: ExpansionSwitch { ExpansionSwitch(key: "user:\(row?.id ?? 0)", expansion: expansion, row: row) }

    private func bubble(_ text: String) -> some View {
        // A very long message folds. Keep unusually large expanded pastes as
        // separate plain lines so a single Markdown parse cannot stall the list.
        let paragraphs = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let long = paragraphs.count > Self.foldLines || text.count > Self.foldCharacters
        let open = openSwitch.value(local: local) ?? false
        let shown = long && !open ? Self.fold(paragraphs) : Array(paragraphs.prefix(2_000))
        let shownText = shown.joined(separator: "\n")
        return HStack {
            Spacer(minLength: 80)
            VStack(alignment: .leading, spacing: prose.lineSpacing - 1) {
                if shownText.count <= 24_000 {
                    AgentProse(markdown: long && !open ? MarkdownHealing.heal(shownText) : shownText)
                } else {
                    SelectableLines(shown.map { TextClip.line($0, max: 4_000) }, spacing: prose.lineSpacing - 1)
                        .font(prose.font(size: prose.points - 1))
                        .lineSpacing(prose.lineSpacing - 1)
                        .foregroundStyle(Color.btText)
                }
                if long {
                    Button(open ? "Show less" : "Show more") {
                        if !openSwitch.set(!open) { local.toggle() }
                    }
                    .buttonStyle(.plain)
                    .font(.btChatCaption)
                    .foregroundStyle(Color.btTextTertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            // Paseo's bubble: round, but for the corner nearest the edge it's said from.
            .background(Color.btSurface, in: UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16,
                                                                      bottomTrailingRadius: 16, topTrailingRadius: 4, style: .continuous))
        }
    }

    /// The first lines of a long message, within the fold's length.
    private static func fold(_ paragraphs: [String]) -> [String] {
        var out: [String] = []
        var count = 0
        for paragraph in paragraphs.prefix(foldLines) {
            if count + paragraph.count > foldCharacters {
                out.append(String(paragraph.prefix(max(0, foldCharacters - count))) + "…")
                break
            }
            out.append(paragraph)
            count += paragraph.count
        }
        return out
    }
}

/// Markdown at a size meant for reading, with selectable text and quiet code blocks.
struct AgentProse: View {
    @Environment(\.proseStyle) private var prose
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let markdown: String
    /// A reply as it streams: new text fades in. Nil for prose that never streams.
    var streaming: Bool?
    @State private var fade = StreamFade()
    @State private var tick = 0.0

    var body: some View {
        if let streaming, !reduceMotion {
            Revealing(text: markdown, streaming: streaming) { shown, catchingUp in
                let partial = streaming || catchingUp
                styled(StructuredText(partial ? MarkdownHealing.heal(shown) : shown, parser: StreamFadeParser(fade: fade, live: partial)))
                    .textRenderer(StreamFadeRenderer(fade: fade, tick: tick))
                    // Redraws for as long as the newest characters take to fade in.
                    .onChange(of: shown) { withAnimation(.linear(duration: StreamFade.duration)) { tick += 1 } }
            }
        } else {
            styled(StructuredText(markdown: markdown))
        }
    }

    private func styled(_ text: StructuredText) -> some View {
        text
            .font(prose.body)
            .foregroundStyle(Color.btProse)
            .textual.structuredTextStyle(.gitHub)
            .textual.codeBlockStyle(BTCodeBlockStyle())
            .textual.inlineStyle(
                InlineStyle()
                    .code(.font(BTFont.chatMono((prose.points * 0.87).rounded())), .backgroundColor(Color.btHover))
                    .link(.foregroundColor(Color.btText), .underlineStyle(.single))
            )
            .textual.textSelection(.enabled)
            .lineSpacing(prose.lineSpacing)
    }
}

struct BTCodeBlockStyle: StructuredText.CodeBlockStyle {
    func makeBody(configuration: Configuration) -> some View {
        CodeBlockChrome(configuration: configuration)
    }
}

private struct CodeBlockChrome: View {
    @Environment(\.proseStyle) private var prose
    let configuration: StructuredText.CodeBlockStyleConfiguration
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let lang = configuration.languageHint, !lang.isEmpty {
                Text(lang).font(.btChatCaption).foregroundStyle(Color.btTextTertiary)
                    .padding(.horizontal, 14).padding(.top, 9)
            }
            Overflow {
                configuration.label
                    .font(BTFont.chatMono((prose.points * 0.84).rounded()))
                    .textual.lineSpacing(.fontScaled(0.35))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            }
        }
        .background(Color.btCode, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button {
                    configuration.codeBlock.copyToPasteboard()
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
                } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
                    .buttonStyle(.icon(size: 26))
                    .padding(6)
                    .help("Copy code")
            }
        }
        .onHover { hovering = $0 }
        .textual.blockSpacing(.init(top: 4, bottom: 14))
    }
}

/// The agent's thinking, shown in the Thinking and Verbose transcripts:
/// quieter, smaller and italic, under a small label so it reads as the
/// agent thinking, not a quoted passage. It streams like a reply.
private struct ThinkingView: View {
    @Environment(\.proseStyle) private var prose
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let text: String
    let streaming: Bool
    @State private var fade = StreamFade()
    @State private var tick = 0.0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(streaming ? "Thinking" : "Thought")
                .font(.btChatCaption)
                .foregroundStyle(Color.btTextTertiary)
            if streaming, !reduceMotion {
                Revealing(text: text.trimmingCharacters(in: .whitespacesAndNewlines), streaming: true) { shown, _ in
                    Text(shown)
                        .font(prose.font(size: prose.points - 1.5).italic())
                        .foregroundStyle(Color.btTextTertiary)
                        .lineSpacing(prose.lineSpacing - 2)
                        .textSelection(.enabled)
                        .textRenderer(StreamFadeRenderer(fade: fade, tick: tick))
                        .onChange(of: shown) {
                            fade.record(length: shown.utf16.count)
                            withAnimation(.linear(duration: StreamFade.duration)) { tick += 1 }
                        }
                }
            } else {
                SelectableText(text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(prose.font(size: prose.points - 1.5).italic())
                    .foregroundStyle(Color.btTextTertiary)
                    .lineSpacing(prose.lineSpacing - 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The end of a turn as a quiet rule: what was done and how long it took.
/// Token counts and cost are subscription noise, so they wait in the tooltip.
private struct TurnSummary: View {
    let summary: String?
    let durationMs: Int?
    let usage: UsageTotals?
    let cost: Double?

    var body: some View {
        let label = [summary, durationMs.map { RelativeTime.duration($0) }].compactMap { $0 }.joined(separator: " · ")
        let details = [
            usage.map { "\(RelativeTime.tokens($0.inputTokens + $0.cacheRead + $0.cacheWrite)) in, \(RelativeTime.tokens($0.outputTokens)) out" },
            cost.flatMap { $0 > 0 ? String(format: "$%.2f", $0) : nil },
        ].compactMap { $0 }.joined(separator: " · ")
        if !label.isEmpty {
            HStack(spacing: Space.md) {
                Hairline()
                Text(label)
                    .font(.btChatCaption)
                    .foregroundStyle(Color.btTextTertiary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                Hairline()
            }
            .padding(.vertical, Space.xs)
            .help(details)
        }
    }
}

private struct RawLinesView: View {
    @Environment(\.transcriptExpansion) private var expansion
    @Environment(\.transcriptRow) private var row
    let lines: [OutputLine]
    @State private var local = false
    private var openSwitch: ExpansionSwitch { ExpansionSwitch(key: "raw:\(row?.id ?? 0)", expansion: expansion, row: row) }
    private var open: Bool { openSwitch.value(local: local) ?? false }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { if !openSwitch.set(!open) { withAnimation(.snappy) { local.toggle() } } } label: {
                Label("\(lines.count) unparsed line\(lines.count == 1 ? "" : "s")", systemImage: "chevron.right")
                    .font(.btChatCaption).foregroundStyle(Color.btTextTertiary)
            }
            .buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                        Text(l.line).font(.btChatMonoSmall).foregroundStyle(l.stream == .stderr ? Color.btWarning : Color.btTextSecondary)
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .btLeadingRule()
            }
        }
    }
}

private struct WorkingIndicator: View {
    let session: Session
    let feed: ChatFeed
    private var last: AgentEvent? { feed.last }
    @Environment(AppModel.self) private var model
    @Environment(\.transcriptMode) private var transcript

    var body: some View {
        // Streaming text, running tool rows and shown thinking already show the agent at work.
        if case .text(_, _, _, true)? = last { EmptyView() } else if case .toolUse? = last { EmptyView() }
        else if case .thinking? = last, transcript.showsThinking { EmptyView() } else {
            SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: Space.sm) {
                    DotLoader()
                    Text(label).font(.btChatCallout.weight(.regular)).foregroundStyle(Color.btTextSecondary)
                    if let start = model.turnStartedAt[session.id] {
                        Text(RelativeTime.duration(Int(context.date.timeIntervalSince(start) * 1000)))
                            .font(.btChatCallout).foregroundStyle(Color.btTextTertiary).monospacedDigit()
                    }
                }
            }
        }
    }

    /// The tool row already says what's running, so this only says the turn
    /// is still going.
    private var label: String {
        switch last {
        case .toolResult?, .thinking?: "Thinking…"
        default: "Working…"
        }
    }
}

/// Six dots in two columns, lit in turn: the agent at work. After Paseo's
/// loader (Apache-2.0, Copyright (c) 2025-present Mohamed Boudra); it steps
/// six times a second inside the transcript's footer row only.
private struct DotLoader: View {
    private static let cycle = 0.95
    private static let levels: [Double] = [1, 0.7, 0.45, 0.28, 0.16, 0.16]
    /// Dot order around the grid: down the left, up the right.
    private static let order = [0, 2, 4, 5, 3, 1]

    var body: some View {
        SwiftUI.TimelineView(.periodic(from: .now, by: Self.cycle / 6)) { context in
            let step = Int(context.date.timeIntervalSinceReferenceDate / (Self.cycle / 6)) % 6
            Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                ForEach(0..<3, id: \.self) { row in
                    GridRow {
                        ForEach(0..<2, id: \.self) { column in
                            let position = Self.order.firstIndex(of: row * 2 + column) ?? 0
                            Circle()
                                .fill(Color.btTextSecondary)
                                .frame(width: 3, height: 3)
                                .opacity(Self.levels[(step - position + 6) % 6])
                        }
                    }
                }
            }
            .frame(width: 14, height: 14)
        }
    }
}
