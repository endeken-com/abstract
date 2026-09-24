import Foundation

/// Work an agent runs beside the conversation: a subagent or a shell command,
/// started in the background or moved there while it ran. Claude Code lists
/// these under `/tasks`.
public struct AgentTask: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable { case agent, shell, other }
    public enum Status: String, Sendable, Hashable { case running, completed, failed, stopped }

    public var id: String
    public var kind: Kind
    public var description: String
    /// The tool call that started it. A subagent's own messages come under it.
    public var toolUseId: String?
    public var subagentType: String?
    public var prompt: String?
    public var isBackgrounded: Bool
    /// Started by a subagent rather than the chat's own agent.
    public var ownedBySubagent: Bool
    public var status: Status
    /// What it's doing now, while it runs.
    public var activity: String?
    public var lastToolName: String?
    public var usage: TaskUsage?
    /// Its report once it ended: a subagent's answer, a command's exit.
    public var summary: String?
    /// A shell command's output, as a file on the agent's Mac.
    public var outputFile: String?
    public var error: String?

    public init(id: String, kind: Kind, description: String, toolUseId: String? = nil, subagentType: String? = nil,
                prompt: String? = nil, isBackgrounded: Bool = false, ownedBySubagent: Bool = false, status: Status = .running,
                activity: String? = nil, lastToolName: String? = nil, usage: TaskUsage? = nil, summary: String? = nil,
                outputFile: String? = nil, error: String? = nil) {
        self.id = id; self.kind = kind; self.description = description; self.toolUseId = toolUseId
        self.subagentType = subagentType; self.prompt = prompt; self.isBackgrounded = isBackgrounded
        self.ownedBySubagent = ownedBySubagent; self.status = status; self.activity = activity
        self.lastToolName = lastToolName; self.usage = usage; self.summary = summary
        self.outputFile = outputFile; self.error = error
    }

    /// Folds a later report into the task.
    mutating func apply(_ event: TaskEvent) {
        switch event {
        case .started:
            break
        case let .progress(_, activity, lastToolName, usage):
            self.activity = activity ?? self.activity
            self.lastToolName = lastToolName ?? self.lastToolName
            self.usage = usage ?? self.usage
        case let .updated(_, status, isBackgrounded, error):
            self.status = status ?? self.status
            self.isBackgrounded = isBackgrounded ?? self.isBackgrounded
            self.error = error ?? self.error
        case let .finished(_, status, summary, outputFile, usage):
            self.status = status
            self.summary = summary ?? self.summary
            self.usage = usage ?? self.usage
            // A subagent's output file is its raw transcript, not something to read.
            if kind == .shell { self.outputFile = outputFile ?? self.outputFile }
            activity = nil
        }
    }
}

public struct TaskUsage: Sendable, Hashable {
    public var tokens: Int?
    public var toolUses: Int?
    public var durationMs: Int?
    public init(tokens: Int? = nil, toolUses: Int? = nil, durationMs: Int? = nil) {
        self.tokens = tokens; self.toolUses = toolUses; self.durationMs = durationMs
    }
}

/// What the agent reports about one of its tasks.
public enum TaskEvent: Sendable, Hashable {
    case started(AgentTask)
    case progress(taskId: String, activity: String?, lastToolName: String?, usage: TaskUsage?)
    /// Only what changed; nil fields are unchanged.
    case updated(taskId: String, status: AgentTask.Status?, isBackgrounded: Bool?, error: String?)
    case finished(taskId: String, status: AgentTask.Status, summary: String?, outputFile: String?, usage: TaskUsage?)

    public var taskId: String {
        switch self {
        case .started(let task): task.id
        case .progress(let id, _, _, _), .updated(let id, _, _, _), .finished(let id, _, _, _, _): id
        }
    }
}

extension Timeline {
    /// Everything the agent ran as a task, oldest first.
    public var tasks: [AgentTask] {
        var order: [String] = []
        var byId: [String: AgentTask] = [:]
        var byCall: [String: String] = [:]
        for entry in entries {
            switch entry.event {
            case .task(.started(let task)):
                if byId[task.id] == nil { order.append(task.id) }
                byId[task.id] = task
                if let call = task.toolUseId { byCall[call] = task.id }
            case .task(let event):
                byId[event.taskId]?.apply(event)
            // A command's output file is named only in its call's result
            // until it ends.
            case let .toolResult(toolUseId, output, _, _):
                guard let id = byCall[toolUseId], byId[id]?.kind == .shell, byId[id]?.outputFile == nil else { continue }
                byId[id]?.outputFile = Self.outputFile(in: output)
            default:
                continue
            }
        }
        return order.compactMap { byId[$0] }
    }

    /// "…Output is being written to: /…/tasks/bl8cio4rv.output. You will…"
    static func outputFile(in result: String) -> String? {
        guard let match = result.firstMatch(of: /Output is being written to: (.+?\.output)\b/) else { return nil }
        return String(match.1)
    }

    /// What a subagent did, under the tool call that started it.
    public func subagent(_ toolUseId: String) -> Timeline {
        var out = Timeline()
        for entry in entries {
            if case let .subagent(parent, event) = entry.event, parent == toolUseId { out.append(event) }
        }
        return out
    }
}
