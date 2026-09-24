import SwiftUI
import AbstractCore

/// Above the reply box: what the agent runs in the background, as Claude
/// Code's footer says it ("2 in background"). Opens the list.
struct BackgroundTasksChip: View {
    @Environment(AppModel.self) private var model
    let sessionId: String

    var body: some View {
        let tasks = model.backgroundTasks(sessionId)
        if !tasks.isEmpty {
            let running = model.runningBackgroundTasks(sessionId)
            Button { model.tasksOpen = TasksFocus(sessionId: sessionId) } label: {
                HStack(spacing: 5) {
                    if running > 0 {
                        AnimatedDiamond(motion: .travel, color: .btAccent, track: Color.btTextTertiary.opacity(0.35))
                            .frame(width: 9, height: 9)
                    } else {
                        Image(systemName: "square.stack.3d.up").font(.system(size: 10))
                    }
                    Text(running > 0 ? "\(running) in background" : tasks.count == 1 ? "1 background task" : "\(tasks.count) background tasks")
                }
                .font(.btChatCaption)
                .foregroundStyle(running > 0 ? Color.btTextSecondary : Color.btTextTertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show background tasks")
            .popover(isPresented: Binding(get: { model.tasksOpen?.sessionId == sessionId },
                                          set: { if !$0, model.tasksOpen?.sessionId == sessionId { model.tasksOpen = nil } }),
                     arrowEdge: .top) {
                BackgroundTasksPanel(sessionId: sessionId).environment(model)
            }
        }
    }
}

/// The chat's background tasks, like Claude Code's `/tasks`: what each is,
/// how it stands, what it's doing, and Stop. A task opens to show its work.
struct BackgroundTasksPanel: View {
    @Environment(AppModel.self) private var model
    let sessionId: String

    var body: some View {
        let tasks = model.backgroundTasks(sessionId)
        let open = model.tasksOpen?.taskId.flatMap { id in tasks.first { $0.id == id } }
        Group {
            if let open {
                BackgroundTaskDetail(sessionId: sessionId, task: open) { model.tasksOpen?.taskId = nil }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    SectionLabel(title: "Background tasks")
                        .padding(.horizontal, Space.md)
                        .padding(.top, Space.md)
                        .padding(.bottom, Space.xs)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            // At work first, then the most recent to end.
                            ForEach(tasks.filter { $0.status == .running } + tasks.filter { $0.status != .running }.reversed()) { task in
                                BackgroundTaskRow(sessionId: sessionId, task: task) { model.tasksOpen?.taskId = task.id }
                            }
                        }
                        .padding(.horizontal, Space.xs)
                        .padding(.bottom, Space.xs)
                    }
                    .frame(maxHeight: 380)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(width: 420)
    }
}

private struct BackgroundTaskRow: View {
    @Environment(AppModel.self) private var model
    let sessionId: String
    let task: AgentTask
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: Space.sm) {
            TaskGlyph(task: task, alive: model.isAlive(sessionId)).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.description.isEmpty ? TaskPresentation.kindName(task) : task.description)
                    .font(.btChatBodyMedium)
                    .foregroundStyle(Color.btText)
                    .lineLimit(1)
                TaskStateLine(sessionId: sessionId, task: task)
                if let activity = task.activity, task.status == .running {
                    Text(activity).font(.btChatCaption).foregroundStyle(Color.btTextTertiary).lineLimit(1)
                }
            }
            Spacer(minLength: Space.sm)
            StopTaskButton(sessionId: sessionId, task: task)
        }
        .padding(.horizontal, Space.sm)
        .padding(.vertical, 7)
        .background(hovering ? Color.btHover : .clear, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        .help("Show what this task did")
    }
}

/// One task's work: its prompt, a subagent's steps, and how it ended or,
/// for a shell command, its output.
private struct BackgroundTaskDetail: View {
    @Environment(AppModel.self) private var model
    let sessionId: String
    let task: AgentTask
    let back: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.xs) {
                Button(action: back) { Label("All Tasks", systemImage: "chevron.left") }
                    .buttonStyle(.plain)
                    .font(.btChatCaption)
                    .foregroundStyle(Color.btTextTertiary)
                Spacer()
                StopTaskButton(sessionId: sessionId, task: task)
            }
            .padding(.horizontal, Space.md)
            .padding(.top, Space.md)
            HStack(alignment: .top, spacing: Space.sm) {
                TaskGlyph(task: task, alive: model.isAlive(sessionId)).padding(.top, 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.description.isEmpty ? TaskPresentation.kindName(task) : task.description)
                        .font(.btChatBodyMedium).foregroundStyle(Color.btText)
                        .textSelection(.enabled)
                    TaskStateLine(sessionId: sessionId, task: task)
                }
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.sm)
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: Space.md) {
                    if let prompt = task.prompt, !prompt.isEmpty {
                        TaskSection(title: "Prompt") {
                            Text(prompt).font(.btChatCallout).foregroundStyle(Color.btTextSecondary)
                                .lineSpacing(2).textSelection(.enabled).btLeadingRule()
                        }
                    }
                    if task.kind == .agent, let toolUseId = task.toolUseId {
                        SubagentSteps(sessionId: sessionId, toolUseId: toolUseId)
                    }
                    if task.kind == .shell {
                        TaskOutput(sessionId: sessionId, task: task)
                    }
                    if let error = task.error {
                        Text(error).font(.btChatCallout).foregroundStyle(Color.btRemoved).textSelection(.enabled)
                    }
                    if task.status != .running, let summary = task.summary, !summary.isEmpty {
                        TaskSection(title: task.kind == .agent ? "Result" : "Ended") {
                            if task.kind == .agent {
                                AgentProse(markdown: summary).textSelection(.enabled)
                            } else {
                                Text(summary).font(.btChatCallout).foregroundStyle(Color.btTextSecondary).textSelection(.enabled)
                            }
                        }
                    }
                }
                .padding(Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 440)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct TaskSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            SectionLabel(title: title)
            content
        }
    }
}

/// What a subagent has done so far, one line per tool call, and its last word.
private struct SubagentSteps: View {
    @Environment(AppModel.self) private var model
    let sessionId: String
    let toolUseId: String

    var body: some View {
        let feed = model.feed(sessionId)
        // Read so the steps update as the subagent works.
        let _ = feed.subagentSteps
        let blocks = feed.subagent(toolUseId).blocks
        let calls = blocks.flatMap { block -> [ToolCall] in if case let .tools(_, calls) = block { calls } else { [] } }
        let root = model.session(sessionId)?.worktreePath
        if !calls.isEmpty {
            TaskSection(title: calls.count == 1 ? "1 step" : "\(calls.count) steps") {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(calls.suffix(40)) { call in
                        HStack(spacing: 6) {
                            Image(systemName: ToolPresentation.symbol(call.name))
                                .font(.system(size: 10)).frame(width: 14)
                                .foregroundStyle(ToolOutcome(call).isFailure ? Color.btRemoved : Color.btTextTertiary)
                            Text(ToolPresentation.verb(call.name, pending: call.result == nil))
                                .font(.btChatCaptionMedium).foregroundStyle(Color.btTextSecondary).fixedSize()
                            if let target = TaskPresentation.text(ToolPresentation.target(call, root: root)) {
                                Text(target).font(.btChatCaption).foregroundStyle(Color.btTextTertiary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// A shell command's output as it's written, read from its file (on this Mac).
private struct TaskOutput: View {
    let sessionId: String
    let task: AgentTask
    @State private var text: String?

    var body: some View {
        if sessionId.hasPrefix(RemoteService.mirrorPrefix) {
            Text("The output is kept on the Mac running this chat.").font(.btChatCaption).foregroundStyle(Color.btTextTertiary)
        } else {
            TaskSection(title: "Output") {
                Group {
                    if let text, !text.isEmpty {
                        ScrollView {
                            Text(TextClip.block(text)).font(.btChatMonoSmall).foregroundStyle(Color.btTextSecondary)
                                .lineSpacing(2).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .defaultScrollAnchor(.bottom)
                        .frame(maxHeight: 200)
                    } else {
                        Text(task.status == .running ? "No output yet." : "No output.")
                            .font(.btChatCaption).foregroundStyle(Color.btTextTertiary)
                    }
                }
                .btLeadingRule()
            }
            .task(id: "\(task.id)-\(task.status.rawValue)-\(task.outputFile ?? "")") { await follow() }
        }
    }

    /// Reads the file's end, then again each second while the command runs.
    private func follow() async {
        guard let path = task.outputFile else { return }
        repeat {
            let read = await Task.detached { TaskPresentation.tail(path) }.value
            if read != text { text = read }
            guard task.status == .running else { return }
            try? await Task.sleep(for: .seconds(1))
        } while !Task.isCancelled
    }
}

private struct StopTaskButton: View {
    @Environment(AppModel.self) private var model
    let sessionId: String
    let task: AgentTask

    var body: some View {
        if task.status == .running, model.isAlive(sessionId), model.canControlTasks(sessionId) {
            Button("Stop") { model.stopTask(sessionId, taskId: task.id) }
                .buttonStyle(.bt(.ghost, size: .small))
                .help(task.kind == .agent ? "Stop this subagent" : "Stop this command")
        }
    }
}

/// "Running · 42s · Bash · 3 tools · 12.1k tokens", or how it ended.
private struct TaskStateLine: View {
    @Environment(AppModel.self) private var model
    let sessionId: String
    let task: AgentTask

    var body: some View {
        let alive = model.isAlive(sessionId)
        let seen = model.feed(sessionId).taskSeenAt[task.id]
        SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = task.status == .running && alive ? seen.map { Int(context.date.timeIntervalSince($0) * 1000) } : nil
            Text(TaskPresentation.stateLine(task, alive: alive, elapsedMs: elapsed))
                .font(.btChatCaption)
                .foregroundStyle(TaskPresentation.isFailure(task) ? Color.btRemoved : Color.btTextTertiary)
                .monospacedDigit()
                .lineLimit(1)
        }
    }
}

private struct TaskGlyph: View {
    let task: AgentTask
    let alive: Bool

    var body: some View {
        Image(systemName: TaskPresentation.symbol(task))
            .font(.system(size: 11))
            .frame(width: 16, height: 14)
            .foregroundStyle(task.status == .running && alive ? Color.btAccent
                             : TaskPresentation.isFailure(task) ? Color.btRemoved : Color.btTextTertiary)
    }
}

enum TaskPresentation {
    static func symbol(_ task: AgentTask) -> String {
        switch task.kind {
        case .agent: "person.2"
        case .shell: "terminal"
        case .other: "gearshape"
        }
    }

    static func kindName(_ task: AgentTask) -> String {
        switch task.kind {
        case .agent: task.subagentType.map { "\($0) agent" } ?? "Subagent"
        case .shell: "Shell command"
        case .other: "Task"
        }
    }

    static func isFailure(_ task: AgentTask) -> Bool { task.status == .failed }

    /// How it stands, in a word: a task still marked running when its
    /// agent's process is gone ended with it.
    static func state(_ task: AgentTask, alive: Bool) -> String {
        switch task.status {
        case .running: alive ? "Running" : "Ended with the chat"
        case .completed: "Done"
        case .failed: "Failed"
        case .stopped: "Stopped"
        }
    }

    static func stateLine(_ task: AgentTask, alive: Bool, elapsedMs: Int?) -> String {
        var parts = [state(task, alive: alive)]
        if let ms = elapsedMs ?? task.usage?.durationMs { parts.append(RelativeTime.duration(ms)) }
        if task.status == .running, alive, let tool = task.lastToolName { parts.append(tool) }
        if let tools = task.usage?.toolUses, tools > 0 { parts.append(tools == 1 ? "1 tool" : "\(tools) tools") }
        if let tokens = task.usage?.tokens, tokens > 0 { parts.append("\(RelativeTime.tokens(tokens)) tokens") }
        return parts.joined(separator: " · ")
    }

    static func text(_ target: ToolTarget?) -> String? {
        switch target {
        case let .path(name, folder)?: folder.flatMap { $0.isEmpty ? nil : "\($0)/\(name)" } ?? name
        case let .command(command)?: command
        case let .text(text)?: text
        case nil: nil
        }
    }

    /// The last `bytes` of a file, from a line start.
    nonisolated static func tail(_ path: String, bytes: UInt64 = 16_384) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > bytes ? size - bytes : 0
        try? handle.seek(toOffset: start)
        var text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        if start > 0, let newline = text.firstIndex(of: "\n") { text = String(text[text.index(after: newline)...]) }
        return text
    }
}
