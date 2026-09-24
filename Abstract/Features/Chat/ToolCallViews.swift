import SwiftUI
import Textual
import AbstractCore

// MARK: - Grouping

/// Consecutive tool calls, arranged the way people read them: looking around
/// folds into one "Explored" line, commands into one "Ran" line, edits carry
/// their diff, and a call waiting for your OK asks on its own row. The
/// Verbose transcript unfolds all of it.
struct ToolGroupView: View {
    @Environment(\.toolApprovals) private var approvals
    @Environment(\.transcriptMode) private var transcript
    let sessionId: String
    let calls: [ToolCall]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(ToolSegment.split(calls, asking: Set(approvals.keys), folds: !transcript.opensTools)) { segment in
                switch segment {
                case let .run(kind, run): CallRun(sessionId: sessionId, kind: kind, calls: run)
                case .single(let call): ToolCallView(sessionId: sessionId, call: call, approval: approvals[call.id])
                }
            }
        }
    }
}

enum ToolSegment: Identifiable {
    /// Two or more calls of a foldable kind (looking around, commands) in a row.
    case run(ToolKind, [ToolCall])
    case single(ToolCall)

    var id: String {
        switch self {
        case let .run(kind, calls): "\(kind)-" + (calls.first?.id ?? "")
        case .single(let call): call.id
        }
    }

    /// Two or more look-around calls, or commands, in a row fold into one
    /// line; everything else, and anything waiting for an answer, stands on
    /// its own.
    static func split(_ calls: [ToolCall], asking: Set<String>, folds: Bool = true) -> [ToolSegment] {
        var out: [ToolSegment] = []
        var run: [ToolCall] = []
        var runKind: ToolKind?
        func flush() {
            if run.count >= 2, let runKind { out.append(.run(runKind, run)) } else { out += run.map { .single($0) } }
            run = []
            runKind = nil
        }
        for call in calls {
            let kind = ToolKind(call.name)
            if folds, kind == .explore || kind == .command, !asking.contains(call.id) {
                if kind != runKind { flush() }
                runKind = kind
                run.append(call)
            } else {
                flush()
                out.append(.single(call))
            }
        }
        flush()
        return out
    }

    /// Pending approvals matched to the calls they are for, by call id: same
    /// tool and input, no result yet, newest calls first. Claude sends the
    /// call before asking, so the question can sit on the call's own row.
    static func approvals(for calls: [ToolCall], pending: [PendingPermission]) -> [String: PendingPermission] {
        var out: [String: PendingPermission] = [:]
        var open = calls.filter { $0.result == nil }.reversed().map { $0 }
        for request in pending {
            guard let i = open.firstIndex(where: { $0.name == request.toolName && $0.input == request.input })
                    ?? open.firstIndex(where: { $0.name == request.toolName }) else { continue }
            out[open.remove(at: i).id] = request
        }
        return out
    }
}

/// What a tool is for, which decides how it reads.
enum ToolKind: Equatable {
    case explore, edit, command, todo, plan, delegate, question, other

    init(_ name: String) {
        switch name.lowercased() {
        case "read", "grep", "glob", "ls", "notebookread", "toolsearch", "websearch", "web_search", "webfetch": self = .explore
        case "edit", "multiedit", "write", "notebookedit", "applypatch", "apply_patch", "file_change": self = .edit
        case "bash", "shell", "command_execution", "bashoutput": self = .command
        case "todowrite", "todolist", "todo_list": self = .todo
        case "exitplanmode": self = .plan
        case "task", "agent": self = .delegate
        case "askuserquestion": self = .question
        default: self = .other
        }
    }
}

/// How a call ended, in words a person would use.
enum ToolOutcome: Equatable {
    case running, done, skipped, blocked, failed(String?)

    init(_ call: ToolCall) {
        guard let result = call.result else { self = .running; return }
        guard result.isError else { self = .done; return }
        let text = result.output
        if text.contains("Denied by user") || text.localizedCaseInsensitiveContains("doesn't want to proceed")
            || text.localizedCaseInsensitiveContains("user rejected") {
            self = .skipped
        } else if text.localizedCaseInsensitiveContains("requires approval") || text.localizedCaseInsensitiveContains("permission to use") {
            self = .blocked
        } else {
            self = .failed(text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty })
        }
    }

    var isFailure: Bool { if case .failed = self { true } else { false } }

    var label: String? {
        switch self {
        case .running, .done: nil
        case .skipped: "Skipped"
        case .blocked: "Not allowed"
        case .failed: "Failed"
        }
    }
}

// MARK: - One call

/// A tool call as one line, with whatever makes it understandable beneath:
/// the diff of an edit, the plan, the checklist, or (on request) the output.
struct ToolCallView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.latestTodoCallId) private var latestTodoCallId
    @Environment(\.transcriptMode) private var transcript
    let sessionId: String
    let call: ToolCall
    var approval: PendingPermission? = nil
    @Environment(\.transcriptExpansion) private var expansion
    @Environment(\.transcriptRow) private var row
    @State private var open: Bool?
    @State private var hovering = false
    @State private var answered = false

    private var kind: ToolKind { ToolKind(call.name) }
    private var outcome: ToolOutcome { ToolOutcome(call) }
    private var openSwitch: ExpansionSwitch { ExpansionSwitch(key: "call:\(call.id)", expansion: expansion, row: row) }
    private var answeredSwitch: ExpansionSwitch { ExpansionSwitch(key: "answered:\(call.id)", expansion: expansion, row: row) }
    private var isAnswered: Bool { answeredSwitch.value(local: answered) ?? false }
    private var asking: Bool { approval != nil && !isAnswered }

    /// Plans and the current checklist show their content; edits (a line
    /// with their counts) and the rest open on click.
    private var isOpen: Bool {
        if let open = openSwitch.value(local: open) { return open }
        if transcript.opensTools { return true }
        switch kind {
        // What you're asked to approve shows; otherwise the counts say enough.
        case .edit: return asking
        case .plan: return true
        // Asked in the reply box's place; the row keeps what you answered.
        case .question: return !asking
        case .todo: return call.id == latestTodoCallId || asking
        case .command: return asking && ToolPresentation.command(call).map { $0.contains("\n") || $0.count > 80 } == true
        default: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isOpen {
                details
                    .padding(.top, 4)
                    .padding(.bottom, Space.sm)
                    .transition(.opacity)
            } else if kind == .command, outcome.isFailure, let result = call.result {
                // A failed command says why without a click.
                Text(ToolPresentation.head(result.output, lines: 3))
                    .font(.btChatMonoSmall)
                    .foregroundStyle(Color.btRemoved.opacity(0.85))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .padding(.bottom, Space.xs)
            }
        }
        .contextMenu { menu }
    }

    private var header: some View {
        HStack(spacing: Space.sm) {
            Button {
                        let next = !isOpen
                        if !openSwitch.set(next) { withAnimation(.snappy(duration: 0.2)) { open = next } }
                    } label: {
                HStack(spacing: 6) {
                    ToolIcon(symbol: ToolPresentation.symbol(call.name), open: isOpen, hovering: hovering && !asking, failed: outcome.isFailure,
                             file: kind == .edit ? ToolPresentation.path(call) : nil)
                    let verb = asking ? ToolPresentation.ask(call.name) : ToolPresentation.verb(call.name, pending: outcome == .running)
                    HStack(spacing: 6) {
                        Text(verb)
                            .font(.btChatToolMedium)
                            .foregroundStyle(asking || hovering ? Color.btText : Color.btTextSecondary)
                            .fixedSize()
                        ToolTargetView(target: ToolPresentation.target(call, root: model.session(sessionId)?.worktreePath), strong: asking || hovering)
                    }
                    // A call at work shimmers instead of spinning, as in Paseo.
                    .modifier(Shimmer(active: outcome == .running && !asking && approval == nil, length: verb.count + 24))
                    if let edit = call.edit, kind == .edit {
                        DiffCounts(additions: edit.additions, deletions: edit.deletions, hideZeros: true).fixedSize()
                    }
                    if kind == .todo, let progress = ToolPresentation.todoProgress(call) {
                        Text(progress).font(.btChatCaption).foregroundStyle(Color.btTextTertiary).fixedSize()
                    }
                    if let label = outcome.label, outcome != .running {
                        Text(label).font(.btChatCaption)
                            .foregroundStyle(outcome.isFailure ? Color.btRemoved : Color.btTextTertiary)
                            .fixedSize()
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }

            Spacer(minLength: Space.md)

            // A question is answered in the reply box's place.
            if asking, kind != .question {
                Button(kind == .plan ? "Keep Planning" : "Skip") { answer(false) }
                    .buttonStyle(.bt(.ghost, size: .small))
                    .help(kind == .plan ? "Stay in plan mode" : "Don't run this; the agent carries on without it")
                Button("Continue") { answer(true) }
                    .buttonStyle(.bt(.primary, size: .small))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(minHeight: asking ? 30 : 26)
        .opacity(isAnswered && call.result == nil ? 0.6 : 1)
    }

    @ViewBuilder
    private var details: some View {
        switch kind {
        case .edit:
            if let edit = call.edit { EditDiff(edit: edit, key: "diff:\(call.id)") } else { InputFields(input: call.input) }
        case .todo:
            TodoChecklist(items: ToolPresentation.todos(call.input))
        case .plan:
            if let plan = call.input["plan"]?.string {
                AgentProse(markdown: plan).btLeadingRule()
            } else {
                InputFields(input: call.input)
            }
        case .command:
            VStack(alignment: .leading, spacing: Space.sm) {
                if let command = ToolPresentation.command(call) { CodeText(command) }
                if let result = call.result, !result.output.isEmpty { OutputText(text: result.output, isError: result.isError, key: "out:\(call.id)") }
            }
        case .question:
            QuestionAnswers(questions: AgentQuestion.parse(call.input), result: call.result)
        case .delegate:
            VStack(alignment: .leading, spacing: Space.sm) {
                if let prompt = call.input["prompt"]?.string { Text(prompt).font(.btChatTool).foregroundStyle(Color.btTextSecondary).lineSpacing(3).textSelection(.enabled).btLeadingRule() }
                if let result = call.result, !result.output.isEmpty { AgentProse(markdown: result.output) }
            }
        case .explore, .other:
            VStack(alignment: .leading, spacing: Space.sm) {
                if kind == .other { InputFields(input: call.input) }
                if let result = call.result, !result.output.isEmpty { OutputText(text: result.output, isError: result.isError, key: "out:\(call.id)") }
            }
        }
    }

    @ViewBuilder
    private var menu: some View {
        if asking, kind != .question {
            Button("Always Continue for \(ToolPresentation.displayName(call.name)) in This Chat") {
                model.autoContinue(call.name, in: sessionId)
                answer(true)
            }
            Divider()
        }
        if let path = ToolPresentation.path(call) {
            let relative = ToolPresentation.relative(path, root: model.session(sessionId)?.worktreePath)
            if kind == .edit { Button("Show in Changes") { model.showChanges(relative, in: sessionId) } }
            Button("Open in Files") { model.openFile(relative, in: sessionId) }
            Button("Copy Path") { copy(path) }
        }
        if let command = ToolPresentation.command(call) { Button("Copy Command") { copy(command) } }
        if let output = call.result?.output, !output.isEmpty { Button("Copy Output") { copy(output) } }
    }

    private func answer(_ allow: Bool) {
        guard let approval else { return }
        if !answeredSwitch.set(true) { withAnimation(.snappy) { answered = true } }
        model.answerPermission(sessionId, requestId: approval.requestId, allow: allow)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Several look-around calls (reads, searches, lookups) or commands as one
/// line: "Explored 3 files, 2 searches", "Ran 3 commands". The calls
/// themselves are one click away.
private struct CallRun: View {
    @Environment(\.transcriptExpansion) private var expansion
    @Environment(\.transcriptRow) private var row
    let sessionId: String
    let kind: ToolKind
    let calls: [ToolCall]
    @State private var local = false
    @State private var hovering = false

    private var openSwitch: ExpansionSwitch { ExpansionSwitch(key: "run:\(calls.first?.id ?? "")", expansion: expansion, row: row) }
    private var open: Bool { openSwitch.value(local: local) ?? false }

    var body: some View {
        let running = calls.contains { $0.result == nil }
        let failed = calls.count { ToolOutcome($0).isFailure }
        VStack(alignment: .leading, spacing: 0) {
            Button { if !openSwitch.set(!open) { withAnimation(.snappy(duration: 0.2)) { local.toggle() } } } label: {
                HStack(spacing: 6) {
                    ToolIcon(symbol: kind == .command ? "terminal" : "magnifyingglass", open: open, hovering: hovering, failed: false)
                    HStack(spacing: 6) {
                        Text(verb(running)).font(.btChatToolMedium).foregroundStyle(hovering ? Color.btText : Color.btTextSecondary)
                        Text(summary).font(.btChatTool).foregroundStyle(hovering ? Color.btTextSecondary : Color.btTextTertiary).lineLimit(1)
                    }
                    .modifier(Shimmer(active: running, length: summary.count + 10))
                    if failed > 0 {
                        Text("\(failed) failed").font(.btChatCaption).foregroundStyle(Color.btRemoved).fixedSize()
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }

            if open {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(calls) { call in ToolCallView(sessionId: sessionId, call: call) }
                }
                .btLeadingRule(Color.btBorder, width: 1)
                .transition(.opacity)
            }
        }
    }

    private func verb(_ running: Bool) -> String {
        switch kind {
        case .command: running ? "Running" : "Ran"
        default: running ? "Exploring" : "Explored"
        }
    }

    private var summary: String {
        kind == .command ? "\(calls.count) commands" : ToolPresentation.exploreSummary(calls)
    }
}

// MARK: - Pieces

/// A call's kind as a small glyph; under the pointer it turns into the
/// chevron that opens the row, and a failed call shows a warning instead.
private struct ToolIcon: View {
    let symbol: String
    let open: Bool
    let hovering: Bool
    let failed: Bool
    /// A file the call edits: its icon from the Files pane stands in for the symbol.
    var file: String? = nil

    var body: some View {
        ZStack {
            if hovering {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(open ? 90 : 0))
            } else if failed {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.btRemoved)
            } else if let file {
                FileIcon(path: file, size: 14)
            } else {
                Image(systemName: symbol)
            }
        }
        .font(.system(size: 11, weight: .regular))
        .foregroundStyle(hovering ? Color.btTextSecondary : Color.btTextTertiary)
        .frame(width: 16, height: 16)
    }
}

/// A soft highlight sweeping across a label while its work runs, after
/// Paseo's running-tool shimmer (Apache-2.0, Copyright (c) 2025-present
/// Mohamed Boudra). Each transcript row has its own hosting view, so this
/// redraws its row only.
struct Shimmer: ViewModifier {
    let active: Bool
    /// About how many characters the label has; longer labels sweep slower.
    let length: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = 0

    private var duration: Double {
        min(max(1.25 + Double(length) * 0.008 - (length <= 12 ? 0.25 : 0), 1), 2.3)
    }

    func body(content: Content) -> some View {
        if active, !reduceMotion {
            content
                .opacity(0.72)
                .overlay {
                    content.mask {
                        GeometryReader { geo in
                            let band = min(max(42, geo.size.width * 0.22), 120)
                            LinearGradient(colors: [.clear, .white, .clear], startPoint: .leading, endPoint: .trailing)
                                .frame(width: band)
                                .offset(x: -band + phase * (geo.size.width + band))
                        }
                    }
                }
                .onAppear {
                    phase = 0
                    withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) { phase = 1 }
                }
        } else {
            content.opacity(active ? 0.72 : 1)
        }
    }
}


/// A file name first, its folder quieter after it; or a command in mono.
private struct ToolTargetView: View {
    let target: ToolTarget?
    var strong = false

    var body: some View {
        switch target {
        case .path(let name, let folder)?:
            HStack(spacing: 6) {
                Text(TextClip.line(name)).font(.btChatTool).foregroundStyle(strong ? Color.btText : Color.btProse).lineLimit(1).layoutPriority(1)
                if let folder, !folder.isEmpty {
                    Text(TextClip.line(folder)).font(.btChatCaption).foregroundStyle(strong ? Color.btTextSecondary : Color.btTextTertiary)
                        .lineLimit(1).truncationMode(.head)
                }
            }
        case .command(let command)?:
            Text(TextClip.line(command)).font(.btChatMono).foregroundStyle(strong ? Color.btText : Color.btTextSecondary).lineLimit(1).truncationMode(.tail)
        case .text(let text)?:
            Text(TextClip.line(text)).font(.btChatTool).foregroundStyle(strong ? Color.btText : Color.btTextSecondary).lineLimit(1).truncationMode(.tail)
        case nil:
            EmptyView()
        }
    }
}

/// An edit's changed lines with line numbers where known, washed green and
/// red in the flow of the text. Long diffs show their start and expand.
struct EditDiff: View {
    @Environment(\.transcriptExpansion) private var expansion
    @Environment(\.transcriptRow) private var row
    let edit: EditPreview
    /// Its place in the chat's record of what's open.
    var key: String? = nil
    var limit = 14
    @State private var local = false

    private var showAll: Bool { key.flatMap { ExpansionSwitch(key: $0, expansion: expansion, row: row).value(local: local) } ?? local }

    var body: some View {
        let all = edit.lines
        let shown = showAll ? all : Array(all.prefix(limit))
        let numbers = all.compactMap { $0.newLine ?? $0.oldLine }
        let gutter = numbers.isEmpty ? 0 : CGFloat(String(numbers.max() ?? 0).count) * 6.7 + 10
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.offset) { index, line in
                    if index > 0, line.startsHunk == true {
                        Text("⋯").font(.btChatMonoSmall).foregroundStyle(Color.btTextTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, gutter + 4)
                            .padding(.vertical, 2)
                    }
                    DiffLineRow(line: line, gutter: gutter)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            let hidden = all.count - shown.count
            let beyond = max(0, edit.additions + edit.deletions - all.filter { $0.origin != .context }.count)
            if hidden > 0 {
                Button("Show \(hidden) more line\(hidden == 1 ? "" : "s")") {
                    if key.map({ ExpansionSwitch(key: $0, expansion: expansion, row: row).set(true) }) != true { withAnimation(.snappy) { local = true } }
                }
                    .buttonStyle(.plain).font(.btChatCaption).foregroundStyle(Color.btTextTertiary)
                    .padding(.top, 6)
            } else if beyond > 0 {
                Text("\(beyond) more changed lines in Changes").font(.btChatCaption).foregroundStyle(Color.btTextTertiary)
                    .padding(.top, 6)
            }
        }
        .textSelection(.enabled)
    }
}

private struct DiffLineRow: View {
    let line: EditPreview.Line
    let gutter: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if gutter > 0 {
                Text((line.newLine ?? line.oldLine).map(String.init) ?? "")
                    .font(.btChatMonoSmall)
                    .foregroundStyle(Color.btTextTertiary.opacity(0.8))
                    .frame(width: gutter, alignment: .trailing)
                    .padding(.trailing, 4)
            }
            Text(line.origin == .added ? "+" : line.origin == .removed ? "−" : " ")
                .foregroundStyle(line.origin == .added ? Color.btAdded : line.origin == .removed ? Color.btRemoved : Color.btTextTertiary)
                .frame(width: 16)
            Text(line.content.isEmpty ? " " : TextClip.line(line.content, max: 2_000))
                .foregroundStyle(line.origin == .context ? Color.btTextSecondary : Color.btText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.btChatMono)
        .lineSpacing(1.5)
        .padding(.vertical, 1.5)
        .padding(.trailing, Space.sm)
        .background(line.origin == .added ? Color.btAddedWash : line.origin == .removed ? Color.btRemovedWash : .clear)
    }
}

struct TodoItem: Hashable {
    enum State { case pending, active, done }
    let text: String
    let state: State
}

/// The agent's plan as a checklist: what's done, what's under way, what's next.
private struct TodoChecklist: View {
    let items: [TodoItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                    Image(systemName: item.state == .done ? "checkmark.circle.fill" : item.state == .active ? "circle.inset.filled" : "circle")
                        .font(.system(size: 11.5, weight: .light))
                        .foregroundStyle(item.state == .active ? Color.btText : Color.btTextTertiary)
                        .frame(width: 14)
                    Text(item.text)
                        .font(.btChatTool)
                        .foregroundStyle(item.state == .done ? Color.btTextTertiary : item.state == .active ? Color.btText : Color.btTextSecondary)
                        .strikethrough(item.state == .done, color: Color.btTextTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// A tool's input as quiet key/value lines, never raw JSON.
private struct InputFields: View {
    let input: JSONValue

    var body: some View {
        let fields = (input.object ?? [:]).sorted { $0.key < $1.key }
        if fields.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(fields, id: \.key) { field in
                    HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                        Text(field.key).font(.btChatMonoSmall).foregroundStyle(Color.btTextTertiary).fixedSize()
                        Text(TextClip.block(ToolPresentation.short(field.value), total: 4_000)).font(.btChatMono).foregroundStyle(Color.btTextSecondary)
                            .lineLimit(6).textSelection(.enabled)
                    }
                }
            }
        }
    }
}

/// Monospaced text set apart by a leading rule instead of a box.
struct CodeText: View {
    let text: String
    /// Off when the surrounding block already carries a rule.
    var ruled = true
    init(_ text: String, ruled: Bool = true) { self.text = text; self.ruled = ruled }
    var body: some View {
        let content = ScrollView(.horizontal, showsIndicators: false) {
            TextLines(text: TextClip.block(text), font: .btChatMono, color: Color.btTextSecondary, spacing: 2.5).fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if ruled { content.btLeadingRule() } else { content }
    }
}

private struct OutputText: View {
    @Environment(\.transcriptExpansion) private var expansion
    @Environment(\.transcriptRow) private var row
    let text: String
    let isError: Bool
    var key: String? = nil
    @State private var local = false
    private var expanded: Bool { key.flatMap { ExpansionSwitch(key: $0, expansion: expansion, row: row).value(local: local) } ?? local }
    var body: some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        VStack(alignment: .leading, spacing: 4) {
            TextLines(text: TextClip.block(expanded || lines.count <= 14 ? text : lines.prefix(14).joined(separator: "\n")),
                      font: .btChatMono, color: isError ? Color.btRemoved : Color.btTextSecondary, spacing: 2.5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .btLeadingRule(isError ? Color.btRemoved : Color.btBorderStrong)
            if lines.count > 14 {
                Button(expanded ? "Show less" : "Show \(lines.count - 14) more lines") {
                    if key.map({ ExpansionSwitch(key: $0, expansion: expansion, row: row).set(!expanded) }) != true { local.toggle() }
                }
                    .buttonStyle(.plain).font(.btChatCaption).foregroundStyle(Color.btTextTertiary)
                    .padding(.leading, Space.md + 2)
            }
        }
    }
}

// MARK: - Words

enum ToolTarget: Equatable {
    case path(name: String, folder: String?)
    case command(String)
    case text(String)
}

private struct LatestTodoKey: EnvironmentKey { static let defaultValue: String? = nil }
private struct ToolApprovalsKey: EnvironmentKey { static let defaultValue: [String: PendingPermission] = [:] }

extension EnvironmentValues {
    /// Pending approvals by the id of the tool call they are for.
    var toolApprovals: [String: PendingPermission] {
        get { self[ToolApprovalsKey.self] }
        set { self[ToolApprovalsKey.self] = newValue }
    }

    /// The newest checklist in the chat; older ones stay folded.
    var latestTodoCallId: String? {
        get { self[LatestTodoKey.self] }
        set { self[LatestTodoKey.self] = newValue }
    }
}

enum ToolPresentation {
    static func symbol(_ name: String) -> String {
        switch name.lowercased() {
        case "read", "notebookread": "doc.text"
        case "write": "doc.badge.plus"
        case "edit", "multiedit", "notebookedit", "applypatch", "apply_patch", "file_change": "pencil"
        case "bash", "shell", "command_execution", "bashoutput": "terminal"
        case "grep", "glob", "search", "ls", "toolsearch": "magnifyingglass"
        case "webfetch", "websearch", "web_search": "globe"
        case "todowrite", "todolist", "todo_list": "checklist"
        case "exitplanmode": "list.bullet.clipboard"
        case "task", "agent": "person.2"
        case "skill": "book.closed"
        case "askuserquestion": "questionmark.bubble"
        default: name.hasPrefix("mcp__") ? "puzzlepiece.extension" : "wrench.and.screwdriver"
        }
    }

    /// Past tense once done, present while running: "Edited", "Editing".
    static func verb(_ name: String, pending: Bool = false) -> String {
        if pending {
            switch name.lowercased() {
            case "read", "notebookread": return "Reading"
            case "write": return "Creating"
            case "edit", "multiedit", "notebookedit", "applypatch", "apply_patch", "file_change": return "Editing"
            case "bash", "shell", "command_execution": return "Running"
            case "grep", "websearch", "web_search", "toolsearch": return "Searching"
            case "glob", "ls": return "Listing"
            case "webfetch": return "Fetching"
            case "task", "agent": return "Delegating"
            case "todowrite", "todolist", "todo_list": return "Updating plan"
            case "exitplanmode": return "Proposed a plan"
            case "skill": return "Using skill"
            case "askuserquestion": return "Asking"
            default: break
            }
        }
        return switch name.lowercased() {
        case "read", "notebookread": "Read"
        case "write": "Created"
        case "edit", "multiedit", "notebookedit", "applypatch", "apply_patch", "file_change": "Edited"
        case "bash", "shell", "command_execution": "Ran"
        case "bashoutput": "Checked output"
        case "grep": "Searched"
        case "glob", "ls": "Listed"
        case "toolsearch": "Looked up tools"
        case "webfetch": "Fetched"
        case "websearch", "web_search": "Searched the web"
        case "task", "agent": "Delegated"
        case "todowrite", "todolist", "todo_list": "Updated plan"
        case "exitplanmode": "Proposed a plan"
        case "skill": "Used skill"
        case "askuserquestion": "Asked"
        default: name.hasPrefix("mcp__") ? "Used" : displayName(name)
        }
    }

    /// A plain request for an approval row: "Edit", "Run", "Create".
    static func ask(_ name: String) -> String {
        switch name.lowercased() {
        case "edit", "multiedit", "notebookedit": "Edit"
        case "write": "Create"
        case "bash", "shell": "Run"
        case "webfetch": "Open"
        case "websearch": "Search the web for"
        case "read": "Read"
        case "exitplanmode": "Start on this plan"
        case "skill": "Use skill"
        case "askuserquestion": "Needs your input"
        default: name.hasPrefix("mcp__") ? "Use" : "Use \(displayName(name))"
        }
    }

    /// "mcp__linear__get_issue" → "linear · get issue"; others unchanged.
    static func displayName(_ name: String) -> String {
        guard name.hasPrefix("mcp__") else { return name }
        let parts = name.dropFirst(5).components(separatedBy: "__")
        return parts.map { $0.replacingOccurrences(of: "_", with: " ") }.joined(separator: " · ")
    }

    static func path(_ call: ToolCall) -> String? {
        guard let o = call.input.object else { return nil }
        return o["file_path"]?.string ?? o["notebook_path"]?.string ?? (ToolKind(call.name) == .command ? nil : o["path"]?.string)
    }

    static func relative(_ path: String, root: String?) -> String {
        guard let root, !root.isEmpty else { return path }
        let base = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }

    /// The command as the agent meant it, without the `zsh -lc "…"` wrapper
    /// Codex puts around everything.
    static func command(_ call: ToolCall) -> String? {
        guard ToolKind(call.name) == .command, let raw = call.input["command"]?.string else { return nil }
        return unwrapShell(raw)
    }

    static func unwrapShell(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for shell in ["/bin/zsh", "/bin/bash", "/bin/sh", "zsh", "bash", "sh"] {
            for flag in [" -lc ", " -c "] where s.hasPrefix(shell + flag) {
                var body = String(s.dropFirst(shell.count + flag.count))
                guard let quote = body.first, quote == "\"" || quote == "'", body.count >= 2, body.last == quote else { continue }
                body = String(body.dropFirst().dropLast())
                if quote == "\"" {
                    body = body.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\$", with: "$")
                        .replacingOccurrences(of: "\\`", with: "`").replacingOccurrences(of: "\\\\", with: "\\")
                }
                return body
            }
        }
        return s
    }

    static func target(_ call: ToolCall, root: String? = nil) -> ToolTarget? {
        let o = call.input.object ?? [:]
        switch ToolKind(call.name) {
        case .command:
            return command(call).map { .command($0.split(separator: "\n").first.map(String.init) ?? $0) }
        case .todo, .plan:
            return nil
        case .question:
            let count = AgentQuestion.parse(call.input).count
            return count > 1 ? .text("\(count) questions") : nil
        case .delegate:
            return (o["description"]?.string).map { .text($0) }
        default:
            break
        }
        if let path = path(call) {
            let rel = relative(path, root: root)
            let name = (rel as NSString).lastPathComponent
            let folder = (rel as NSString).deletingLastPathComponent
            return .path(name: name.isEmpty ? rel : name, folder: folder == "/" ? nil : folder)
        }
        if call.name.lowercased() == "skill", let skill = o["skill"]?.string { return .text(skill) }
        for key in ["pattern", "query", "url", "description", "path", "command"] {
            if let v = o[key]?.string, !v.isEmpty { return .text(key == "path" ? relative(v, root: root) : v) }
        }
        if call.name.hasPrefix("mcp__") { return .text(displayName(call.name)) }
        return nil
    }

    /// "3 files, 2 searches" for a run of look-around calls.
    static func exploreSummary(_ calls: [ToolCall]) -> String {
        var files = Set<String>(), searches = 0, web = 0, pages = 0, other = 0
        for call in calls {
            switch call.name.lowercased() {
            case "read", "notebookread": files.insert(path(call) ?? call.id)
            case "grep", "glob", "ls", "toolsearch": searches += 1
            case "websearch", "web_search": web += 1
            case "webfetch": pages += 1
            default: other += 1
            }
        }
        func count(_ n: Int, _ one: String, _ many: String) -> String? { n == 0 ? nil : "\(n) \(n == 1 ? one : many)" }
        return [count(files.count, "file", "files"), count(searches, "search", "searches"),
                count(web, "web search", "web searches"), count(pages, "page", "pages"), count(other, "lookup", "lookups")]
            .compactMap { $0 }.joined(separator: ", ")
    }

    /// Claude's TodoWrite (`todos`) or Codex's todo_list (`items`).
    static func todos(_ input: JSONValue) -> [TodoItem] {
        if let todos = input["todos"]?.array {
            return todos.compactMap { t in
                guard let content = t["content"]?.string else { return nil }
                switch t["status"]?.string {
                case "completed": return TodoItem(text: content, state: .done)
                case "in_progress": return TodoItem(text: t["activeForm"]?.string ?? content, state: .active)
                default: return TodoItem(text: content, state: .pending)
                }
            }
        }
        return (input["items"]?.array ?? []).compactMap { i in
            guard let text = i["text"]?.string else { return nil }
            return TodoItem(text: text, state: i["completed"]?.bool == true ? .done : .pending)
        }
    }

    static func todoProgress(_ call: ToolCall) -> String? {
        let items = todos(call.input)
        guard !items.isEmpty else { return nil }
        return "\(items.count { $0.state == .done }) of \(items.count) done"
    }

    static func head(_ text: String, lines: Int) -> String {
        let all = text.split(separator: "\n", omittingEmptySubsequences: true)
        return all.prefix(lines).map { TextClip.line(String($0)) }.joined(separator: "\n") + (all.count > lines ? "\n…" : "")
    }

    static func short(_ value: JSONValue) -> String {
        switch value {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        case .null: return "—"
        default: return value.compact()
        }
    }
}

/// Text cut to what a row can show. Core Text lays out a line whole before
/// truncating it, so a single line of megabytes (a minified file, a heredoc
/// command) would stall drawing for seconds; only a screenful is ever
/// visible, and the full text stays one Copy away.
enum TextClip {
    /// The first line, at most `max` characters.
    static func line(_ text: String, max: Int = 400) -> String {
        let first = text.firstIndex(of: "\n").map { text[..<$0] } ?? text[...]
        return first.count > max ? String(first.prefix(max)) + "…" : String(first)
    }

    /// Lines of at most `lineLength` characters, `total` characters in all.
    static func block(_ text: String, lineLength: Int = 2_000, total: Int = 60_000) -> String {
        guard text.count > lineLength else { return text }
        var out = ""
        out.reserveCapacity(min(text.count, total) + 16)
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if !out.isEmpty { out += "\n" }
            out += line.count > lineLength ? String(line.prefix(lineLength)) + "…" : String(line)
            if out.count >= total { return String(out.prefix(total)) + "\n…" }
        }
        return out
    }
}

/// Lines of selectable text, a Text each: one Text of many lines lays out in
/// time that grows much faster than its length, which a long output would
/// feel as a frozen scroll.
struct TextLines: View {
    let text: String
    let font: Font
    let color: Color
    var spacing: CGFloat = 2

    var body: some View {
        SelectableLines(text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init), spacing: spacing)
            .font(font)
            .foregroundStyle(color)
    }
}
