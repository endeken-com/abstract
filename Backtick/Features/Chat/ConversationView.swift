import SwiftUI
import Textual
import BacktickCore

/// Agent output as a readable document. Prose is rendered Markdown at a
/// reading size, tool activity folds into compact cards, edits carry an
/// inline diff, and only a permission request raises its voice.
struct ConversationView: View {
    @Environment(AppModel.self) private var model
    let session: Session
    @State private var atBottom = true

    var body: some View {
        let blocks = model.timeline(session.id).blocks
        let permissions = model.pendingPermissions(session.id)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(blocks) { block in
                        BlockView(block: block, providerId: session.providerId)
                            .id(block.id)
                    }
                    ForEach(permissions) { p in
                        PermissionCard(sessionId: session.id, providerId: session.providerId, request: p)
                            .transition(.scale(scale: 0.97).combined(with: .opacity))
                    }
                    if session.status == .running || session.status == .provisioning, permissions.isEmpty {
                        WorkingIndicator(session: session, last: model.timeline(session.id).last)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: Space.readingWidth, alignment: .leading)
                .padding(.horizontal, Space.xxl)
                .padding(.top, Space.xl)
                .padding(.bottom, Space.lg)
                .frame(maxWidth: .infinity)
                .animation(.snappy(duration: 0.25), value: permissions)
            }
            .defaultScrollAnchor(.top, for: .alignment)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height < 80
            } action: { _, near in
                atBottom = near
            }
            .overlay(alignment: .bottom) {
                if !atBottom {
                    Button { withAnimation(.snappy) { proxy.scrollTo("bottom", anchor: .bottom) } } label: {
                        Label("Latest", systemImage: "arrow.down").font(.btCaptionMedium)
                            .padding(.horizontal, 12).frame(height: 28)
                            .btRaised(radius: 14)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, Space.md)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.2), value: atBottom)
        }
    }
}

// MARK: - Blocks

private struct BlockView: View {
    let block: TimelineBlock
    let providerId: String

    var body: some View {
        switch block {
        case let .user(_, text):
            UserBubble(text: text)
        case let .assistant(_, text, _, opensTurn):
            VStack(alignment: .leading, spacing: Space.sm) {
                if opensTurn {
                    HStack(spacing: Space.sm) {
                        ProviderAvatar(providerId: providerId, size: 22)
                        Text(ProviderRegistry.name(providerId)).font(.btBodyMedium).foregroundStyle(Color.btTextSecondary)
                    }
                }
                AgentProse(markdown: text)
            }
        case let .thinking(_, text):
            ThinkingView(text: text)
        case let .tools(_, calls):
            ToolGroupView(calls: calls)
        case let .system(_, model, mode):
            if model != nil || mode != nil {
                HStack(spacing: 6) {
                    Image(systemName: "cpu").font(.system(size: 10))
                    Text([model, mode].compactMap { $0 }.joined(separator: " · ")).font(.btMonoSmall)
                }
                .foregroundStyle(Color.btTextTertiary)
                .frame(maxWidth: .infinity)
            }
        case let .turn(_, summary, duration, usage, cost):
            TurnSummary(summary: summary, durationMs: duration, usage: usage, cost: cost)
        case let .error(_, message):
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.btRemoved).font(.system(size: 12))
                Text(message).font(.btBody).foregroundStyle(Color.btText).lineSpacing(2).textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .btLeadingRule(Color.btRemoved)
        case let .raw(_, lines):
            RawLinesView(lines: lines)
        }
    }
}

private struct UserBubble: View {
    let text: String
    var body: some View {
        HStack {
            Spacer(minLength: 80)
            Text(text)
                .font(.system(size: 13.5))
                .lineSpacing(3)
                .foregroundStyle(Color.btText)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.btSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

/// Markdown at a size meant for reading, with selectable text and quiet code blocks.
struct AgentProse: View {
    let markdown: String
    var body: some View {
        StructuredText(markdown: markdown)
            .font(.btProse)
            .foregroundStyle(Color.btText)
            .textual.structuredTextStyle(.gitHub)
            .textual.codeBlockStyle(BTCodeBlockStyle())
            .textual.inlineStyle(
                InlineStyle()
                    .code(.monospaced, .fontScale(0.88), .backgroundColor(Color.btInset))
                    .link(.foregroundColor(Color.accentColor))
            )
            .textual.textSelection(.enabled)
            .lineSpacing(3.5)
    }
}

struct BTCodeBlockStyle: StructuredText.CodeBlockStyle {
    func makeBody(configuration: Configuration) -> some View {
        CodeBlockChrome(configuration: configuration)
    }
}

private struct CodeBlockChrome: View {
    let configuration: StructuredText.CodeBlockStyleConfiguration
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let lang = configuration.languageHint, !lang.isEmpty {
                Text(lang).font(.btCaption).foregroundStyle(Color.btTextTertiary)
                    .padding(.horizontal, 14).padding(.top, 9)
            }
            Overflow {
                configuration.label
                    .textual.lineSpacing(.fontScaled(0.3))
                    .textual.fontScale(0.86)
                    .monospaced()
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

private struct ThinkingView: View {
    let text: String
    @State private var open = false
    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Button { withAnimation(.snappy) { open.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain").font(.system(size: 11))
                    Text("Thought process")
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(open ? 90 : 0))
                }
                .font(.btCallout)
                .foregroundStyle(Color.btTextTertiary)
            }
            .buttonStyle(.plain)
            if open {
                Text(text).font(.btCallout).foregroundStyle(Color.btTextSecondary).lineSpacing(3).textSelection(.enabled)
                    .btLeadingRule()
            }
        }
    }
}

private struct TurnSummary: View {
    let summary: String?
    let durationMs: Int?
    let usage: UsageTotals?
    let cost: Double?

    var body: some View {
        let stats = [
            durationMs.map { RelativeTime.duration($0) },
            usage.map { "\(RelativeTime.tokens($0.inputTokens + $0.cacheRead + $0.cacheWrite)) in · \(RelativeTime.tokens($0.outputTokens)) out" },
            cost.flatMap { $0 > 0 ? String(format: "$%.2f", $0) : nil },
        ].compactMap { $0 }
        if summary != nil || !stats.isEmpty {
            HStack(spacing: Space.md) {
                Hairline()
                HStack(spacing: 6) {
                    Image(systemName: "checkmark").foregroundStyle(Color.btAdded).font(.system(size: 10, weight: .bold))
                    if let summary { Text(summary).foregroundStyle(Color.btTextSecondary) }
                    if !stats.isEmpty { Text(stats.joined(separator: " · ")).foregroundStyle(Color.btTextTertiary).monospacedDigit() }
                }
                .font(.btCaption)
                .lineLimit(1)
                .fixedSize()
                Hairline()
            }
            .padding(.vertical, Space.xs)
        }
    }
}

private struct RawLinesView: View {
    let lines: [OutputLine]
    @State private var open = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.snappy) { open.toggle() } } label: {
                Label("\(lines.count) unparsed line\(lines.count == 1 ? "" : "s")", systemImage: "chevron.right")
                    .font(.btCaption).foregroundStyle(Color.btTextTertiary)
            }
            .buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                        Text(l.line).font(.btMonoSmall).foregroundStyle(l.stream == .stderr ? Color.btWarning : Color.btTextSecondary)
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
    let last: AgentEvent?
    @Environment(AppModel.self) private var model

    var body: some View {
        if case .text(_, _, _, true)? = last { EmptyView() } else {
            SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: Space.sm) {
                    ProgressView().controlSize(.small)
                    Text(label).font(.btCallout.weight(.medium)).foregroundStyle(Color.btTextSecondary)
                    if let start = model.turnStartedAt[session.id] {
                        Text(RelativeTime.duration(Int(context.date.timeIntervalSince(start) * 1000)))
                            .font(.btCallout).foregroundStyle(Color.btTextTertiary).monospacedDigit()
                    }
                }
            }
        }
    }

    private var label: String {
        switch last {
        case .toolUse(_, let name, _, _)?: "Running \(name)…"
        case .toolResult?: "Thinking…"
        default: "Working…"
        }
    }
}
