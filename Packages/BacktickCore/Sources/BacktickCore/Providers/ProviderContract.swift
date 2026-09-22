import Foundation

/// How much an agent may do without asking.
public enum PermissionPolicy: String, Sendable, Codable, CaseIterable {
    case ask
    case autoEdits = "auto-edits"
    case bypass

    public var title: String {
        switch self {
        case .ask: "Ask before acting"
        case .autoEdits: "Accept edits"
        case .bypass: "Full autonomy"
        }
    }

    public var detail: String {
        switch self {
        case .ask: "You approve each tool call in the chat."
        case .autoEdits: "File edits go through; commands still ask."
        case .bypass: "Nothing asks. Only for trusted tasks."
        }
    }
}

public struct LaunchContext: Sendable {
    /// Working directory: the session's worktree.
    public var cwd: String
    public var prompt: String
    public var resumeId: String?
    public var permissionPolicy: PermissionPolicy
    public var extraArgs: [String]
    public var binaryOverride: String?
    /// Model name or alias; nil uses the agent's own configured default.
    public var model: String?

    public init(cwd: String, prompt: String, resumeId: String? = nil, permissionPolicy: PermissionPolicy,
                extraArgs: [String] = [], binaryOverride: String? = nil, model: String? = nil) {
        self.cwd = cwd; self.prompt = prompt; self.resumeId = resumeId; self.permissionPolicy = permissionPolicy
        self.extraArgs = extraArgs; self.binaryOverride = binaryOverride
        self.model = model.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0.trimmingCharacters(in: .whitespaces) }
    }
}

/// Exactly what to spawn. The core runs it without interpreting it.
public struct LaunchSpec: Sendable, Hashable, Codable {
    public var command: String
    public var args: [String]
    public var cwd: String
    public var env: [String: String]
    /// Written to stdin right after spawn.
    public var stdinInitial: String?
    /// Keep stdin open for follow-up turns and permission answers. When false,
    /// stdin is closed right after `stdinInitial` (agents like `codex exec`
    /// otherwise wait on it forever).
    public var keepStdinOpen: Bool

    public init(command: String, args: [String], cwd: String, env: [String: String] = [:],
                stdinInitial: String? = nil, keepStdinOpen: Bool) {
        self.command = command; self.args = args; self.cwd = cwd; self.env = env
        self.stdinInitial = stdinInitial; self.keepStdinOpen = keepStdinOpen
    }
}

public enum OutputStreamKind: String, Sendable, Codable { case stdout, stderr }

public struct UsageTotals: Sendable, Hashable, Codable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheRead: Int
    public var cacheWrite: Int
    public init(inputTokens: Int = 0, outputTokens: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0) {
        self.inputTokens = inputTokens; self.outputTokens = outputTokens
        self.cacheRead = cacheRead; self.cacheWrite = cacheWrite
    }
    public static let zero = UsageTotals()
    public static func + (a: UsageTotals, b: UsageTotals) -> UsageTotals {
        UsageTotals(inputTokens: a.inputTokens + b.inputTokens, outputTokens: a.outputTokens + b.outputTokens,
                    cacheRead: a.cacheRead + b.cacheRead, cacheWrite: a.cacheWrite + b.cacheWrite)
    }
}

/// A small inline diff shown under an edit tool call.
public struct EditPreview: Sendable, Hashable, Codable {
    public enum Origin: String, Sendable, Codable { case context = " ", added = "+", removed = "-" }
    public struct Line: Sendable, Hashable, Codable {
        public var origin: Origin
        public var content: String
        public init(origin: Origin, content: String) { self.origin = origin; self.content = content }
    }
    public var filePath: String
    public var additions: Int
    public var deletions: Int
    public var lines: [Line]
    public init(filePath: String, additions: Int, deletions: Int, lines: [Line]) {
        self.filePath = filePath; self.additions = additions; self.deletions = deletions; self.lines = lines
    }
}

public enum TextRole: String, Sendable, Codable { case assistant, user }

/// Normalised agent output. Every provider parser produces only these.
public enum AgentEvent: Sendable, Hashable {
    case status(SessionStatus, detail: String?)
    case sessionId(String)
    case system(model: String?, cwd: String?, permissionMode: String?, sessionId: String?)
    /// `partial` chunks share `blockId` and are appended; the final block
    /// (partial == false) with the same id replaces them.
    case text(role: TextRole, text: String, blockId: String?, partial: Bool)
    case thinking(text: String, blockId: String?, partial: Bool)
    case toolUse(id: String, name: String, input: JSONValue, edit: EditPreview?)
    case toolResult(toolUseId: String, output: String, isError: Bool, edit: EditPreview?)
    case permissionRequest(requestId: String, toolName: String, input: JSONValue)
    case turnEnd(durationMs: Int?, costUsd: Double?, usage: UsageTotals?, summary: String?)
    case usage(UsageTotals, costUsd: Double?, durationMs: Int?, turns: Int?)
    case error(String)
    case raw(line: String, stream: OutputStreamKind)
}

public protocol OutputParser: AnyObject {
    /// One raw line from the agent. Must never throw or crash on bad input.
    func feed(_ line: String, stream: OutputStreamKind) -> [AgentEvent]
    func onExit(code: Int32?) -> [AgentEvent]
}

/// A model an agent can run, as offered in pickers. `id` is passed verbatim
/// to the CLI, so aliases ("opus") and full names both work.
public struct ModelOption: Sendable, Hashable, Identifiable {
    public var id: String
    public var label: String
    public init(id: String, label: String) { self.id = id; self.label = label }
}

public enum FollowUpMode: Sendable {
    /// Follow-ups are written to the live process's stdin.
    case stdin
    /// Follow-ups spawn a new process that resumes the provider session.
    case respawn
}

/// Everything agent-specific. Adding an agent = one conforming type plus one
/// line in `ProviderRegistry`. The rest of the app never names a provider.
public protocol ProviderDefinition: Sendable {
    var id: String { get }
    var name: String { get }
    /// Asset name of the provider's logo in the app bundle.
    var logoAsset: String { get }
    var binary: String { get }
    var detectArgs: [String] { get }
    var followUpMode: FollowUpMode { get }
    func buildLaunch(_ ctx: LaunchContext) -> LaunchSpec
    func buildResume(_ ctx: LaunchContext, resumeId: String) -> LaunchSpec
    func makeParser() -> OutputParser
    /// stdin line for a follow-up turn (stdin mode only).
    func buildUserMessage(_ text: String) -> String?
    /// stdin line answering a permission request (stdin mode only).
    func buildPermissionResponse(requestId: String, allow: Bool, input: JSONValue?) -> String?
    /// Suggested models. Any other name can still be typed in.
    var models: [ModelOption] { get }
    /// The model the CLI uses when none is passed, read from its own config.
    func configuredDefaultModel(home: String) -> String?
}
